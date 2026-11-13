// 职责: M7 研究任务服务 —— 独立窗口执行、预算熔断、结果回填。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (ResearchTasks 表)
//   lib/shared/database/novel_content_daos/research_task_dao.dart
//   lib/shared/agent/agent_hook.dart (AgentHook / HookAction)
//   lib/shared/services/ai/usage_service.dart (UsageService)
//   lib/shared/services/memory_proposal_service.dart (结果回填记忆提案)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v6→v7 createTable）
//
// §M7 研究任务：发起（选模型/定预算）→ 审批 → 独立窗口执行 → 结果回填。
// 本服务把上述链路串成可测试的编排层：
//   submit()   — 落库一条 pending_approval 任务（含模型/预算）
//   approve()  — 转 approved 并记审批时间
//   reject()   — 转 cancelled
//   run()      — 经 BudgetGuardHook 执行 Agent（token/费用超上限自动停）
//   backfill() — 把结果作为记忆提案写入 FactProposals（走 §4.1 审批链）
//
// 设计取舍：
// - 不重写 Agent/审批/记账基础设施，直接复用 Agent + AgentHook；
// - 预算熔断独立成一个 AgentHook（BudgetGuardHook），在 afterLLM 里累加
//   已耗，超限返回 HookAction.abort 中断 run；
// - 回填走 MemoryProposalService（M6e 已有），研究结论不直接写正典，
//   保留作者裁决入口。

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide Column;

import '../agent/agent.dart';
import '../agent/agent_event.dart';
import '../agent/agent_hook.dart';
import '../database/novel_content_database.dart';
import '../database/novel_content_daos/research_task_dao.dart';
import '../logger/app_logger.dart';
import '../models/ai_run_failure.dart';
import '../models/research_source_ref.dart';
import '../utils/random_id.dart';
import 'memory_proposal_service.dart';

final _log = AppLogger.forModule('ResearchTask');

/// 预算熔断钩子：在每轮 LLM 结束后累加 token/费用，超出上限即 abort。
///
/// 与 [UsageHook] 并列挂到同一个 Agent，不重写记账，只做「超预算停」。
/// 费用口径按全量 token（input+output）折算（cache 折扣价暂不计费，
/// 与 UsageService 记账保持一致；[costPerMileTokenMicros] 为 0 时不做
/// 费用熔断，仅 token 熔断）。
class BudgetGuardHook extends AgentHook {
  BudgetGuardHook({
    required this.dao,
    required this.taskId,
    this.budgetTokens = 0,
    this.budgetCostMicros = 0,
    this.costPerMileTokenMicros = 0,
    this.onBudgetExceeded,
  }) : super();

  final ResearchTaskDao dao;
  final String taskId;

  /// 0 = 不限 token。
  final int budgetTokens;

  /// 0 = 不限费用。
  final int budgetCostMicros;

  /// 每百万 token 的费用（微美元）。0 表示未配置价格、不做费用熔断。
  final int costPerMileTokenMicros;

  /// 熔断回调（供 UI 弹提示）。
  final void Function()? onBudgetExceeded;

  int _spentTokens = 0;
  int _spentCostMicros = 0;

  /// 本轮新增 token（供服务在 run() 结束后落库累计）。
  int get pendingDeltaTokens => _spentTokens;

  /// 本轮新增费用（微美元）。
  int get pendingDeltaCostMicros => _spentCostMicros;

  /// 是否已超限（token 或费用任一超限即停）。
  bool get exceeded {
    final tokenExceeded = budgetTokens > 0 && _spentTokens >= budgetTokens;
    final costExceeded =
        budgetCostMicros > 0 && _spentCostMicros >= budgetCostMicros;
    return tokenExceeded || costExceeded;
  }

  @override
  FutureOr<HookAction<AgentRoundResult>> afterLLM(AgentRoundResult round) {
    final usage = round.usage;
    if (usage == null || !usage.hasData) {
      return const HookAction.proceed();
    }
    _spentTokens += usage.totalTokens;
    if (costPerMileTokenMicros > 0) {
      _spentCostMicros +=
          (usage.totalTokens * costPerMileTokenMicros) ~/ 1000000;
    }
    if (exceeded) {
      onBudgetExceeded?.call();
      return HookAction.abort(
        AiRunFailure.requestFailed(
          providerMessage:
              '研究任务超出预算上限（token 或费用），已自动停止。',
        ),
        technicalMessage:
            'Budget exceeded: tokens=$_spentTokens budget=$budgetTokens; '
            'cost=$_spentCostMicros budget=$budgetCostMicros',
      );
    }
    return const HookAction.proceed();
  }
}

/// 研究任务编排服务。
class ResearchTaskService {
  ResearchTaskService(
    this.db, {
    this.memoryProposalService,
  });

  final NovelContentDatabase db;

  /// 结果回填走 M6e 记忆提案（§4.1 审批链）。可为 null（则不自动回填）。
  final MemoryProposalService? memoryProposalService;

  ResearchTaskDao get _dao => db.researchTaskDao;

  /// 发起研究任务：落库一条 pending_approval（含模型/预算），返回任务 id。
  Future<String> submit({
    required String title,
    required String prompt,
    String projectId = '',
    String providerId = '',
    String modelId = '',
    int budgetTokens = 0,
    int budgetCostMicros = 0,
  }) async {
    final id = buildRandomId('research');
    await _dao.upsert(
      ResearchTasksCompanion.insert(
        id: id,
        title: title,
        prompt: prompt,
        projectId: Value(projectId),
        providerId: Value(providerId),
        modelId: Value(modelId),
        budgetTokens: Value(budgetTokens),
        budgetCostMicros: Value(budgetCostMicros),
      ),
    );
    _log.info(
      '[ResearchTask] submitted id=$id budget(t)=$budgetTokens '
      'budget(cost)=$budgetCostMicros',
    );
    return id;
  }

  /// 审批通过：pending_approval→approved，记 approvedAt。
  Future<void> approve(String id, {String note = ''}) async {
    await _dao.updateStatus(
      id,
      researchTaskStatusApproved,
      approvedAt: DateTime.now(),
    );
    _log.info('[ResearchTask] approved id=$id note=$note');
  }

  /// 拒绝：pending_approval→cancelled。
  Future<void> reject(String id, {String note = ''}) async {
    await _dao.updateStatus(id, researchTaskStatusCancelled);
    _log.info('[ResearchTask] rejected id=$id note=$note');
  }

  /// 执行研究任务（对应的「执行」阶段）。
  ///
  /// 1. 校验任务必须处于 approved；
  /// 2. 转 running；
  /// 3. 消费事件流（[runEvents] 由调用方提供，通常是 `agent.process(task)`）；
  /// 4. 按结果转 completed/failed/budget_exceeded/cancelled，并累计 spent；
  /// 5. 返回 [ResearchRunOutcome]。
  ///
  /// 之所以接收事件流函数而不是 Agent 实例，是为了让编排逻辑可单测
  /// （Agent 构造器私有、依赖真实 ProviderClient），生产路径用
  /// [runWithAgent] 包一层即可。
  Future<ResearchRunOutcome> run(
    String id, {
    required String task,
    required Stream<AgentEvent> Function(String task) runEvents,
  }) async {
    final row = await _dao.getById(id);
    if (row == null) {
      throw StateError('research task not found: $id');
    }
    if (row.status != researchTaskStatusApproved &&
        row.status != researchTaskStatusRunning) {
      throw StateError(
        'research task $id not runnable (status=${row.status}); '
        '需要先 submit → approve',
      );
    }
    await _dao.updateStatus(id, researchTaskStatusRunning);

    // 按任务表预算自建熔断钩子。
    final guard = BudgetGuardHook(
      dao: _dao,
      taskId: id,
      budgetTokens: row.budgetTokens,
      budgetCostMicros: row.budgetCostMicros,
    );

    String? finalText;
    AiRunFailure? failure;
    var cancelled = false;
    try {
      await for (final event in runEvents(task)) {
        switch (event) {
          case AgentDone():
            finalText = event.finalText;
          case AgentError():
            failure = event.failure;
          case AgentCancelled():
            cancelled = true;
          default:
            break;
        }
      }
    } catch (error, stackTrace) {
      _log.error('[ResearchTask] run error id=$id', stackTrace: stackTrace);
      await _dao.updateStatus(
        id,
        researchTaskStatusFailed,
        errorCode: 'run_exception',
        completedAt: DateTime.now(),
      );
      return ResearchRunOutcome(
        taskId: id,
        status: researchTaskStatusFailed,
        resultText: '',
        errorCode: 'run_exception',
        message: error.toString(),
      );
    }

    final spentTokens = guard.pendingDeltaTokens;
    final spentCost = guard.pendingDeltaCostMicros;
    if (spentTokens > 0 || spentCost > 0) {
      await _dao.addSpent(id, spentTokens, spentCost);
    }

    if (cancelled) {
      await _dao.updateStatus(
        id,
        researchTaskStatusCancelled,
        errorCode: 'user_cancelled',
        completedAt: DateTime.now(),
      );
      return ResearchRunOutcome(
        taskId: id,
        status: researchTaskStatusCancelled,
        resultText: '',
        errorCode: 'user_cancelled',
      );
    }

    if (failure != null) {
      final isBudget = guard.exceeded;
      final status = isBudget
          ? researchTaskStatusBudgetExceeded
          : researchTaskStatusFailed;
      await _dao.updateStatus(
        id,
        status,
        errorCode: isBudget ? 'budget_exceeded' : failure.kind.name,
        resultText: finalText ?? '',
        completedAt: DateTime.now(),
      );
      return ResearchRunOutcome(
        taskId: id,
        status: status,
        resultText: finalText ?? '',
        errorCode: isBudget ? 'budget_exceeded' : failure.kind.name,
        message: failure.providerMessage,
      );
    }

    await _dao.updateStatus(
      id,
      researchTaskStatusCompleted,
      resultText: finalText ?? '',
      completedAt: DateTime.now(),
    );
    return ResearchRunOutcome(
      taskId: id,
      status: researchTaskStatusCompleted,
      resultText: finalText ?? '',
    );
  }

  /// 用现成 [Agent] 直接执行研究任务（生产路径便捷封装）。
  Future<ResearchRunOutcome> runWithAgent(
    String id, {
    required Agent agent,
    required String task,
  }) {
    return run(id, task: task, runEvents: agent.process);
  }

  /// 结果回填：把研究结论作为记忆提案写入 FactProposals（不直接改正典）。
  ///
  /// 走 M6e 审批链，作者可在「待裁决」面板 accept/reject。
  Future<String?> backfill({
    required String taskId,
    String targetType = 'research',
    String targetId = '',
    String predicate = 'finding',
  }) async {
    final service = memoryProposalService;
    if (service == null) {
      return null;
    }
    final row = await _dao.getById(taskId);
    if (row == null || row.resultText.isEmpty) {
      return null;
    }
    final proposal = await service.propose(
      MemoryProposalRequest(
        projectId: row.projectId,
        targetType: targetType,
        targetId: targetId.isEmpty ? row.id : targetId,
        predicate: predicate,
        proposedValue: row.resultText,
        sourceModel: row.modelId,
      ),
    );
    _log.info('[ResearchTask] backfill id=$taskId proposal=${proposal.id}');
    return proposal.id;
  }

  /// 取消任务（标记 cancelled；实际 LLM 流中断由调用方 agent.cancel()）。
  Future<void> cancel(String id) async {
    await _dao.updateStatus(
      id,
      researchTaskStatusCancelled,
      errorCode: 'user_cancelled',
      completedAt: DateTime.now(),
    );
  }

  // ---------------------------------------------------------------------------
  // R-37 来源合规：来源记录存 ResearchTasks.metadataJson['sources']，
  // merge 保留其它键；未 verified 的来源不得展示为确定事实。
  // ---------------------------------------------------------------------------

  /// 追加一条研究来源记录（merge 进 metadataJson['sources']）。
  Future<void> addSourceRef(String taskId, ResearchSourceRef ref) async {
    final row = await _dao.getById(taskId);
    if (row == null) {
      throw StateError('research task not found: $taskId');
    }
    final metadata = _decodeMetadata(row.metadataJson);
    final sources = metadata['sources'] as List<dynamic>? ?? [];
    final updated = List<dynamic>.from(sources)
      ..add(ref.toJson());
    metadata['sources'] = updated;
    await _writeMetadata(taskId, metadata);
    _log.info('[ResearchTask] source added taskId=$taskId title=${ref.title}');
  }

  /// 列出任务的全部来源记录（缺省空数组）。
  Future<List<ResearchSourceRef>> listSourceRefs(String taskId) async {
    final row = await _dao.getById(taskId);
    if (row == null) {
      return const [];
    }
    final sources = _decodeMetadata(row.metadataJson)['sources'];
    if (sources is! List) {
      return const [];
    }
    return [
      for (final item in sources)
        if (item is Map<String, dynamic>)
          ResearchSourceRef.fromJson(item),
    ];
  }

  /// 作者核验第 [index] 条来源（verified=true；越界抛 StateError）。
  Future<void> markSourceVerified(String taskId, int index) async {
    final row = await _dao.getById(taskId);
    if (row == null) {
      throw StateError('research task not found: $taskId');
    }
    final metadata = _decodeMetadata(row.metadataJson);
    final sources = metadata['sources'] as List<dynamic>? ?? [];
    if (index < 0 || index >= sources.length) {
      throw RangeError.index(index, sources, 'source index');
    }
    final source = sources[index];
    if (source is Map<String, dynamic>) {
      final ref = ResearchSourceRef.fromJson(source);
      sources[index] = ref.copyWith(verified: true).toJson();
      metadata['sources'] = sources;
      await _writeMetadata(taskId, metadata);
    }
  }

  Map<String, dynamic> _decodeMetadata(String raw) {
    if (raw.isEmpty || raw == '{}') {
      return {};
    }
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
    } on FormatException {
      return {};
    }
  }

  Future<void> _writeMetadata(String taskId, Map<String, dynamic> metadata) async {
    // 只更新 metadataJson（update 而非 upsert：insert 校验会要求 title/prompt 必填）。
    await db.researchTaskDao.updateMetadata(taskId, jsonEncode(metadata));
  }
}

/// 执行结果封装（供 UI/测试消费）。
class ResearchRunOutcome {
  const ResearchRunOutcome({
    required this.taskId,
    required this.status,
    required this.resultText,
    this.errorCode,
    this.message,
  });

  final String taskId;
  final String status;
  final String resultText;
  final String? errorCode;
  final String? message;

  bool get succeeded => status == researchTaskStatusCompleted;

  bool get budgetExceeded => status == researchTaskStatusBudgetExceeded;
}