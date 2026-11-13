// 职责: 验证 P0-A.2 统一远程执行门禁 — 运行状态（enabled + remoteConfirmed）、
//       授权撤销/降级、存储读取失败 fail-closed、多用户/多会话不串权、
//       未知工具/MCP/Plugin/SpawnAgent 边界、本地写作不受影响。
//       P0-A 正式验收 V1.2：isJobToolAuthorized 只对 approvedToolNames +
//       jobOrchestrationCapabilities（Run）回退/复核，其余工具 fail-closed 拒绝。
//       纯 Dart 内存 store，不依赖数据库/Flutter。
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
//   lib/shared/services/remote/channel_adapter.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/remote/notify_controls.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';
import 'package:reveric/shared/services/remote/run_resource_verifier.dart';

/// 内存授权存储 — 不触达 app_settings / 数据库，纯 Dart。
class _MemoryStore extends RemoteAuthorizationStore {
  _MemoryStore({this.failReads = false});
  final bool failReads;
  final Map<String, String> _data = {};
  @override
  Future<String?> read(String key) async {
    if (failReads) {
      throw StateError('storage read failed');
    }
    return _data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }
}

RemoteAuthorizationService _service(
  RemoteAuthorizationStore store, {
  RemoteRuntimeStatus? status,
}) {
  return RemoteAuthorizationService(
    store,
    runtimeStatusProvider: status == null ? null : () async => status,
  );
}

void main() {
  const channel = 'wechat';
  const chatA = 'wxid_alice';
  const chatB = 'wxid_bob';
  const userA = 'wxid_alice';

  group('P0-A.2 统一门禁 — 运行状态（enabled + remoteConfirmed）', () {
    test('enabled=false 白名单仍有效 → 后台工具被拒绝（fail-closed）', () async {
      final store = _MemoryStore();
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(
          enabled: false,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // 白名单（授权记录）仍有效，但远程已关闭 → 任何工具都不得执行。
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      expect(
        await service.isToolAuthorized(
          'list_novels',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: '远程关闭时连只读工具也不得执行（已运行 Job 即刻冻结）',
      );
      // 消息进入同样拒绝。
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      // 审计事件记录运行状态拒绝。
      expect(service.auditEvents.any((e) => e.event == 'deny_runtime'), isTrue);
    });

    test('remoteConfirmed=false → 不能启动远程 Job（门禁打开前不执行）', () async {
      final store = _MemoryStore();
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: false,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // 历史 enabled=true 但未本地确认 → Job 启动工具被拒。
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });

    test('enabled && remoteConfirmed 均满足 → 正常放行（write 工具）', () async {
      final store = _MemoryStore();
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(enabled: true, remoteConfirmed: true),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      expect(
        await service.isToolAuthorized(
          'send_to_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });

    test('运行中 Job 时关闭远程（enabled true→false）→ 下一敏感操作被拒', () async {
      final store = _MemoryStore();
      var status = const RemoteRuntimeStatus(
        enabled: true,
        remoteConfirmed: true,
      );
      final service = RemoteAuthorizationService(
        store,
        runtimeStatusProvider: () async => status,
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // Job 启动时远程开启 → 放行（模拟 start_job 已授权启动）。
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      // 用户运行中关闭远程助手（enabled → false）。
      status = const RemoteRuntimeStatus(enabled: false, remoteConfirmed: true);
      // 下一次敏感操作（任何工具）立即被拒 —— 不依赖新授权，fail-closed。
      expect(
        await service.isToolAuthorized(
          'send_to_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      expect(
        await service.isToolAuthorized(
          'list_novels',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      expect(
        service.auditEvents.last.event,
        'deny_runtime',
        reason: '运行状态关闭应产生 deny_runtime 审计事件',
      );
    });
  });

  group('P0-A.2 门禁 — 撤销 / 降级后的执行行为', () {
    test('授权撤销后，正在运行的 Job 无法执行下一个敏感工具', () async {
      final store = _MemoryStore();
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(enabled: true, remoteConfirmed: true),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // Job 启动时已获授权。
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      // 运行中撤销授权（模拟用户在本地设置撤销）。
      await service.revokeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
      );
      // Job 的下一次敏感操作（写工具）被拒 —— 后台任务 fail-closed。
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      expect(
        await service.isToolAuthorized(
          'edit_novel',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });

    test('write 降级 read 后，所有写入和间接执行路径被拒，只读仍可', () async {
      final store = _MemoryStore();
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(enabled: true, remoteConfirmed: true),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      expect(
        await service.isToolAuthorized(
          'edit_novel',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      // 降级：重新授权为 read（同键覆盖）。
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      // 写入工具全部被拒。
      for (final writeTool in const [
        'start_job',
        'send_to_job',
        'create_novel',
        'edit_novel',
      ]) {
        expect(
          await service.isToolAuthorized(
            writeTool,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isFalse,
          reason: '降级 read 后写工具 $writeTool 必须被拒',
        );
      }
      // 间接执行路径：read 授权仍可进入受限 Agent 会话（P0-A.1 语义，
      // 消息级放宽——仅查询不触发写入），但会话内任何会写入的间接执行
      // 都由 A4 工具级拦截收紧（上方 writeTool 循环已验证）。这里验证
      // 消息级确实放行（read 可进），而会话内写工具全部被拒。
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
        reason: 'read 授权可进入受限 Agent 会话（仅查询），消息级放行',
      );
      // 只读工具仍放行。
      for (final readTool in const [
        'list_novels',
        'job_status',
        'list_chapters',
      ]) {
        expect(
          await service.isToolAuthorized(
            readTool,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isTrue,
          reason: '只读工具 $readTool 在 read scope 下应放行',
        );
      }
    });
  });

  group('P0-A.2 门禁 — 工具权限边界', () {
    test('未知工具、MCP、Plugin、SpawnAgent 一律拒绝（不在批准清单）', () async {
      final store = _MemoryStore();
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(enabled: true, remoteConfirmed: true),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.all,
      );
      // 即使 all scope，未批准的 MCP/Plugin/SpawnAgent/任意未知工具都拒绝。
      for (final unknownTool in const [
        'mcp_execute',
        'mcp_anything',
        'plugin_run',
        'spawn_agent',
        'agent_launch',
        'random_not_approved',
      ]) {
        expect(
          await service.isToolAuthorized(
            unknownTool,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isFalse,
          reason: '未知工具 $unknownTool 默认拒绝（any scope 不得放行）',
        );
      }
      // 审计事件记录 unknown-tool-rejected。
      expect(
        service.auditEvents.any(
          (e) =>
              e.event == 'deny_tool' &&
              (e.detail?.contains('unknown-tool-rejected') ?? false),
        ),
        isTrue,
      );
    });

    test('批准清单内工具名不被误拒（approvedToolNames 完整）', () async {
      expect(
        RemoteAuthorizationService.approvedToolNames,
        containsAll(<String>[
          'list_novels',
          'start_job',
          'job_status',
          'send_to_job',
          'create_novel',
          'edit_novel',
          'list_chapters',
        ]),
      );
    });
  });

  group('P0-A.2 门禁 — 串权防护', () {
    test('同一渠道不同用户不串权', () async {
      final store = _MemoryStore();
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(enabled: true, remoteConfirmed: true),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // 同会话不同 userId 不被放行。
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: 'other_user',
        ),
        isFalse,
        reason: '不同用户不共享同一授权（会话级记录除外）',
      );
      // 同会话同用户正常放行。
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });

    test('不同会话不串权', () async {
      final store = _MemoryStore();
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(enabled: true, remoteConfirmed: true),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatB,
          userId: userA,
        ),
        isFalse,
        reason: 'chatB 未授权，不因 chatA 的授权而放行',
      );
    });
  });

  group('P0-A.2 门禁 — 存储读取失败', () {
    test('授权存储读取失败时默认拒绝（fail-closed）', () async {
      final store = _MemoryStore(failReads: true);
      final service = _service(
        store,
        status: const RemoteRuntimeStatus(enabled: true, remoteConfirmed: true),
      );
      // 存储读失败 → 消息与工具都拒绝，不得放行。
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      expect(
        await service.isToolAuthorized(
          'list_novels',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });

    test('运行状态读取失败时默认拒绝（fail-closed）', () async {
      final store = _MemoryStore();
      final service = RemoteAuthorizationService(
        store,
        runtimeStatusProvider: () async =>
            throw StateError('status read failed'),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: '运行状态读取异常 → fail-closed 拒绝',
      );
    });
  });

  group('P0-A.2 本地写作不受远程门禁影响', () {
    test('未注入 runtimeStatusProvider（本地路径）→ 授权语义独立可用', () async {
      // 本地 Assistant（localMode）不注入运行状态 —— 授权服务回退到
      // 纯授权判定，本地编辑/保存/回滚不受影响。
      final store = _MemoryStore();
      final service = RemoteAuthorizationService(store);
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      expect(
        await service.isToolAuthorized(
          'list_novels',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      expect(
        await service.isToolAuthorized(
          'edit_novel',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: 'read scope 下写工具依然拒绝（本地路径同样跑授权判定）',
      );
    });
  });

  group('P0-A V1.1 — 后台 Job 工具级复核（isJobToolAuthorized）', () {
    test('入口复核（toolName=null）→ 按 Job 运行权判定', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // turn 入口：验证「该身份仍持有 Job 运行权」。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: null,
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });

    test('携带已批准工具名 → 逐工具复核（write 权可执行写工具）', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'edit_novel',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
        reason: 'write 权下已批准写工具被放行',
      );
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'list_novels',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
        reason: 'write 权下已批准只读工具被放行',
      );
    });

    test('read 降级 → 已批准写工具被拒、只读工具放行（逐工具复核生效）', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      // 已批准写工具：逐工具复核按 read scope 拒绝（间接写入路径被堵）。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'edit_novel',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: '降级 read 后已批准写工具被拒（间接执行路径也走授权判定）',
      );
      // 已批准只读工具：P0-A.1 语义 —— read 可进受限会话，只读工具放行。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'list_novels',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
        reason: 'read 降级后只读工具仍放行（受限会话语义）',
      );
      // Job 编排能力（Run，白名单内）回退 Job 运行权 → read 降级后 Job 中止。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: '降级 read 后 Job 编排工具沿 Job 运行权被拒 → 已运行 Job 中止',
      );
    });

    test('编排能力白名单（Run）→ 回退 Job 运行权判定', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // Run 是 Job 执行写作任务的核心载体（自然必要编排能力）：
      // 在明确白名单内 → 回退 Job 运行权（start_job）判定。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          // P0-B.2：Run 必须携带明确 command/subcommand 才进入正向策略，
          // 缺失参数 fail-closed 拒绝（禁止绕过）。此处用只读子命令
          // assets.list（read，不依赖 workId）验证「通过正向策略后，
          // Run 作为明确编排能力沿 Job 运行权放行」的语义保持不变。
          toolArguments: const {'command': 'assets', 'subcommand': 'list'},
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
        reason: 'write 权下编排能力 Run 沿 Job 运行权放行（明确白名单内）',
      );
    });

    test('编排能力白名单外工具（MCP/Plugin/SpawnAgent）→ fail-closed 拒绝', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // P0-A V1.2：未经明确允许的工具不得仅凭 Job 写入权限执行。
      // MCP / Plugin / SpawnAgent / Create / Write / Edit 均不在
      // jobOrchestrationCapabilities（仅 Run）→ 一律拒绝（fail-closed）。
      for (final tool in [
        'mcp__anything',
        'plugin__anything',
        'SpawnAgent',
        'ForkAgent',
        'Create',
        'Write',
        'Edit',
        'Replace',
        'Remove',
      ]) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: tool,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isFalse,
          reason: 'write 权下未明确允许的工具（$tool）不得沿 Job 运行权执行',
        );
      }
    });

    test('关闭远程后 Job 级逐工具复核一律拒绝（fail-closed）', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: false,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'edit_novel',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: '关闭远程后已运行 Job 的下一敏感工具被拒',
      );
    });

    test('未知工具名 → fail-closed 拒绝（不回退放行）', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // P0-A V1.2：任何不在 approvedToolNames 且不在 jobOrchestrationCapabilities
      // 的工具名，一律默认拒绝——不得因「名字像远程工具」或「回退 Job 权」
      // 而获得额外执行权限（fail-closed，白名单约束不在 orchestrator 层）。
      for (final tool in ['not_a_real_tool', 'TodoWrite', 'AgentSkill', 'Codemode']) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: tool,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isFalse,
          reason: '未知/未明确允许工具（$tool）不得沿 Job 运行权放行',
        );
      }
    });

    test('空串 toolName → 回退 Job 运行权（入口语义兼容）', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // 空串（非 null 但无工具名信息）→ 按 Job 运行权判定（与 null 一致）。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: '',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
        reason: '空串无工具名信息 → 回退 Job 运行权',
      );
    });

    test('send_to_job 续跑：编排能力 Run 沿 Job 运行权放行，其余拒绝', () async {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // send_to_job（续跑）作为 jobToolName 同样适用白名单语义。
      expect(
        await service.isJobToolAuthorized(
          'send_to_job',
          toolName: 'Run',
          // P0-B.2：Run 必须携带明确 command/subcommand（同 start_job 用例，
          // 用只读 assets.list 验证通过正向策略后沿 Job 运行权放行）。
          toolArguments: const {'command': 'assets', 'subcommand': 'list'},
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
        reason: '续跑 Job 的 Run 沿 send_to_job 运行权放行（白名单内）',
      );
      expect(
        await service.isJobToolAuthorized(
          'send_to_job',
          toolName: 'SpawnAgent',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: '续跑 Job 的 SpawnAgent 不在白名单 → fail-closed 拒绝',
      );
    });
  });

  group('P0-B B0 — Run 子命令级授权（isJobToolAuthorized + toolArguments）', () {
    RemoteAuthorizationService buildWriteService() {
      final service = _service(
        _MemoryStore(),
        status: const RemoteRuntimeStatus(
          enabled: true,
          remoteConfirmed: true,
        ),
      );
      return service;
    }

    test('Run mcp call → fail-closed 拒绝（任意外部 MCP 调用不得沿 Job 权执行）',
        () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // Run 本身是白名单编排能力（Job 运行权放行），但 mcp.call 是外部
      // 工具调用（Run 内部直接路由到 McpToolDispatcher，无本地门禁）——
      // B0 子命令级授权必须拦截。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'mcp',
            'subcommand': 'call',
            'options': {'name': 'filesystem', 'arguments': {'path': '/'}},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: 'write 权下 Run mcp call 必须被拒（外部调用 fail-closed）',
      );
      // 审计事件记录敏感子命令拒绝。
      expect(
        service.auditEvents.any(
          (e) =>
              e.event == 'deny_tool' &&
              (e.detail?.contains('run=mcp.call') ?? false) &&
              (e.detail?.contains('code=requires_explicit_review') ?? false),
        ),
        isTrue,
      );
    });

    test('Run files remove → fail-closed 拒绝（文件删除不得沿 Job 权执行）',
        () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'files',
            'subcommand': 'remove',
            'options': {'path': 'chapter/old.md', 'recursive': true},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: 'write 权下 Run files remove 必须被拒（危险写 fail-closed）',
      );
    });

    test('Run 其他写入命令（novel 数据写）→ 沿 Job 运行权放行（不无差别禁用）',
        () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // stagings write / editing apply / agent-rules create 是 Job 执行写作
      // 任务的自然必要组成 —— 沿 Job 运行权放行，不得因 B0 收紧而无差别禁用。
      for (final runArgs in const [
        {'command': 'stagings', 'subcommand': 'write', 'options': {'id': 's1'}},
        {'command': 'editing', 'subcommand': 'apply', 'options': {'id': 'e1'}},
        {
          'command': 'agent-rules',
          'subcommand': 'create',
          'options': {'name': 'Rule'},
        },
      ]) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: 'Run',
            toolArguments: runArgs,
            channelType: channel,
            chatId: chatA,
            userId: userA,
            // P0-B.2：写操作必须绑定明确作品（第 4 维真实生效）。
            workId: 'novel-1',
          ),
          isTrue,
          reason: 'novel 数据写子命令 ${runArgs['command']}.${runArgs['subcommand']} '
              '沿 Job 运行权放行（不无差别禁用 Run）',
        );
      }
      // P0-B.2：未绑定作品（workId null/空）的写操作一律拒绝（work_not_bound）。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'stagings',
            'subcommand': 'write',
            'options': {'id': 's2'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: null,
        ),
        isFalse,
        reason: '未绑定作品时 Run 写操作按第 4 维 fail-closed 拒绝',
      );
      // P0-B.1 S1 收紧：denied-codemode 子命令（map.draft 需直接 Run）
      // 不再沿 Job 运行权放行，改为正向策略拒绝（未分类/未允许 → fail-closed）。
      // P0-B.3 任务3：notify.* 已从 denied-codemode 移出（受控通知，正向分类），
      // 此处改用仍为 denied-codemode 的 map.draft 验证「未分类不沿 Job 运行权放行」。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'map',
            'subcommand': 'draft',
            'options': {'id': 'm1'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: 'denied-codemode 子命令 map.draft 按正向策略拒绝',
      );
    });

    test('Run 远程 notify 通道：受控通知（P0-B.3 任务3 恢复）', () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // notify 是 run agent 的进度/提问/完成/错误上报通道，P0-B.3 任务3 恢复
      // 为**受控**能力：write/all scope + 无任意目标 + 内容不超长 → 放行；
      // 指定任意目标/内容超长/read scope → 拒绝。
      for (final action in const ['progress', 'question', 'complete', 'error']) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: 'Run',
            toolArguments: {
              'command': 'notify',
              'subcommand': action,
              'options': {'content': 'msg'},
            },
            channelType: channel,
            chatId: chatA,
            userId: userA,
            workId: 'novel-1',
          ),
          isTrue,
          reason: '受控 notify.$action（write scope，无目标，不超长）应放行',
        );
      }
      // 指定任意目标用户 → 拒绝（notify_target_forbidden）。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'notify',
            'subcommand': 'progress',
            'options': {'content': '40%', 'target_chat_id': 'wxid_b'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'novel-1',
        ),
        isFalse,
        reason: '受控通知不得指定任意目标用户/渠道',
      );
      // 内容超长 → 拒绝（notify_too_long）。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: {
            'command': 'notify',
            'subcommand': 'progress',
            'options': {'content': 'x' * (notifyMaxContentLength + 1)},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'novel-1',
        ),
        isFalse,
        reason: '受控通知内容超长应拒绝',
      );
      // read scope → 拒绝（scope_denied）。
      final readService = buildWriteService();
      await readService.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      expect(
        await readService.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'notify',
            'subcommand': 'progress',
            'options': {'content': '40%'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'novel-1',
        ),
        isFalse,
        reason: 'read scope 下受控通知应拒绝（写入类能力）',
      );
    });

    test('Run help / --help → 只读帮助放行（不构成执行，P0-B.2 例外）', () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      for (final cmd in const ['help', '--help']) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: 'Run',
            toolArguments: {'command': cmd},
            channelType: channel,
            chatId: chatA,
            userId: userA,
            workId: 'novel-1',
          ),
          isTrue,
          reason: 'Run $cmd 只读帮助文本沿 Job 运行权放行（安全例外）',
        );
      }
    });

    test('Run 只读子命令（files.read / mcp 发现）→ 沿 Job 运行权放行', () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      for (final runArgs in const [
        {
          'command': 'files',
          'subcommand': 'read-text',
          'options': {'path': 'chapter/1.md'},
        },
      ]) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: 'Run',
            toolArguments: runArgs,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isTrue,
          reason: '只读子命令 ${runArgs['command']}.${runArgs['subcommand']} '
              '沿 Job 运行权放行',
        );
      }
      // P0-B.1 S1 收紧：mcp 发现子命令在 codemode 中被标记为 denied
      // （必须走 listMcpServers / searchTool / describeTool），正向策略拒绝。
      for (final runArgs in const [
        {'command': 'mcp', 'subcommand': 'list', 'options': {}},
        {'command': 'mcp', 'subcommand': 'search', 'options': {'query': 'x'}},
        {'command': 'mcp', 'subcommand': 'describe', 'options': {'name': 't'}},
      ]) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: 'Run',
            toolArguments: runArgs,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isFalse,
          reason: 'mcp 发现子命令 ${runArgs['subcommand']} 按正向策略拒绝',
        );
      }
    });

    test('Run 子命令嵌套在 options 内（防呆结构）→ 仍按敏感子命令拒绝', () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // Run 防呆：command/subcommand 可能被模型误嵌进 options。B0 解析
      // 必须兼容该结构，敏感子命令仍被拦截。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'options': {'command': 'mcp', 'subcommand': 'call'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: '嵌套 options 中的 mcp call 同样被拦截（防呆兼容）',
      );
      // 嵌套 options 中的非敏感子命令不被误拒。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'options': {'command': 'stagings', 'subcommand': 'write'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          // P0-B.2：写操作必须绑定明确作品。
          workId: 'novel-1',
        ),
        isTrue,
        reason: '嵌套 options 中的 stagings write 沿 Job 运行权放行',
      );
    });

    test('Run 参数缺失（无 command/无 subcommand）→ fail-closed 拒绝（P0-B.2）',
        () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // 仅有 command（无 subcommand）→ 无法归类 → 不得回落 Job 运行权，
      // 按正向策略 fail-closed 拒绝（P0-B.2 关闭参数缺失绕过通道）。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {'command': 'mcp'},
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'novel-1',
        ),
        isFalse,
        reason: 'Run 仅 command 无 subcommand → 必须 fail-closed 拒绝（不回退 Job 权）',
      );
      // 无任何参数（toolArguments null）→ 同样拒绝。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: null,
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'novel-1',
        ),
        isFalse,
        reason: 'Run 无参数 → 必须 fail-closed 拒绝',
      );
      // 空 command → 拒绝。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {'command': '', 'subcommand': 'list'},
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'novel-1',
        ),
        isFalse,
        reason: 'Run 空 command → 必须 fail-closed 拒绝',
      );
      // 非 Run 工具不因 toolArguments 误判。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'edit_novel',
          toolArguments: const {'command': 'mcp', 'subcommand': 'call'},
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'novel-1',
        ),
        isTrue,
        reason: '非 Run 工具不因含 Run 样子的参数被误判为敏感子命令',
      );
    });

    test('撤销后 Run mcp call → 拒绝（撤销立即失效，fail-closed）', () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // 撤销前敏感子命令已被拒。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'mcp',
            'subcommand': 'call',
            'options': {'name': 'filesystem'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      // 撤销授权后，即使非敏感 Run 子命令也沿 Job 运行权被拒。
      await service.revokeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
      );
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'stagings',
            'subcommand': 'write',
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
        reason: '撤销后 Job 运行权失效 → 所有 Run 子命令 fail-closed 拒绝',
      );
    });

    test('read 降级 → Run mcp call 与 Run stagings write 一律拒绝（Job 中止）',
        () async {
      final service = buildWriteService();
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // 降级为 read。
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      // Run（无论子命令）沿 Job 运行权（start_job 需 write）被拒 → Job 中止。
      for (final runArgs in const [
        {'command': 'mcp', 'subcommand': 'call'},
        {'command': 'stagings', 'subcommand': 'write'},
        {'command': 'files', 'subcommand': 'read-text'},
      ]) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: 'Run',
            toolArguments: runArgs,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isFalse,
          reason: '降级 read 后 Run 子命令 ${runArgs['command']}.${runArgs['subcommand']} '
              '沿 Job 运行权被拒（Job 中止）',
        );
      }
    });
  });

  group('P0-B.3 任务2 — 真实作品资源隔离（跨作品拒绝）', () {
    RemoteAuthorizationService buildWriteService({RunResourceVerifier? verifier}) {
      final store = _MemoryStore();
      final service = RemoteAuthorizationService(
        store,
        runtimeStatusProvider: () async =>
            const RemoteRuntimeStatus(enabled: true, remoteConfirmed: true),
        resourceVerifier: verifier,
      );
      return service;
    }

    Future<void> grantWrite(RemoteAuthorizationService service) {
      return service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
    }

    test('作品 A Job 改/删作品 B 资源 → 全部拒绝（跨作品写）', () async {
      final service = buildWriteService();
      await grantWrite(service);
      const workA = 'work-a';
      const workB = 'work-b';
      // 作品域写操作携带显式目标作品 = workB（≠ workA）→ 跨作品拒绝。
      for (final runArgs in const [
        {
          'command': 'stagings',
          'subcommand': 'write',
          'options': {'novelId': workB, 'id': 's1'},
        },
        {
          'command': 'stagings',
          'subcommand': 'apply',
          'options': {'novelId': workB, 'id': 's1'},
        },
        {
          'command': 'editing',
          'subcommand': 'apply',
          'options': {'novelId': workB, 'id': 'e1'},
        },
        {
          'command': 'editing',
          'subcommand': 'undo',
          'options': {'novelId': workB},
        },
        {
          'command': 'editing',
          'subcommand': 'redo',
          'options': {'novelId': workB},
        },
        {
          'command': 'novel',
          'subcommand': 'add-to-library',
          'options': {'novelId': workB},
        },
      ]) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: 'Run',
            toolArguments: runArgs,
            channelType: channel,
            chatId: chatA,
            userId: userA,
            workId: workA,
          ),
          isFalse,
          reason: '作品 A Job 不得改/删作品 B 资源：'
              '${runArgs['command']}.${runArgs['subcommand']}（跨作品）',
        );
      }
      // 审计事件记录跨作品拒绝。
      expect(
        service.auditEvents.any(
          (e) =>
              e.event == 'deny_tool' &&
              (e.detail?.contains('code=resource_not_owned') ?? false),
        ),
        isTrue,
        reason: '跨作品写拒绝应产生 resource_not_owned 审计事件',
      );
    });

    test('作品 A Job 读作品 B 资源 → 拒绝（跨作品读）', () async {
      final service = buildWriteService();
      await grantWrite(service);
      const workA = 'work-a';
      const workB = 'work-b';
      // 作品域读操作携带显式目标作品 = workB（≠ workA）→ 跨作品拒绝。
      for (final runArgs in const [
        {
          'command': 'files',
          'subcommand': 'read-text',
          'options': {'novelId': workB, 'path': 'chapter/1.md'},
        },
        {
          'command': 'assets',
          'subcommand': 'read',
          'options': {'novelId': workB, 'id': 'a1'},
        },
        {
          'command': 'stagings',
          'subcommand': 'read',
          'options': {'novelId': workB, 'id': 's1'},
        },
        {
          'command': 'editing',
          'subcommand': 'read',
          'options': {'novelId': workB, 'id': 'e1'},
        },
      ]) {
        expect(
          await service.isJobToolAuthorized(
            'start_job',
            toolName: 'Run',
            toolArguments: runArgs,
            channelType: channel,
            chatId: chatA,
            userId: userA,
            workId: workA,
          ),
          isFalse,
          reason: '作品 A Job 不得读作品 B 资源：'
              '${runArgs['command']}.${runArgs['subcommand']}（跨作品）',
        );
      }
    });

    test('正确作品目标（novelId == workId）与未声明目标 → 放行', () async {
      final service = buildWriteService();
      await grantWrite(service);
      const workA = 'work-a';
      // 显式目标 == 可信作品 → 放行。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'stagings',
            'subcommand': 'write',
            'options': {'novelId': workA, 'id': 's1'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: workA,
        ),
        isTrue,
        reason: '显式目标作品 == 可信作品 → 放行（归属一致）',
      );
      // 未显式声明目标作品 → 资源绑定可信作品 → 放行。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'editing',
            'subcommand': 'apply',
            'options': {'id': 'e1'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: workA,
        ),
        isTrue,
        reason: '未声明目标作品 → 资源绑定可信作品 → 放行',
      );
      // 作品域读 + 显式目标 == 可信作品 → 放行。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'files',
            'subcommand': 'read-text',
            'options': {'novelId': workA, 'path': 'chapter/1.md'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: workA,
        ),
        isTrue,
        reason: '作品域读 + 显式目标 == 可信作品 → 放行',
      );
    });

    test('显式目标作品但无可信作品（workId null）→ 拒绝（归属不可证）', () async {
      final service = buildWriteService();
      await grantWrite(service);
      // 作品域读 + 显式目标作品，但无可信作品（非 Job 上下文）→ 拒绝。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'files',
            'subcommand': 'read-text',
            'options': {'novelId': 'work-b', 'path': 'chapter/1.md'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: null,
        ),
        isFalse,
        reason: '显式目标作品但无可信作品 → 归属不可证 → 拒绝（安全侧）',
      );
    });

    test('全局写（styles.create）不因作品归属校验被误拒（独立能力分类）', () async {
      final service = buildWriteService();
      await grantWrite(service);
      // 全局写操作即使携带 novelId（模拟模型误带）也不做作品归属校验——
      // 它是无作品归属的全局资源，走 globalWrite 独立分类。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'styles',
            'subcommand': 'create',
            'options': {'novelId': 'work-b', 'name': 'Style'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'work-a',
        ),
        isTrue,
        reason: '全局写（styles.create）不要求作品归属，独立分类放行',
      );
      // 全局写 + read scope → 拒绝（scope 不足）。
      final readService = buildWriteService();
      await readService.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      expect(
        await readService.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'styles',
            'subcommand': 'create',
            'options': {'name': 'Style'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'work-a',
        ),
        isFalse,
        reason: '全局写 + read scope → scope_denied 拒绝',
      );
    });

    test('注入 DAO 风格 verifier：伪造/失效可信作品 → 拒绝（归属不可证）',
        () async {
      // 模拟 DAO 校验：仅当可信作品存在于「作品库」才放行。
      const knownWorks = {'work-a'};
      final verifier = _FakeRunResourceVerifier(knownWorks);
      final service = buildWriteService(verifier: verifier);
      await grantWrite(service);
      // 可信作品不存在（伪造）→ 拒绝。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'stagings',
            'subcommand': 'write',
            'options': {'id': 's1'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'work-fake',
        ),
        isFalse,
        reason: '可信作品不存在（DAO 校验失败）→ 归属不可证 → 拒绝',
      );
      // 可信作品存在 + 跨作品目标 → 拒绝。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'stagings',
            'subcommand': 'write',
            'options': {'novelId': 'work-b', 'id': 's1'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'work-a',
        ),
        isFalse,
        reason: 'DAO 校验：可信作品存在但目标为跨作品 → 拒绝',
      );
      // 可信作品存在 + 目标一致 → 放行。
      expect(
        await service.isJobToolAuthorized(
          'start_job',
          toolName: 'Run',
          toolArguments: const {
            'command': 'stagings',
            'subcommand': 'write',
            'options': {'novelId': 'work-a', 'id': 's1'},
          },
          channelType: channel,
          chatId: chatA,
          userId: userA,
          workId: 'work-a',
        ),
        isTrue,
        reason: 'DAO 校验：可信作品存在且目标一致 → 放行',
      );
    });
  });
}

/// P0-B.3 任务2：模拟 DAO 支撑的作品归属校验器（纯 Dart，供单测注入）。
class _FakeRunResourceVerifier implements RunResourceVerifier {
  _FakeRunResourceVerifier(this._knownWorks);

  final Set<String> _knownWorks;

  @override
  Future<bool> verifyWorkResource({
    required String? workId,
    required String command,
    required String subcommand,
    Map<String, dynamic>? toolArguments,
  }) async {
    // 可信作品必须存在（DAO 语义）。
    if (workId == null || workId.isEmpty || !_knownWorks.contains(workId)) {
      return false;
    }
    final target = extractTargetWorkId(toolArguments);
    if (target != null) {
      if (target != workId) {
        return false;
      }
      if (!_knownWorks.contains(target)) {
        return false;
      }
    }
    return true;
  }
}
