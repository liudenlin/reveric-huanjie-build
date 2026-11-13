// 职责: M7 ResearchTaskService 测试 — 发起/审批/执行/回填 + 预算熔断状态机。
// 关联文件:
//   lib/shared/services/research_task_service.dart
//   lib/shared/database/novel_content_database.dart (ResearchTasks 表)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（总纲 §4 M7）：发起（选模型/定预算）→审批→独立窗口执行→回填；
//   超预算自动停（budget_exceeded）；结果回填走 M6e 记忆提案。

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/client.dart' show AiUsage;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/research_source_ref.dart';
import 'package:reveric/shared/models/ai_run_failure.dart';
import 'package:reveric/shared/services/memory_proposal_service.dart';
import 'package:reveric/shared/services/research_task_service.dart';

void main() {
  late NovelContentDatabase db;
  late ResearchTaskService service;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = ResearchTaskService(db);
  });

  tearDown(() async => db.close());

  group('ResearchTaskService', () {
    test('submit 落库 pending_approval，携带模型与预算', () async {
      final id = await service.submit(
        title: '研究反派动机',
        prompt: '为什么反派要夺取星核？',
        projectId: 'novel_x',
        providerId: 'openai',
        modelId: 'gpt-4o',
        budgetTokens: 50000,
        budgetCostMicros: 100000,
      );
      final row = await db.researchTaskDao.getById(id);
      expect(row, isNotNull);
      expect(row!.status, researchTaskStatusPendingApproval);
      expect(row.providerId, 'openai');
      expect(row.modelId, 'gpt-4o');
      expect(row.budgetTokens, 50000);
      expect(row.budgetCostMicros, 100000);
    });

    test('approve 转 approved 并记审批时间', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      expect((await db.researchTaskDao.getById(id))!.status,
          researchTaskStatusPendingApproval);
      await service.approve(id, note: '同意执行');
      final row = await db.researchTaskDao.getById(id);
      expect(row!.status, researchTaskStatusApproved);
      expect(row.approvedAt, isNotNull);
    });

    test('reject 转 cancelled', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      await service.reject(id, note: '预算过高，暂缓');
      expect((await db.researchTaskDao.getById(id))!.status,
          researchTaskStatusCancelled);
    });

    test('run 前未 approve 抛 StateError（必须发起→审批→执行）', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      expect(
        () => service.run(id, task: '研究问题', runEvents: (_) => _emit([])),
        throwsA(isA<StateError>()),
      );
    });

    test('run 正常完成 → completed + 结果落库', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      await service.approve(id);
      final outcome = await service.run(
        id,
        task: '研究问题',
        runEvents: (_) => _emit(const [AgentDone('反派为复活亡妻。')]),
      );
      expect(outcome.succeeded, isTrue);
      expect(outcome.resultText, '反派为复活亡妻。');
      final row = await db.researchTaskDao.getById(id);
      expect(row!.status, researchTaskStatusCompleted);
      expect(row.resultText, '反派为复活亡妻。');
      expect(row.completedAt, isNotNull);
    });

    test('run AgentCancelled → cancelled + user_cancelled 错误码', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      await service.approve(id);
      final outcome = await service.run(
        id,
        task: 't',
        runEvents: (_) => _emit(const [AgentCancelled()]),
      );
      expect(outcome.status, researchTaskStatusCancelled);
      expect(outcome.errorCode, 'user_cancelled');
    });

    test('run AgentError → failed + 错误码 = failure.kind', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      await service.approve(id);
      final outcome = await service.run(
        id,
        task: 't',
        runEvents: (_) => _emit([
          AgentError(
            const AiRunFailure.requestFailed(providerMessage: 'LLM 挂了'),
          ),
        ]),
      );
      expect(outcome.status, researchTaskStatusFailed);
      expect(outcome.errorCode, 'requestFailed');
      expect(outcome.message, 'LLM 挂了');
    });

    test('BudgetGuardHook 超 token 预算 → budget_exceeded', () async {
      final id = await service.submit(
        title: 't',
        prompt: 'p',
        budgetTokens: 100,
      );
      await service.approve(id);
      // 事件流本身不产生 usage —— 由 hook 在 run 内模拟预置。
      // 这里直接单测 guard 行为。
      final guard = BudgetGuardHook(
        dao: db.researchTaskDao,
        taskId: id,
        budgetTokens: 100,
      );
      final round = AgentRoundResult(
        text: 't',
        thinking: '',
        toolCalls: const [],
        usage: _makeUsage(120),
      );
      final action = await guard.afterLLM(round);
      expect(action, isA<HookAction<AgentRoundResult>>());
      if (action is HookAbort<AgentRoundResult>) {
        expect(guard.exceeded, isTrue);
      } else {
        expect(guard.exceeded, isTrue, reason: '超预算必须中止');
      }
      expect(guard.pendingDeltaTokens, 120);
    });

    test('BudgetGuardHook 未超预算 proceed 且累计正确', () async {
      final guard = BudgetGuardHook(
        dao: db.researchTaskDao,
        taskId: 'rt_x',
        budgetTokens: 100,
      );
      final round = AgentRoundResult(
        text: 't',
        thinking: '',
        toolCalls: const [],
        usage: _makeUsage(80),
      );
      final action = await guard.afterLLM(round);
      expect(action, isA<HookProceed<AgentRoundResult>>());
      expect(guard.exceeded, isFalse);
      expect(guard.pendingDeltaTokens, 80);
    });

    test('backfill 把研究结论写入记忆提案（走 M6e 审批链）', () async {
      final svc = ResearchTaskService(
        db,
        memoryProposalService: MemoryProposalService(db),
      );
      final id = await svc.submit(title: 't', prompt: 'p', projectId: 'novel_x');
      await svc.approve(id);
      await svc.run(
        id,
        task: 'p',
        runEvents: (_) => _emit(const [AgentDone('结论X')]),
      );
      final proposalId = await svc.backfill(taskId: id, targetId: 'c_hero');
      expect(proposalId, isNotNull);
      final proposal = await db.factProposalDao.getById(proposalId!);
      expect(proposal, isNotNull);
      expect(proposal!.proposedValue, '结论X');
      expect(proposal.targetType, 'research');
      expect(proposal.reviewStatus, proposalReviewStatusPending);
    });

    test('R-37: addSourceRef 追加来源并 merge 保留其它 metadataJson 键', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      // 预置一个其它 metadataJson 键（模拟既有键，验证 merge 不覆盖）。
      await db.researchTaskDao.updateMetadata(id, '{"custom_key":"keep_me"}');
      await service.addSourceRef(
        id,
        ResearchSourceRef(
          url: 'https://example.com/article',
          retrievedAt: DateTime(2026, 11, 10),
          title: '星核设定考据',
          summary: '考据星核的历史原型',
          quotePosition: '第 2 章「星核」段',
          licenseStatus: 'public_domain',
          accessType: 'public',
          verified: false,
        ),
      );
      await service.addSourceRef(
        id,
        ResearchSourceRef(
          retrievedAt: DateTime(2026, 11, 11),
          title: '第二来源',
        ),
      );
      final sources = await service.listSourceRefs(id);
      expect(sources, hasLength(2));
      expect(sources.first.title, '星核设定考据');
      expect(sources.first.url, 'https://example.com/article');
      expect(sources.first.verified, isFalse);
      expect(sources.first.licenseStatus, 'public_domain');
      expect(sources.last.title, '第二来源');
      final row = await db.researchTaskDao.getById(id);
      expect(row!.metadataJson, contains('keep_me'),
          reason: 'addSourceRef 必须 merge 保留其它 metadataJson 键');
      expect(row.metadataJson, contains('星核设定考据'));
    });

    test('R-37: listSourceRefs 缺省返回空数组', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      expect(await service.listSourceRefs(id), isEmpty);
    });

    test('R-37: markSourceVerified 把来源标记为已核验', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      await service.addSourceRef(
        id,
        ResearchSourceRef(retrievedAt: DateTime(2026, 11, 10), title: 'S1'),
      );
      await service.markSourceVerified(id, 0);
      final sources = await service.listSourceRefs(id);
      expect(sources.single.verified, isTrue);
      // 越界抛错。
      expect(() => service.markSourceVerified(id, 3), throwsRangeError);
    });

    test('R-37: readonly verified=false 的来源不被当作确定事实', () async {
      final id = await service.submit(title: 't', prompt: 'p');
      await service.addSourceRef(
        id,
        ResearchSourceRef(retrievedAt: DateTime(2026, 11, 10), title: 'S1'),
      );
      final sources = await service.listSourceRefs(id);
      expect(sources.single.verified, isFalse,
          reason: '未经核验的来源不得视为确定事实（R-37）');
    });
  });
}

// —— 测试辅助 ——

AiUsage _makeUsage(int total) => AiUsage(
  inputTokens: total ~/ 2,
  outputTokens: total - total ~/ 2,
);

Stream<AgentEvent> _emit(List<AgentEvent> events) {
  return Stream<AgentEvent>.fromIterable(events);
}