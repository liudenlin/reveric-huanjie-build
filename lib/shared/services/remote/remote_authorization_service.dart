// 职责: 远程渠道统一授权服务 — deny-by-default 白名单授权，按 (channelType, chatId, userId, scope)
//       判定「消息进入 Agent」与「远程工具执行」权限，并提供授权/撤销/审计能力。
//       所有判定共用同一个服务实例，消息入口与工具执行不产生第二套授权状态。
// 关联文件:
//   lib/shared/services/remote/channel_adapter.dart
//   lib/shared/services/remote/remote_bridge_service.dart
//   lib/shared/services/ai/assistant/coordinator.dart
//   lib/shared/services/ai/assistant/tool_dispatcher.dart
//   lib/shared/providers/remote_bridge_providers.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
import 'dart:async';
import 'dart:convert';

import '../../logger/app_logger.dart';
import 'notify_controls.dart';
import 'run_permission_policy.dart';
import 'run_resource_verifier.dart';

final _log = AppLogger.forModule('RemoteAuthorization');

/// 远程授权记录在 app_settings 中的存储 key（JSON 数组）。
///
/// 说明：本轮 P0-A 为「远程安全封口」最小施工，授权记录落在 app_settings
/// key-value 上（不建新表、不升 schemaVersion）——当前 schema v4 已随 v0.8.0
/// 发布，新增表必须走正式 v5 migration 并重新生成 Drift 代码（build_runner），
/// 风险与成本高于安全收益；建表方案列入 P0-B 后续施工建议。判定语义与表方案
/// 完全一致，迁移到表结构时记录字段可直接转换。
const remoteChannelAuthorizationsKey = 'remote_channel_authorizations';

/// 远程动作的读写维度（决定授权 scope 是否放行）。
///
/// - read：查询/只读类操作（list_novels、job_status、list_chapters 等）。
/// - write：会触发 AI 执行或数据写入的操作（消息进入 Agent、start_job、
///   send_to_job、create_novel、edit_novel 等）。
enum RemoteAction { read, write }

/// 远程授权的权限范围。
///
/// - read：仅放行只读操作。
/// - write：放行只读 + 写入操作。
/// - all：放行一切操作（含消息进入 Agent）。
enum RemotePermissionScope { read, write, all }

/// 一条远程授权记录。
///
/// 主键语义 (channelType, chatId, userId)：不同渠道、不同会话、不同用户各自
/// 独立判定，互不影响（多渠道/多会话不串权）。userId 为 null 表示会话级授权
/// （私聊里 chatId 即用户 id 时也可传 null 的 chat 级记录）。
class RemoteAuthorizationRecord {
  const RemoteAuthorizationRecord({
    required this.channelType,
    required this.chatId,
    this.userId,
    required this.scope,
    required this.grantedAt,
    this.revokedAt,
    this.displayName,
    this.grantedBy = 'local_user',
  });

  final String channelType;
  final String chatId;

  /// 平台侧用户 id；私聊中通常与 chatId 相同，群聊中区分成员。
  final String? userId;
  final RemotePermissionScope scope;
  final DateTime grantedAt;
  final DateTime? revokedAt;
  final String? displayName;

  /// 授权来源标识 —— 授权必须从本地可信界面/服务调用产生，
  /// 不允许使用未经验证的消息正文声明身份来授权。
  final String grantedBy;

  bool get isActive => revokedAt == null;

  /// 该授权在 [now] 是否仍有效：未撤销且未超过 [maxAge]。
  ///
  /// P0-D D1：授权失效策略 —— 授权记录按 `grantedAt + maxAge` 惰性过期
  /// （不新增列、不升 schema、不迁移既有数据）。[maxAge] 为 null 表示
  /// 不过期（兼容旧行为/单元测试），默认由
  /// [RemoteAuthorizationService.authorizationTtl] 提供。
  bool isActiveAt(DateTime now, {Duration? maxAge}) {
    if (revokedAt != null) {
      return false;
    }
    if (maxAge == null) {
      return true;
    }
    return !now.isAfter(grantedAt.add(maxAge));
  }

  /// 该记录是否匹配给定的渠道身份（授权判定用）。
  bool matches({
    required String channelType,
    required String chatId,
    String? userId,
  }) {
    if (channelType != this.channelType || chatId != this.chatId) {
      return false;
    }
    if (this.userId == null) {
      return true; // 会话级授权匹配整个会话
    }
    // 授权绑定 userId 时，消息声明身份必须一致；缺省 userId 的消息不匹配。
    return userId != null && userId == this.userId;
  }

  /// 该 scope 是否放行给定动作。
  bool allows(RemoteAction action) {
    switch (action) {
      // 任何 scope（read/write/all）都放行只读操作 —— 读是安全的，写才分权。
      case RemoteAction.read:
        return true;
      case RemoteAction.write:
        return scope == RemotePermissionScope.write ||
            scope == RemotePermissionScope.all;
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'channel_type': channelType,
    'chat_id': chatId,
    if (userId != null) 'user_id': userId,
    'scope': scope.name,
    'granted_at': grantedAt.toIso8601String(),
    if (revokedAt != null) 'revoked_at': revokedAt!.toIso8601String(),
    if (displayName != null) 'display_name': displayName,
    'granted_by': grantedBy,
  };

  static RemoteAuthorizationRecord? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    try {
      final channelType = raw['channel_type']?.toString();
      final chatId = raw['chat_id']?.toString();
      final scopeName = raw['scope']?.toString();
      final grantedAt = DateTime.tryParse(raw['granted_at']?.toString() ?? '');
      if (channelType == null ||
          channelType.isEmpty ||
          chatId == null ||
          chatId.isEmpty ||
          scopeName == null ||
          grantedAt == null) {
        return null;
      }
      final scope = RemotePermissionScope.values.where(
        (e) => e.name == scopeName,
      );
      if (scope.isEmpty) {
        return null;
      }
      final revokedRaw = raw['revoked_at']?.toString();
      return RemoteAuthorizationRecord(
        channelType: channelType,
        chatId: chatId,
        userId: raw['user_id']?.toString(),
        scope: scope.single,
        grantedAt: grantedAt,
        revokedAt: revokedRaw == null ? null : DateTime.tryParse(revokedRaw),
        displayName: raw['display_name']?.toString(),
        grantedBy: raw['granted_by']?.toString() ?? 'local_user',
      );
    } catch (error) {
      _log.error('[RemoteAuthorization] malformed record: $raw error=$error');
      return null;
    }
  }
}

/// 远程运行状态快照（P0-A.2 统一门禁）。
///
/// 由 providers 层从 app_settings 读取并注入授权服务，用于在执行敏感操作前
/// 复核「远程助手 enabled + 本地确认 remoteConfirmed」。两者缺一即 fail-closed：
/// 关闭远程助手或未本地确认后，即使授权记录仍有效，也已运行的 Job 也不得
/// 继续执行新的敏感操作（P0-A.2 任务一）。
class RemoteRuntimeStatus {
  const RemoteRuntimeStatus({
    required this.enabled,
    required this.remoteConfirmed,
  });

  /// 读取失败 / 持久化缺失时 fail-closed：一律拒绝远程执行。
  const RemoteRuntimeStatus.failClosed()
    : enabled = false,
      remoteConfirmed = false;

  /// 渠道桥接开关。
  final bool enabled;

  /// 本地用户显式确认标记（历史配置不绕过门禁）。
  final bool remoteConfirmed;

  /// 运行状态是否允许远程执行（enabled 且已本地确认）。
  bool get allowsRemote => enabled && remoteConfirmed;
}

/// 授权记录持久化接口。
///
/// 生产实现 [DriftRemoteAuthorizationStore]（`remote_authorizations` 表，
/// 行级事务操作）；[AppSettingsRemoteAuthorizationStore] 落 app_settings
/// （旧 JSON 背板，生产已弃用，保留兼容）；测试用内存实现，保证授权服务
/// 本体可在纯 Dart 测试中验证。
///
/// ## M2 行级操作（P0-B.1）
/// 新增 [upsert] / [revoke] / [listAll] / [readActive] 行级方法：默认实现
/// 基于 [read]/[write] 的读-改-写（单线程语义正确，兼容既有测试内存实现），
/// [DriftRemoteAuthorizationStore] 覆写为**事务行级**（并发安全，遵守部分
/// 唯一索引）。授权/撤销不再走「全表 DELETE ALL + INSERT ALL」替换。
abstract class RemoteAuthorizationStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);

  /// 行级授权/重新授权（grant/upsert）。
  ///
  /// 同一 (channelType, chatId, userId) 已存在 → 覆盖为最新授权；否则新增。
  /// 默认实现读-改-写（单线程正确）；Drift 覆写为事务 + 部分唯一索引。
  Future<void> upsert(RemoteAuthorizationRecord record) async {
    final records = await _readAllRecords();
    records.removeWhere(
      (r) =>
          r.channelType == record.channelType &&
          r.chatId == record.chatId &&
          r.userId == record.userId,
    );
    records.add(record);
    await _writeAllRecords(records);
  }

  /// 行级软撤销（置 revokedAt，保留记录与审计）。
  ///
  /// 返回是否实际撤销了一条活动记录。默认实现读-改-写；Drift 覆写为
  /// 事务内 `UPDATE ... SET revoked_at`（仅活动行）。
  Future<bool> revoke({
    required String channelType,
    required String chatId,
    String? userId,
    DateTime? at,
    String? revokedBy,
  }) async {
    final now = at ?? DateTime.now();
    final records = await _readAllRecords();
    var revoked = false;
    final updated = <RemoteAuthorizationRecord>[
      for (final r in records)
        if (r.isActive &&
            r.channelType == channelType &&
            r.chatId == chatId &&
            r.userId == userId)
          () {
            revoked = true;
            return RemoteAuthorizationRecord(
              channelType: r.channelType,
              chatId: r.chatId,
              userId: r.userId,
              scope: r.scope,
              grantedAt: r.grantedAt,
              revokedAt: now,
              displayName: r.displayName,
              grantedBy: r.grantedBy,
            );
          }()
        else
          r,
    ];
    if (revoked) {
      await _writeAllRecords(updated);
    }
    return revoked;
  }

  /// 列出授权记录（含已撤销；可选按渠道/会话过滤）。
  Future<List<RemoteAuthorizationRecord>> listAll({
    String? channelType,
    String? chatId,
  }) async {
    final records = await _readAllRecords();
    return [
      for (final r in records)
        if ((channelType == null || r.channelType == channelType) &&
            (chatId == null || r.chatId == chatId))
          r,
    ];
  }

  /// 读取活动（未撤销且匹配）授权记录——授权判定用。
  Future<List<RemoteAuthorizationRecord>> readActive({
    required String channelType,
    required String chatId,
    String? userId,
  }) async {
    final records = await _readAllRecords();
    return [
      for (final r in records)
        if (r.isActive &&
            r.matches(channelType: channelType, chatId: chatId, userId: userId))
          r,
    ];
  }

  /// 读取全部记录（容错：损坏/非列表按空表，fail-closed）。
  Future<List<RemoteAuthorizationRecord>> _readAllRecords() async {
    final raw = await read(remoteChannelAuthorizationsKey);
    if (raw == null || raw.isEmpty) {
      // 返回可变列表：默认 upsert 会对结果做 removeWhere（M2 行级语义）。
      return <RemoteAuthorizationRecord>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return <RemoteAuthorizationRecord>[];
      }
      return <RemoteAuthorizationRecord>[
        for (final item in decoded) ?RemoteAuthorizationRecord.fromJson(item),
      ];
    } catch (_) {
      return <RemoteAuthorizationRecord>[];
    }
  }

  /// 全量写入（默认实现用 JSON 序列化）。
  Future<void> _writeAllRecords(
    List<RemoteAuthorizationRecord> records,
  ) async {
    await write(
      remoteChannelAuthorizationsKey,
      jsonEncode([for (final r in records) r.toJson()]),
    );
  }
}

/// 远程授权判定门面 —— coordinator / bridge / tool dispatcher 共用同一实例，
/// 保证「两层入口使用同一个授权判断逻辑」，不产生不一致的授权状态。
abstract interface class RemoteAuthorizationGateway {
  /// 消息能否进入 Agent 执行（含触发工具与数据写入）。
  ///
  /// deny-by-default：无有效记录即 false。仅 scope ∈ {write, all} 放行
  /// （read 授权不能进入会触发写入的 Agent turn）。
  Future<bool> isMessageAuthorized({
    required String channelType,
    required String chatId,
    String? userId,
    String? jobId,
  });

  /// 单个远程工具能否执行。
  ///
  /// 按工具读写能力 + 授权 scope 判定：只读工具要求 scope ∈ {read, write, all}；
  /// 写入/执行类工具要求 scope ∈ {write, all}。禁止把「消息文本推断动作」
  /// 作为最终授权依据 —— 工具名由 LLM 调用点显式传入，与消息正文无关。
  Future<bool> isToolAuthorized(
    String toolName, {
    required String channelType,
    required String chatId,
    String? userId,
    String? jobId,
  });

  /// 从本地可信界面授权一个渠道身份（动作本身必须来自本地 UI/服务调用）。
  ///
  /// [allowSessionWide]：仅当调用方显式确认该渠道会话的身份可验证（私聊/单聊）
  /// 时才可授权会话级记录（userId 为 null）。群聊/身份无法验证的会话默认禁止
  /// 共享会话级授权（P0-A.1 任务 3）——调用方应要求传入具体 userId 或显式
  /// 声明该会话身份可验证并置 true。
  Future<void> authorizeRemoteUser({
    required String channelType,
    required String chatId,
    String? userId,
    required RemotePermissionScope scope,
    String? displayName,
    String grantedBy = 'local_user',
    bool allowSessionWide = false,
  });

  /// 撤销授权（软撤销：置 revokedAt，保留审计记录，不物理删除）。
  Future<void> revokeRemoteUser({
    required String channelType,
    required String chatId,
    String? userId,
    String revokedBy = 'local_user',
  });

  /// 列出授权记录（可选按渠道/会话过滤）。
  Future<List<RemoteAuthorizationRecord>> listAuthorizations({
    String? channelType,
    String? chatId,
  });
}

/// AppSettings 实现的授权存储（读-改-写同一 key；生产已由
/// [DriftRemoteAuthorizationStore] 替代，保留作兼容/回退）。
class AppSettingsRemoteAuthorizationStore extends RemoteAuthorizationStore {
  AppSettingsRemoteAuthorizationStore(this._read, this._write);

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  @override
  Future<String?> read(String key) => _read(key);

  @override
  Future<void> write(String key, String value) => _write(key, value);
}

/// 远程授权审计事件（内存环形缓冲，供 UI/测试观察；同步写 AppLogger；
/// P0-B B3 起同时持久化到 `remote_authorization_audit` 表）。
class RemoteAuthorizationAuditEvent {
  const RemoteAuthorizationAuditEvent({
    required this.event,
    required this.channelType,
    required this.chatId,
    this.userId,
    this.detail,
    this.jobId,
    required this.at,
  });

  final String
  event; // grant / revoke / deny_runtime / deny_message / deny_tool / allow_message / allow_tool
  final String channelType;
  final String chatId;
  final String? userId;

  /// 事件详情（已脱敏，不含敏感 Token / API Key / 凭证）。
  final String? detail;

  /// 关联远程 Job（send_to_job 续跑等场景）；无则 null。
  final String? jobId;
  final DateTime at;
}

/// 远程授权审计持久化接口（P0-B B3）。
///
/// 生产实现 [DriftRemoteAuthorizationAuditStore] 落
/// `remote_authorization_audit` 表（追加式）；测试用内存实现，保证审计
/// 本体可在纯 Dart 测试中验证。
///
/// 不变量：`append` 实现必须吞掉内部异常（不得向上抛），保证审计写入
/// 失败绝不影响授权判定（审计是授权决策之后的最佳努力记录，非关键路径）。
abstract interface class RemoteAuthorizationAuditStore {
  /// 追加一条审计事件（append-only）。
  Future<void> append(RemoteAuthorizationAuditEvent event);

  /// 按时间 / 用户 / 渠道 / Job / 事件类型过滤查询（默认返回最近 [limit] 条，
  /// 按 `at` 倒序）。
  ///
  /// [eventTypes] 非空时仅返回命中事件类型（如 `{'deny_message','deny_tool'}`）
  /// 的记录——事件筛选下沉到存储层，避免「最新一页全为放行、历史拒绝被漏掉」
  /// 的筛选失真。
  Future<List<RemoteAuthorizationAuditEvent>> query({
    DateTime? since,
    DateTime? until,
    String? channelType,
    String? chatId,
    String? userId,
    String? jobId,
    Set<String>? eventTypes,
    int limit = 200,
  });

  /// 清理早于 [cutoff] 的事件（保留期限策略），返回删除行数。
  Future<int> cleanupBefore(DateTime cutoff);
}

/// 授权列表读取快照（P0-B B4：存储错误提示）。
///
/// 授权判定路径 [RemoteAuthorizationService.listAuthorizations] 保持
/// fail-closed（存储故障按空表拒绝，语义不变）；本快照供管理 UI 区分
/// 「确无授权」与「存储读取失败」——后者不得用误导性的空态提示，而应展示
/// 错误（存储故障 ≠ 无授权）。
class AuthorizationListSnapshot {
  const AuthorizationListSnapshot({required this.records, this.error});

  /// 已读取的授权记录（存储故障时为空）。
  final List<RemoteAuthorizationRecord> records;

  /// 读取错误；null 表示读取成功。
  final String? error;
}

/// 敏感字段脱敏：Token / API Key / 凭证等一律不写入审计 `detail`。
///
/// 匹配 `key=xxx`、`key: xxx` 形式的敏感键并替换值为 `<redacted>`；
/// 不匹配的原文（纯事件描述，如 `scope=write`、`tool=xxx action=read`）
/// 原样保留。脱敏是防御性兜底 —— 服务侧构造 detail 时本就不该含凭证，
/// 此处再拦一道，确保「敏感 Token / API Key 不写入」为硬约束。服务层
/// `_audit` 与审计存储写入边界（[DriftRemoteAuthorizationAuditStore]）都会
/// 调用本函数，实现纵深防御。
final RegExp _auditSecretPattern = RegExp(
  r'((?:token|api[_-]?key|secret|password|passwd|authorization|bearer|'
  r'access[_-]?token|refresh[_-]?token|credential|private[_-]?key|'
  r'client[_-]?secret)\s*[=:]\s*(?:(?:bearer)\s+)?)\S+',
  caseSensitive: false,
);

String? sanitizeRemoteAuthorizationDetail(String? detail) {
  if (detail == null || detail.isEmpty) {
    return detail;
  }
  return detail.replaceAllMapped(
    _auditSecretPattern,
    (m) => '${m.group(1)}<redacted>',
  );
}

/// 统一远程授权服务实现。
///
/// 核心语义：
/// 1. deny-by-default —— 授权表无有效记录一律拒绝。
/// 2. 授权绑定 (channelType, chatId, userId)，身份必须来自可信渠道适配器
///    （消息正文不允许声明身份）。
/// 3. 消息入口与工具执行共用本服务的判定，授权状态单一来源。
/// 4. 支持授权 / 撤销 / 审计。
/// 5. P0-A.2 统一远程执行门禁 —— 注入 [runtimeStatusProvider] 后，每次
///    授权判定前置复核「远程助手 enabled + 本地确认 remoteConfirmed」，
///    关闭远程或未确认时 fail-closed 拒绝，防止已授权 Job 在远程关闭后
///    继续执行敏感操作。生产路径必须注入；未注入仅用于纯授权单元测试
///    （此时不叠加运行状态门禁，授权语义本身可独立验证）。
class RemoteAuthorizationService implements RemoteAuthorizationGateway {
  RemoteAuthorizationService(
    this._store, {
    RemoteAuthorizationAuditStore? auditStore,
    Future<RemoteRuntimeStatus> Function()? runtimeStatusProvider,
    RunResourceVerifier? resourceVerifier,
    // P0-D D1：授权失效策略 —— 授权记录超过该时长后视为过期（惰性判定）。
    // 默认 30 天；null 表示不过期（仅显式测试用）。生产由 providers 注入
    // 或走默认；管理 UI 可将授权视为「已过期」并可批量撤销。
    Duration? authorizationTtl = const Duration(days: 30),
  })  : _auditStore = auditStore, // ignore: prefer_initializing_formals — 字段私有，命名参数不能以下划线开头。
        // ignore: prefer_initializing_formals — 字段私有，命名参数不能以下划线开头。
        _runtimeStatusProvider = runtimeStatusProvider,
        // ignore: prefer_initializing_formals — 字段私有，命名参数不能以下划线开头。
        _resourceVerifier = resourceVerifier,
        // ignore: prefer_initializing_formals — 字段私有，命名参数不能以下划线开头。
        _authorizationTtl = authorizationTtl;

  final RemoteAuthorizationStore _store;

  /// 审计持久化存储（P0-B B3）。未注入（纯授权单元测试）时仅内存 + 日志，
  /// 不落库；生产由 providers 注入 [DriftRemoteAuthorizationAuditStore]。
  final RemoteAuthorizationAuditStore? _auditStore;

  /// 远程运行状态读取回调（由 providers 层从 app_settings 注入）。
  ///
  /// 读取失败时由调用方返回 [RemoteRuntimeStatus.failClosed]，授权服务
  /// 侧再兜一层异常 fail-closed，保证存储故障不产生放行。
  final Future<RemoteRuntimeStatus> Function()? _runtimeStatusProvider;

  /// P0-B.3 任务2：作品域 Run 写操作的目标资源归属校验器（由 providers 层
  /// 注入 DAO 实现）。未注入时退化为「options 显式目标作品 ID == workId」
  /// 比对（纯授权单元测试可验证跨作品拒绝），资源级 ID 无校验器则拒绝。
  final RunResourceVerifier? _resourceVerifier;

  /// P0-D D1：授权失效策略 —— 授权记录超过该时长后视为过期（惰性判定，
  /// 见 [RemoteAuthorizationRecord.isActiveAt]）。null 表示不过期（仅测试）。
  final Duration? _authorizationTtl;

  /// 审计事件广播流（P0-B B4：管理 UI 实时更新）。
  ///
  /// 每次 [RemoteAuthorizationService._audit]（grant/revoke/deny/allow 等）
  /// 都会向流推一条事件，UI 订阅后即可在授权/撤销/远程判定发生时实时刷新，
  /// 无需轮询或手动点击。服务为长生命周期单例，流不关闭（进程内随服务存活）。
  final StreamController<RemoteAuthorizationAuditEvent> _auditController =
      StreamController<RemoteAuthorizationAuditEvent>.broadcast();

  /// 最近一次授权存储读取错误（P0-B B4：存储错误提示）。
  ///
  /// [listAuthorizations] 的 [_loadAll] 读取成功清空、失败置值。仅供管理 UI
  /// 通过 [listAuthorizationsDetailed] 区分「确无授权」与「存储读取失败」；
  /// 授权判定路径不读本字段（仍 fail-closed），且本字段为尽力提示，并发
  /// 授权判定可能覆盖，但不影响判定语义（UI 提示非关键路径）。
  String? _lastStoreReadError;

  /// 审计事件流（只读）。
  Stream<RemoteAuthorizationAuditEvent> get auditStream =>
      _auditController.stream;

  static const _maxAuditEvents = 200;
  final List<RemoteAuthorizationAuditEvent> _auditEvents = [];

  /// 最近审计事件（不变量：最多保留 [_maxAuditEvents] 条）。
  List<RemoteAuthorizationAuditEvent> get auditEvents =>
      List.unmodifiable(_auditEvents);

  void _audit(
    String event,
    String channelType,
    String chatId,
    String? userId,
    String? detail, {
    String? jobId,
  }) {
    final safeDetail = sanitizeRemoteAuthorizationDetail(detail);
    final record = RemoteAuthorizationAuditEvent(
      event: event,
      channelType: channelType,
      chatId: chatId,
      userId: userId,
      detail: safeDetail,
      jobId: jobId,
      at: DateTime.now(),
    );
    _auditEvents.add(record);
    if (_auditEvents.length > _maxAuditEvents) {
      _auditEvents.removeAt(0);
    }
    // P0-B B4：广播给管理 UI 订阅者（授权/撤销/远程判定实时刷新）。
    _auditController.add(record);
    _log.info(
      '[RemoteAuthorization] $event channel=$channelType chat=$chatId '
      'user=$userId ${safeDetail ?? ''}',
    );
    // P0-B B3：持久化审计（最佳努力，fire-and-forget）。写入失败仅记录，
    // 绝不影响已做出的授权判定（授权决策先于审计，审计不在关键路径）。
    final store = _auditStore;
    if (store != null) {
      unawaited(
        store.append(record).catchError((Object error, StackTrace stackTrace) {
          _log.error(
            '[RemoteAuthorization] audit persist failed event=$event '
            'error=$error',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    }
  }

  /// 读取全部授权记录（原始 JSON 容错：损坏按空表处理，不阻断启动）。
  ///
  /// P0-A.2：存储读取失败（抛异常）同样按空表处理 → deny-by-default 拒绝，
  /// 不得把存储故障传播成未定义行为；调用方看到空表即拒绝，fail-closed。
  Future<List<RemoteAuthorizationRecord>> _loadAll() async {
    String? raw;
    _lastStoreReadError = null;
    try {
      raw = await _store.read(remoteChannelAuthorizationsKey);
    } catch (error, stackTrace) {
      _lastStoreReadError = '$error';
      _log.error(
        '[RemoteAuthorization] store read failed key=$remoteChannelAuthorizationsKey '
        'error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return const <RemoteAuthorizationRecord>[];
    }
    if (raw == null || raw.isEmpty) {
      return const <RemoteAuthorizationRecord>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <RemoteAuthorizationRecord>[];
      }
      return <RemoteAuthorizationRecord>[
        for (final item in decoded) ?RemoteAuthorizationRecord.fromJson(item),
      ];
    } catch (error, stackTrace) {
      _lastStoreReadError = '$error';
      _log.error(
        '[RemoteAuthorization] load failed key=$remoteChannelAuthorizationsKey '
        'error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return const <RemoteAuthorizationRecord>[];
    }
  }

  /// P0-A.2 统一远程执行门禁：复核「远程助手 enabled + 本地确认 remoteConfirmed」。
  ///
  /// - 未注入 runtimeStatusProvider（纯授权单元测试）→ 不叠加运行状态门禁，
  ///   返回 true，授权语义独立可验证。
  /// - 注入后：enabled && remoteConfirmed 才放行；读取失败或状态关闭一律
  ///   fail-closed 拒绝（安全侧）。
  Future<bool> _runtimeAllows() async {
    final provider = _runtimeStatusProvider;
    if (provider == null) {
      return true; // 生产必须注入；未注入仅见于纯授权测试。
    }
    try {
      return (await provider()).allowsRemote;
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteAuthorization] runtime status read failed — fail-closed '
        'error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  @override
  Future<bool> isMessageAuthorized({
    required String channelType,
    required String chatId,
    String? userId,
    String? jobId,
  }) async {
    if (chatId.isEmpty) {
      return false;
    }
    // P0-A.2 统一门禁：关闭远程 / 未本地确认 → 消息不得进入 Agent。
    if (!await _runtimeAllows()) {
      _audit(
        'deny_runtime',
        channelType,
        chatId,
        userId,
        'remote disabled or unconfirmed (fail-closed)',
        jobId: jobId,
      );
      return false;
    }
    final records = await _loadAll();
    MatchingResult? best;
    // P0-D D1：单次取基准时间，保证同一判定内一致性（避免跨阈值抖动）。
    final now = DateTime.now();
    for (final r in records) {
      if (r.isActiveAt(now, maxAge: _authorizationTtl) &&
          r.matches(channelType: channelType, chatId: chatId, userId: userId)) {
        // read scope 也能进入受限 Agent 会话 —— 会话内仅查询（只读工具），
        // 工具级拦截（A4）保证 read 用户不能触发任何写入。因此这里只需
        // 存在有效记录即可进入（任何 scope），写入能力由 A4 工具判定收紧。
        final result = MatchingResult(record: r, allowsMessage: true);
        if (best == null || _rank(result) > _rank(best)) {
          best = result;
        }
      }
    }
    final allowed = best != null;
    if (!allowed) {
      _audit(
        'deny_message',
        channelType,
        chatId,
        userId,
        'no valid authorization record',
        jobId: jobId,
      );
    } else {
      _audit(
        'allow_message',
        channelType,
        chatId,
        userId,
        'scope=${best.record.scope.name}',
        jobId: jobId,
      );
    }
    return allowed;
  }

  @override
  Future<bool> isToolAuthorized(
    String toolName, {
    required String channelType,
    required String chatId,
    String? userId,
    String? jobId,
  }) async {
    if (chatId.isEmpty) {
      return false;
    }
    // P0-A.2 统一门禁：关闭远程 / 未本地确认 → 任何远程工具不得执行。
    // 覆盖已运行 Job 的下一次敏感操作（start_job/send_to_job 的
    // jobAuthGate/resumeAuthGate 与 _AuthorizationRecheckHook 都经本方法）。
    if (!await _runtimeAllows()) {
      _audit(
        'deny_runtime',
        channelType,
        chatId,
        userId,
        'tool=$toolName remote disabled or unconfirmed (fail-closed)',
        jobId: jobId,
      );
      return false;
    }
    // 未知工具默认拒绝：工具未在分类表中即视为不被批准，不得因缺省映射
    // 而放行（P0-A.1 任务 2）。只有当工具名在已批准清单内才继续判定 scope。
    final action = _actionForTool(toolName);
    if (action == null) {
      _audit(
        'deny_tool',
        channelType,
        chatId,
        userId,
        'tool=$toolName action=unknown-tool-rejected',
        jobId: jobId,
      );
      return false;
    }
    final records = await _loadAll();
    MatchingResult? best;
    final now = DateTime.now();
    for (final r in records) {
      if (r.isActiveAt(now, maxAge: _authorizationTtl) &&
          r.matches(channelType: channelType, chatId: chatId, userId: userId)) {
        final result = MatchingResult(
          record: r,
          allowsMessage: r.allows(action),
        );
        if (best == null || _rank(result) > _rank(best)) {
          best = result;
        }
      }
    }
    final allowed = best?.allowsMessage ?? false;
    if (!allowed) {
      _audit(
        'deny_tool',
        channelType,
        chatId,
        userId,
        'tool=$toolName action=$action',
        jobId: jobId,
      );
    } else {
      _audit(
        'allow_tool',
        channelType,
        chatId,
        userId,
        'tool=$toolName action=$action scope=${best!.record.scope.name}',
        jobId: jobId,
      );
    }
    return allowed;
  }

  /// 后台 Job 授权复核的统一判定（P0-A 正式验收 V1.1 / V1.2 收紧，
  /// P0-B 任务 B0 扩展 Run 子命令级授权）。
  ///
  /// 远程 Job（start_job / send_to_job）启动的后台 turn，其工具链
  /// （orchestrator / 子 Agent / MCP / Plugin / 内置工具）不经过远程
  /// Assistant 的 A4 逐工具拦截；本方法供 Job 的授权 gate 统一判定：
  /// - [toolName] 为 null（turn 入口复核）→ 按 [jobToolName]（Job 运行权）
  ///   判定；
  /// - [toolName] 为 `Run` 且 [toolArguments] 解析出 command/subcommand →
  ///   **子命令级正向授权（P0-B.1 S1）**：按 [RunPermissionPolicy] 五维规则
  ///   （工具名+子命令+操作类型+作品归属+远程 scope）判定，仅允许经明确
  ///   审核的 novel 写作子命令；未知/未分类/外部执行/未审核写一律
  ///   fail-closed 拒绝（禁用 B0 黑名单策略）；
  /// - [toolName] 在已批准远程工具清单内 → 按该工具逐工具复核
  ///   （未知工具由 [isToolAuthorized] 默认拒绝）；
  /// - [toolName] 在 [jobOrchestrationCapabilities]（明确、可审计的编排
  ///   能力白名单）内 → 回退 [jobToolName] 判定——这些是 Job 执行任务
  ///   的自然必要组成（如 `Run` 执行写作命令），其工具边界由 Job 级
  ///   远程复核共同约束；
  /// - 其余工具名（SpawnAgent / Create / Write / Edit / MCP / Plugin /
  ///   任意未知工具）→ **默认拒绝（fail-closed）**，不得仅凭 Job 运行
  ///   权执行——P0-A 正式验收 V1.2：未经明确允许的工具不得只凭 Job
  ///   写入权限执行。
  ///
  /// [toolArguments] 为即将执行工具的参数（来自
  /// `BeforeToolCallContext.call.arguments`），仅当 [toolName] == `Run` 时
  /// 用于解析 command/subcommand（含 Run 的防呆结构：command/subcommand
  /// 可能嵌套在 `options` 中）。本地路径（无远程 Job）传 null。
  Future<bool> isJobToolAuthorized(
    String jobToolName, {
    String? toolName,
    Map<String, dynamic>? toolArguments,
    required String channelType,
    required String chatId,
    String? userId,
    String? jobId,
    String? workId,
  }) async {
    // P0-B.1 S1：Run 子command级正向授权 —— 替换 B0 黑名单为正向白名单。
    // 未知/未分类/外部执行/未审核写一律 fail-closed 拒绝（RunPermissionPolicy）。
    // P0-B.2：toolName == 'Run' 无条件进入正向策略；command/subcommand 缺失
    // 不得回落 Job 运行权（禁止通过省略参数绕过正向策略）。
    if (toolName == 'Run') {
      final runCommand = toolArguments == null
          ? null
          : _parseRunArgument(toolArguments, 'command');
      final runSubcommand = toolArguments == null
          ? null
          : _parseRunArgument(toolArguments, 'subcommand');
      if (runCommand == null || runCommand.isEmpty) {
        _audit(
          'deny_tool',
          channelType,
          chatId,
          userId,
          'run=Run missing command code=run_missing_arguments (positive policy)',
          jobId: jobId,
        );
        return false;
      }
      if (runCommand == 'help' || runCommand == '--help') {
        // help/--help：纯只读帮助文本，不构成任何执行/写操作，安全放行
        // （随后沿 Job 运行权复核，避免 read-scope 用户借 help 越权）。
      } else if (runSubcommand == null || runSubcommand.isEmpty) {
        _audit(
          'deny_tool',
          channelType,
          chatId,
          userId,
          'run=$runCommand missing subcommand '
          'code=run_missing_subcommand (positive policy)',
          jobId: jobId,
        );
        return false;
      } else {
        final scopeName = await _effectiveScopeName(
          channelType,
          chatId,
          userId,
        );
        final decision = RunPermissionPolicy.evaluate(
          command: runCommand,
          subcommand: runSubcommand,
          workId: workId,
          scope: RunPolicyScope.fromName(scopeName),
        );
        if (!decision.isAllowed) {
          _audit(
            'deny_tool',
            channelType,
            chatId,
            userId,
            'run=$runCommand.$runSubcommand code=${decision.code} '
            '(positive policy)',
            jobId: jobId,
          );
          return false;
        }
        // P0-B.3 任务2：作品域资源操作（read 或 write，目标资源位于当前作品
        // 内）必须通过目标资源归属校验——防止作品 A 的 Job 读/改/删作品 B 的
        // 资源（跨作品）。策略已保证作品域**写**操作绑定明确 workId（非空，
        // work_not_bound 拒绝）；此处对作品域资源操作统一校验工具参数声明的
        // 目标作品 ID 与可信作品 ID 一致（或资源天然绑定可信作品）；校验
        // 失败/无法解析归属一律拒绝（deny-by-default 安全侧）。全局资源
        // （styles/themes/subagents/agent-rules/agent-skills/operations.cancel）
        // 无作品归属，走独立能力分类（globalWrite），不做本校验。
        if (RunPermissionPolicy.workScopedOperations.contains(
          '$runCommand.$runSubcommand',
        )) {
          final verifier =
              _resourceVerifier ?? const DefaultRunResourceVerifier();
          final owned = await verifier.verifyWorkResource(
            workId: workId,
            command: runCommand,
            subcommand: runSubcommand,
            toolArguments: toolArguments,
          );
          if (!owned) {
            _audit(
              'deny_tool',
              channelType,
              chatId,
              userId,
              'run=$runCommand.$runSubcommand code=resource_not_owned '
              '(cross-work access rejected)',
              jobId: jobId,
            );
            return false;
          }
        }
        // P0-B.3 任务3：受控通知（Run notify progress/question/complete/error）
        // 在策略放行后仍需通过受控约束——仅允许向当前 Job 绑定会话发送，
        // 不得指定任意目标用户/渠道；消息长度受限（超长拒绝）。频率/敏感
        // 信息限制由运行时 notifyCallback 执行（见 notify_controls.dart）。
        if (decision.operationType == RunOperationType.notify) {
          final targetViolation = notifyTargetViolation(toolArguments);
          if (targetViolation != null) {
            _audit(
              'deny_tool',
              channelType,
              chatId,
              userId,
              'run=$runCommand.$runSubcommand code=$targetViolation '
              '(controlled notify: no arbitrary target)',
              jobId: jobId,
            );
            return false;
          }
          final lengthViolation = notifyLengthViolation(toolArguments);
          if (lengthViolation != null) {
            _audit(
              'deny_tool',
              channelType,
              chatId,
              userId,
              'run=$runCommand.$runSubcommand code=$lengthViolation '
              '(controlled notify: content too long)',
              jobId: jobId,
            );
            return false;
          }
        }
      }
    }
    // 入口复核（null）或明确的编排能力 → 按 Job 运行权判定。
    if (toolName == null ||
        toolName.isEmpty ||
        jobOrchestrationCapabilities.contains(toolName)) {
      return isToolAuthorized(
        jobToolName,
        channelType: channelType,
        chatId: chatId,
        userId: userId,
        jobId: jobId,
      );
    }
    // 已批准远程工具 → 逐工具复核（未知工具由 isToolAuthorized 默认拒绝）。
    return isToolAuthorized(
      toolName,
      channelType: channelType,
      chatId: chatId,
      userId: userId,
      jobId: jobId,
    );
  }

  /// P0-B.1 S1：Run 子命令授权已改为正向白名单（[RunPermissionPolicy]），
  /// 不再使用 B0 黑名单（runSensitiveSubcommands）——黑名单已移除，防止
  /// 策略漂移（未列出的子命令在正向策略下默认拒绝，安全侧）。

  /// 从 Run 参数中解析 command/subcommand（兼容 Run 防呆结构：顶层缺失时
  /// 回捞 `options` 里的同名键）。仅返回非空字符串；无则 null。
  String? _parseRunArgument(Map<String, dynamic> arguments, String key) {
    final direct = arguments[key];
    if (direct is String && direct.isNotEmpty) {
      return direct;
    }
    final options = arguments['options'];
    if (options is Map) {
      final nested = options[key];
      if (nested is String && nested.isNotEmpty) {
        return nested;
      }
    }
    return null;
  }

  /// 解析当前渠道身份的有效授权 scope（all > write > read 取最大匹配项）。
  Future<String?> _effectiveScopeName(
    String channelType,
    String chatId,
    String? userId,
  ) async {
    final records = await _loadAll();
    RemoteAuthorizationRecord? best;
    int rankOf(RemoteAuthorizationRecord r) {
      switch (r.scope) {
        case RemotePermissionScope.all:
          return 3;
        case RemotePermissionScope.write:
          return 2;
        case RemotePermissionScope.read:
          return 1;
      }
    }

    final now = DateTime.now();
    for (final r in records) {
      if (r.isActiveAt(now, maxAge: _authorizationTtl) &&
          r.matches(channelType: channelType, chatId: chatId, userId: userId)) {
        if (best == null || rankOf(r) > rankOf(best)) {
          best = r;
        }
      }
    }
    return best?.scope.name;
  }

  @override
  Future<void> authorizeRemoteUser({
    required String channelType,
    required String chatId,
    String? userId,
    required RemotePermissionScope scope,
    String? displayName,
    String grantedBy = 'local_user',
    bool allowSessionWide = false,
  }) async {
    if (chatId.isEmpty) {
      throw ArgumentError('chatId must not be empty');
    }
    // 群聊/身份不可验证的会话，不允许共享会话级授权（userId 为空）。
    // 仅当调用方显式声明该会话身份可验证（allowSessionWide）才放行。
    // 微信渠道的入站消息 userId == chatId（私聊），可验证。
    if (userId == null && !allowSessionWide) {
      throw ArgumentError(
        'session-wide authorization is disabled by default: '
        'require a verified userId or explicitly allow session-wide',
      );
    }
    // M2 行级 upsert（P0-B.1）：同一 (channelType, chatId, userId) 覆盖为
    // 最新授权，由存储层事务 + 部分唯一索引保证——不再走
    // 「读全表 → 改列表 → DELETE ALL → INSERT ALL」全表替换（旧实现会在
    // 并发撤销与重新授权交错时用旧快照覆盖已撤销记录）。
    await _store.upsert(
      RemoteAuthorizationRecord(
        channelType: channelType,
        chatId: chatId,
        userId: userId,
        scope: scope,
        grantedAt: DateTime.now(),
        displayName: displayName,
        grantedBy: grantedBy,
      ),
    );
    _audit(
      'grant',
      channelType,
      chatId,
      userId,
      'scope=${scope.name} by=$grantedBy',
    );
  }

  @override
  Future<void> revokeRemoteUser({
    required String channelType,
    required String chatId,
    String? userId,
    String revokedBy = 'local_user',
  }) async {
    // M2 行级软撤销（P0-B.1）：仅置被匹配活动记录的 revoked_at，保留记录
    // 与审计，不再走全表替换。并发授权不会被旧快照覆盖（行级事务）。
    final revoked = await _store.revoke(
      channelType: channelType,
      chatId: chatId,
      userId: userId,
      at: DateTime.now(),
    );
    if (revoked) {
      _audit('revoke', channelType, chatId, userId, 'by=$revokedBy');
    }
  }

  @override
  Future<List<RemoteAuthorizationRecord>> listAuthorizations({
    String? channelType,
    String? chatId,
  }) async {
    final records = await _loadAll();
    return [
      for (final r in records)
        if ((channelType == null || r.channelType == channelType) &&
            (chatId == null || r.chatId == chatId))
          r,
    ];
  }

  /// 管理 UI 用的授权列表读取（P0-B B4：区分「确无授权」与「存储读取失败」）。
  ///
  /// 判定语义与 [listAuthorizations] 完全一致（fail-closed：存储故障返回空表），
  /// 额外附带读取错误快照。UI 在 [AuthorizationListSnapshot.error] 非空时展示
  /// 存储错误提示，而非误导性的「暂无授权」空态。
  Future<AuthorizationListSnapshot> listAuthorizationsDetailed({
    String? channelType,
    String? chatId,
  }) async {
    final records = await listAuthorizations(
      channelType: channelType,
      chatId: chatId,
    );
    // 紧跟读取后取错误快照：并发授权判定可能覆盖本字段，但仅为提示，
    // 不影响授权判定语义（fail-closed 路径不依赖本字段）。
    return AuthorizationListSnapshot(records: records, error: _lastStoreReadError);
  }

  /// 审计事件查询（P0-B B4：管理 UI 事件列表，含类型筛选）。
  ///
  /// 注入 [RemoteAuthorizationAuditStore] 时落库查询（`remote_authorization_audit`
  /// 表，按 `at` 倒序）；未注入（纯授权单元测试）时回退内存环形缓冲
  /// [_auditEvents]，语义一致（最新在前）。事件筛选 [eventTypes] 下沉到存储层
  /// （见 [RemoteAuthorizationAuditStore.query]）。
  Future<List<RemoteAuthorizationAuditEvent>> queryAuditEvents({
    DateTime? since,
    DateTime? until,
    String? channelType,
    String? chatId,
    String? userId,
    String? jobId,
    Set<String>? eventTypes,
    int limit = 200,
  }) async {
    final store = _auditStore;
    if (store != null) {
      return store.query(
        since: since,
        until: until,
        channelType: channelType,
        chatId: chatId,
        userId: userId,
        jobId: jobId,
        eventTypes: eventTypes,
        limit: limit,
      );
    }
    // 无审计存储（纯授权测试）：内存缓冲过滤（oldest→newest，取最新在前）。
    final filtered = _auditEvents.where((e) {
      if (since != null && e.at.isBefore(since)) {
        return false;
      }
      if (until != null && !e.at.isBefore(until)) {
        return false;
      }
      if (channelType != null && e.channelType != channelType) {
        return false;
      }
      if (chatId != null && e.chatId != chatId) {
        return false;
      }
      if (userId != null && e.userId != userId) {
        return false;
      }
      if (jobId != null && e.jobId != jobId) {
        return false;
      }
      if (eventTypes != null &&
          eventTypes.isNotEmpty &&
          !eventTypes.contains(e.event)) {
        return false;
      }
      return true;
    });
    final newestFirst = filtered.toList(growable: false).reversed;
    if (limit > 0) {
      return newestFirst.take(limit).toList(growable: false);
    }
    return newestFirst.toList(growable: false);
  }

  /// 已批准（可授权判定）的远程工具名清单。
  ///
  /// 与 [AssistantToolDispatcher] 的工具定义一一对应；未列入的工具名一律
  /// 视为「未知工具 → 默认拒绝」，不因缺省分类映射而放行（P0-A.1 任务 2）。
  static const Set<String> approvedToolNames = {
    'list_novels',
    'start_job',
    'job_status',
    'send_to_job',
    'create_novel',
    'edit_novel',
    'list_chapters',
  };

  /// 后台 Job 编排能力白名单（P0-A 正式验收 V1.2）。
  ///
  /// 仅这些**明确、可审计**的编排工具允许回退 [jobToolName]（Job 运行权）
  /// 判定；其余任何非批准工具名（SpawnAgent / Create / Write / Edit /
  /// MCP / Plugin / 未知工具）一律默认拒绝，不得仅凭 Job 写入权限执行。
  ///
  /// - `Run`：Job 执行写作任务的核心载体（含 Run notify 进度上报）。
  ///   它是 Job 自然必要的执行原语，与「运行 Job」这一授权语义一一对应。
  ///
  /// 注：`Run` 虽能执行命令，但其权限边界由本机 Agent 工具系统 +
  /// Job 级远程复核共同约束；任何扩权（如允许 SpawnAgent / MCP / Plugin）
  /// 必须显式加入本清单，并有对应授权审计（P0-A V1.2 验收标准 4）。
  static const Set<String> jobOrchestrationCapabilities = {
    'Run',
  };

  /// 工具名 → 动作维度分类（与 [AssistantToolDispatcher] 的工具清单一一对应；
  /// 未知工具返回 null —— 默认拒绝，安全侧）。
  RemoteAction? _actionForTool(String toolName) {
    switch (toolName) {
      case 'list_novels':
      case 'job_status':
      case 'list_chapters':
        return RemoteAction.read;
      case 'start_job':
      case 'send_to_job':
      case 'create_novel':
      case 'edit_novel':
        return RemoteAction.write;
      default:
        // 未知工具：不分类，交由 isToolAuthorized 前置拒绝。
        return null;
    }
  }

  /// 匹配记录挑选：all > write > read（多记录并存时取权限最大的匹配项）。
  int _rank(MatchingResult result) {
    switch (result.record.scope) {
      case RemotePermissionScope.all:
        return 3;
      case RemotePermissionScope.write:
        return 2;
      case RemotePermissionScope.read:
        return 1;
    }
  }
}

class MatchingResult {
  MatchingResult({required this.record, required this.allowsMessage});

  final RemoteAuthorizationRecord record;
  final bool allowsMessage;
}
