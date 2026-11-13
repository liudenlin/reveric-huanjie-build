// 职责: 验证 RemoteAuthorizationService 统一授权判定 — deny-by-default、身份绑定、
//       scope 读写分离、撤销与审计。纯 Dart 内存 store，不依赖数据库/Flutter。
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
//   lib/shared/services/remote/channel_adapter.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';

/// 内存授权存储 — 不触达 app_settings / 数据库，纯 Dart。
class _MemoryStore extends RemoteAuthorizationStore {
  final Map<String, String> _data = {};
  @override
  Future<String?> read(String key) async => _data[key];
  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }
}

void main() {
  const channel = 'wechat';
  const chatA = 'wxid_alice';
  const chatB = 'wxid_bob';
  const userA = 'wxid_alice';

  group('RemoteAuthorizationService.isMessageAuthorized — deny-by-default', () {
    test('无任何授权记录 → 拒绝（默认拒绝）', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      // 拒绝应产生审计事件
      expect(service.auditEvents.any((e) => e.event == 'deny_message'), isTrue);
    });

    test('空 chatId → 拒绝，不崩溃', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      expect(
        await service.isMessageAuthorized(channelType: channel, chatId: ''),
        isFalse,
      );
    });
  });

  group('身份绑定与串权防护', () {
    test('授权 chatA 后，chatB 仍被拒绝（不同会话不串权）', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.all,
      );
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatB,
          userId: 'wxid_bob',
        ),
        isFalse,
      );
    });

    test('不同渠道类型不串权', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: 'wechat',
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.all,
      );
      expect(
        await service.isMessageAuthorized(
          channelType: 'telegram',
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });

    test('会话级授权（userId=null）需显式 allowSessionWide（P0-A.1 任务 3）', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      // 群聊/身份未验证场景：默认抛错，禁止共享会话级授权。
      await expectLater(
        service.authorizeRemoteUser(
          channelType: channel,
          chatId: chatA,
          scope: RemotePermissionScope.all,
        ),
        throwsArgumentError,
      );
      // 显式声明会话身份可验证（allowSessionWide: true）才允许。
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        scope: RemotePermissionScope.all,
        allowSessionWide: true,
      );
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: 'any_member',
        ),
        isTrue,
      );
      // 会话级授权不可串到其他会话。
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatB,
          userId: 'any_member',
        ),
        isFalse,
      );
    });
  });

  group('scope 读写分离', () {
    test('read scope 允许消息进入受限 Agent 会话（P0-A.1 任务 2）', () async {
      // 任务 2 语义修正：read 授权可进会话做只读操作（list_novels/job_status/
      // list_chapters），写入能力由工具级拦截（isToolAuthorized）收紧——
      // 会话内只能调已批准只读工具，不能触发任何写入。
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      // 会话内只读工具放行、写入工具拒绝（A4 工具级收紧）
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
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });

    test('write scope 允许消息进入 Agent', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
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
  });

  group('RemoteAuthorizationService.isToolAuthorized', () {
    test('read scope：只读工具放行，写入工具拒绝', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      // 只读工具 → 放行
      expect(
        await service.isToolAuthorized(
          'list_novels',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      // 写入工具 → 拒绝
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });

    test('write scope：读与写工具均放行', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      expect(
        await service.isToolAuthorized(
          'create_novel',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      expect(
        await service.isToolAuthorized(
          'job_status',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });

    test('未授权工具一律拒绝（默认拒绝）', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });

    test('未知工具默认拒绝，不得因缺省分类映射放行（P0-A.1 任务 2）', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.all,
      );
      // all scope 下未知工具也必须拒绝（_actionForTool 返回 null → 前置拒绝）。
      for (final tool in [
        'Run',
        'SpawnAgent',
        'start_job_evil',
        'list_novels_extended',
        'mcp__foo__bar',
        'unknown_tool',
      ]) {
        expect(
          await service.isToolAuthorized(
            tool,
            channelType: channel,
            chatId: chatA,
            userId: userA,
          ),
          isFalse,
          reason: 'unknown tool should be rejected even under all scope: $tool',
        );
        expect(
          service.auditEvents.any(
            (e) =>
                e.event == 'deny_tool' &&
                (e.detail ?? '').contains('unknown-tool-rejected'),
          ),
          isTrue,
          reason: 'audit should record unknown-tool-rejected for: $tool',
        );
      }
    });

    test('approvedToolNames 与 7 个远程工具一一对应', () {
      expect(RemoteAuthorizationService.approvedToolNames, {
        'list_novels',
        'start_job',
        'job_status',
        'send_to_job',
        'create_novel',
        'edit_novel',
        'list_chapters',
      });
      // 本地 AI chat 工具（Run/SpawnAgent 等）不在远程已批准清单内 ——
      // 远程 Assistant 无法调用本地强权工具，防止子 Agent/嵌套工具绕过。
      expect(
        RemoteAuthorizationService.approvedToolNames.contains('Run'),
        isFalse,
      );
      expect(
        RemoteAuthorizationService.approvedToolNames.contains('SpawnAgent'),
        isFalse,
      );
    });

    test('撤销后已运行的 Job 在下次判定时立即拒绝（每次判定实时读存储）', () async {
      // 撤销（软撤销置 revokedAt）后，已运行 Job 的任何下一次授权判定
      // （消息进入 / 工具执行 / 后台复核 gate 复用同一判定）都返回 false。
      final store = _MemoryStore();
      final service = RemoteAuthorizationService(store);
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      // 模拟 Job 运行中：授权仍有效时 gate 通过
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      // 运行中撤销授权
      await service.revokeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
      );
      // 下一次敏感操作（后台 gate 同源判定）立即拒绝
      expect(
        await service.isToolAuthorized(
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
      // 重新授权后 gate 恢复通过 —— 撤销/再授权是本地可信操作
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
        isTrue,
      );
    });
  });

  group('撤销与审计', () {
    test('撤销后拒绝新的消息与工具执行', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.all,
      );
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
      await service.revokeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
      );
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
          'start_job',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });

    test('grant / revoke 均产生审计事件', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      await service.revokeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
      );
      expect(service.auditEvents.any((e) => e.event == 'grant'), isTrue);
      expect(service.auditEvents.any((e) => e.event == 'revoke'), isTrue);
    });

    test('重新授权（grant 同身份）覆盖旧授权，撤销后再次 grant 生效', () async {
      final service = RemoteAuthorizationService(_MemoryStore());
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.all,
      );
      // 覆盖为 all
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });
  });

  group('持久化往返（app_settings 兼容）', () {
    test('JSON 编解码往返保真', () async {
      final store = _MemoryStore();
      final service = RemoteAuthorizationService(store);
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.all,
        displayName: 'Alice',
        grantedBy: 'local_settings_ui',
      );
      // 新实例从同一 store 读取（模拟重启）
      final reloaded = RemoteAuthorizationService(store);
      final records = await reloaded.listAuthorizations(
        channelType: channel,
        chatId: chatA,
      );
      expect(records, hasLength(1));
      expect(records.single.userId, userA);
      expect(records.single.scope, RemotePermissionScope.all);
      expect(records.single.grantedBy, 'local_settings_ui');
      expect(
        await reloaded.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });

    test('损坏 JSON → 按空表处理，不崩溃', () async {
      final store = _MemoryStore();
      store._data[remoteChannelAuthorizationsKey] = '{invalid json';
      final service = RemoteAuthorizationService(store);
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isFalse,
      );
    });
  });
}
