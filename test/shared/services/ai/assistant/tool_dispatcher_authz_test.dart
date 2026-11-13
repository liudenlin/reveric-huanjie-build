// 职责: 验证 AssistantToolDispatcher 的 A4 工具级授权拦截（P0-A.1 任务 2）—
//       注入 authorization 后未授权工具拒绝、授权工具放行；未注入（本地路径）不拦截。
// 关联文件:
//   lib/shared/services/ai/assistant/tool_dispatcher.dart
//   lib/shared/services/remote/remote_authorization_service.dart
// 说明: 由 coordinator 在构建 dispatcher 时把授权判定绑定到当前 turn 的渠道身份
//       （channelType/chatId/userId），验证 read/write scope 与渠道身份的失败关闭行为。
// 本测试从隔离包（autz_p0a）迁移并适配正式包名，纯 Dart 语义，不触达 DB/网络。

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/ai/assistant/tool_dispatcher.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';

/// 记录调用并返回固定结果的回调。
Future<Map<String, dynamic>> _ok(String key) async => {'ok': true, 'key': key};

/// 无授权注入（本地路径默认行为）。
AssistantToolDispatcher _localDispatcher() => AssistantToolDispatcher(
  listNovelsCallback: () async => [
    <String, dynamic>{'id': 'n1', 'title': 't'},
  ],
  startJobCallback: (id, seed) => _ok('start_job'),
  jobStatusCallback: (id) => _ok('job_status'),
  sendToJobCallback: (id, text) => _ok('send_to_job'),
  createNovelCallback: (novel) => _ok('create_novel'),
  editNovelCallback: (id, fields) => _ok('edit_novel'),
  listChaptersCallback: (id) => _ok('list_chapters'),
);

/// 绑定统一授权服务的 dispatcher（模拟 coordinator 注入 A4 策略）。
AssistantToolDispatcher _authorizedDispatcher(
  RemoteAuthorizationService authorization, {
  required String channelType,
  required String chatId,
  String? userId,
}) => AssistantToolDispatcher(
  listNovelsCallback: () async => [
    <String, dynamic>{'id': 'n1', 'title': 't'},
  ],
  startJobCallback: (id, seed) => _ok('start_job'),
  jobStatusCallback: (id) => _ok('job_status'),
  sendToJobCallback: (id, text) => _ok('send_to_job'),
  createNovelCallback: (novel) => _ok('create_novel'),
  editNovelCallback: (id, fields) => _ok('edit_novel'),
  listChaptersCallback: (id) => _ok('list_chapters'),
  authorization: (toolName) => authorization.isToolAuthorized(
    toolName,
    channelType: channelType,
    chatId: chatId,
    userId: userId,
  ),
);

void main() {
  const channel = 'wechat';
  const chatA = 'wxid_alice';
  const userA = 'wxid_alice';

  group('A4 — 未注入 authorization（本地路径）', () {
    test('所有工具正常执行，不拦截（无回归）', () async {
      final d = _localDispatcher();
      expect(
        await d.executeTool(
          name: 'start_job',
          input: {'novel_id': 'n1', 'seed': '写第三章'},
        ),
        containsPair('ok', true),
      );
      expect(
        await d.executeTool(name: 'list_novels', input: {}),
        containsPair('ok', true),
      );
      expect(
        await d.executeTool(name: 'create_novel', input: {'title': 'x'}),
        containsPair('ok', true),
      );
    });
  });

  group('A4 — write scope 授权', () {
    test('写入与只读工具均放行', () async {
      final svc = RemoteAuthorizationService(_inMemoryStore());
      await svc.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.write,
      );
      final d = _authorizedDispatcher(
        svc,
        channelType: channel,
        chatId: chatA,
        userId: userA,
      );
      // 写入工具放行
      final start = await d.executeTool(
        name: 'start_job',
        input: {'novel_id': 'n1', 'seed': '写第三章'},
      );
      expect(start, containsPair('ok', true));
      // 只读工具放行
      expect(
        await d.executeTool(name: 'list_novels', input: {}),
        containsPair('ok', true),
      );
    });
  });

  group('A4 — read scope 授权', () {
    test('只读工具放行，写入工具被拦截且不调用业务回调', () async {
      final svc = RemoteAuthorizationService(_inMemoryStore());
      await svc.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
      );
      final d = _authorizedDispatcher(
        svc,
        channelType: channel,
        chatId: chatA,
        userId: userA,
      );
      // 只读放行
      expect(
        await d.executeTool(name: 'list_novels', input: {}),
        containsPair('ok', true),
      );
      expect(
        await d.executeTool(name: 'job_status', input: {'job_id': 'j1'}),
        containsPair('ok', true),
      );
      // 写入工具被拦截，返回 not authorized
      final start = await d.executeTool(
        name: 'start_job',
        input: {'novel_id': 'n1', 'seed': '写第三章'},
      );
      expect(start, containsPair('ok', false));
      expect(start['error'], contains('not authorized'));
      // 拦截不调用业务回调（未落库）
      final create = await d.executeTool(
        name: 'create_novel',
        input: {'title': 'x'},
      );
      expect(create, containsPair('ok', false));
      expect(create['error'], contains('not authorized'));
    });
  });

  group('A4 — 未授权渠道身份', () {
    test('写授权仅对指定 chat 生效，其他 chat 全拒', () async {
      final svc = RemoteAuthorizationService(_inMemoryStore());
      await svc.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.all,
      );
      // 用 B 的身份调用 → 全拒（read 与 write 均不匹配渠道身份）
      final d = _authorizedDispatcher(
        svc,
        channelType: channel,
        chatId: 'wxid_bob',
        userId: 'wxid_bob',
      );
      expect(
        await d.executeTool(name: 'list_novels', input: {}),
        containsPair('ok', false),
      );
      expect(
        await d.executeTool(
          name: 'start_job',
          input: {'novel_id': 'n1', 'seed': 'x'},
        ),
        containsPair('ok', false),
      );
    });
  });
}

/// 内存授权存储（与授权服务测试共用语义，纯 Dart）。
class _InMemoryStore extends RemoteAuthorizationStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }
}

RemoteAuthorizationStore _inMemoryStore() => _InMemoryStore();
