// P0-B B4: 授权管理 UI 完善 —— 服务层支撑验证。
// 覆盖：queryAuditEvents（事件类型筛选 + 无审计存储回退内存缓冲）、
//       auditStream（授权/撤销/远程判定实时广播）、
//       listAuthorizationsDetailed（存储读取错误与正常快照）、
//       Drift 存储层事件类型筛选（DB 级，下沉过滤不失真）。
// 运行（隔离副本 cwd，需临时禁用 super_native_extensions hook + 清代理）:
//   fvm flutter test b4_ui_service_test.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/remote_authorization_audit_store.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';

/// 测试用授权存储（实现 RemoteAuthorizationStore），可注入读取失败。
class _MemoryStore extends RemoteAuthorizationStore {
  String? _value;

  /// 置 true 时 read 抛错（验证存储故障 → fail-closed + 错误提示）。
  bool failRead = false;

  @override
  Future<String?> read(String key) async {
    if (failRead) {
      throw StateError('forced store read failure');
    }
    return _value;
  }

  @override
  Future<void> write(String key, String value) async {
    _value = value;
  }
}

/// 测试用审计存储（实现 RemoteAuthorizationAuditStore，含类型筛选）。
class _MemoryAuditStore implements RemoteAuthorizationAuditStore {
  final List<RemoteAuthorizationAuditEvent> events = [];

  @override
  Future<void> append(RemoteAuthorizationAuditEvent event) async {
    events.add(event);
  }

  @override
  Future<List<RemoteAuthorizationAuditEvent>> query({
    DateTime? since,
    DateTime? until,
    String? channelType,
    String? chatId,
    String? userId,
    String? jobId,
    Set<String>? eventTypes,
    int limit = 200,
  }) async {
    return [
      for (final e in events.reversed)
        if ((since == null || !e.at.isBefore(since)) &&
            (until == null || !e.at.isAfter(until)) &&
            (channelType == null || e.channelType == channelType) &&
            (chatId == null || e.chatId == chatId) &&
            (userId == null || e.userId == userId) &&
            (jobId == null || e.jobId == jobId) &&
            (eventTypes == null ||
                eventTypes.isEmpty ||
                eventTypes.contains(e.event)))
          e,
    ].take(limit).toList();
  }

  @override
  Future<int> cleanupBefore(DateTime cutoff) async {
    final before = events.length;
    events.removeWhere((e) => e.at.isBefore(cutoff));
    return before - events.length;
  }
}

/// 构造一条审计事件。
RemoteAuthorizationAuditEvent _event(
  String type,
  String chatId, {
  String? detail,
}) {
  return RemoteAuthorizationAuditEvent(
    event: type,
    channelType: 'wechat',
    chatId: chatId,
    userId: 'wxid_user',
    detail: detail,
    at: DateTime.now(),
  );
}

void main() {
  const channel = 'wechat';
  const chatA = 'wxid_alice';

  group('queryAuditEvents — 事件类型筛选（内存审计存储）', () {
    test('eventTypes 仅返回命中事件类型，最新在前', () async {
      final store = _MemoryStore();
      final audit = _MemoryAuditStore();
      final service = RemoteAuthorizationService(store, auditStore: audit);
      await audit.append(_event('grant', chatA));
      await audit.append(_event('deny_message', chatA));
      await audit.append(_event('allow_tool', chatA));
      await audit.append(_event('deny_tool', chatA));

      final denied = await service.queryAuditEvents(
        eventTypes: {'deny_message', 'deny_tool'},
      );
      expect(denied.map((e) => e.event).toList(), ['deny_tool', 'deny_message']);

      final all = await service.queryAuditEvents();
      expect(all.map((e) => e.event).toList(), [
        'deny_tool',
        'allow_tool',
        'deny_message',
        'grant',
      ]);
    });

    test('无审计存储时回退内存环形缓冲，语义一致', () async {
      // 不注入 auditStore → 纯授权服务，审计仅内存缓冲。
      final store = _MemoryStore();
      final service = RemoteAuthorizationService(store);
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: 'wxid_user',
        scope: RemotePermissionScope.write,
        grantedBy: 'test',
      );
      await service.isMessageAuthorized(
        channelType: channel,
        chatId: chatA,
        userId: 'wxid_user',
      );
      // 判定放行（有授权）→ 内存缓冲含 grant + allow_message。
      final all = await service.queryAuditEvents();
      expect(all.map((e) => e.event).toList(), contains('grant'));
      expect(all.map((e) => e.event).toList(), contains('allow_message'));
      // 类型筛选（内存层）。
      final grants = await service.queryAuditEvents(eventTypes: {'grant'});
      expect(grants.map((e) => e.event).toList(), ['grant']);
    });
  });

  group('auditStream — 实时广播', () {
    test('授权/撤销/远程判定均推送事件', () async {
      final store = _MemoryStore();
      final audit = _MemoryAuditStore();
      final service = RemoteAuthorizationService(store, auditStore: audit);
      final received = <String>[];
      final sub = service.auditStream.listen((e) => received.add(e.event));

      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: 'wxid_user',
        scope: RemotePermissionScope.write,
        grantedBy: 'test',
      );
      await service.isMessageAuthorized(
        channelType: channel,
        chatId: chatA,
        userId: 'wxid_user',
      );
      await service.revokeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: 'wxid_user',
        revokedBy: 'test',
      );
      await service.isMessageAuthorized(
        channelType: channel,
        chatId: chatA,
        userId: 'wxid_user',
      );

      // 广播流默认异步派发（sync:false）：冲刷事件队列后再断言/取消，
      // 避免 cancel 丢弃尚未派发的事件。
      await pumpEventQueue();
      await sub.cancel();
      expect(received, contains('grant'));
      expect(received, contains('allow_message'));
      expect(received, contains('revoke'));
      expect(received, contains('deny_message'));
    });
  });

  group('listAuthorizationsDetailed — 存储错误提示', () {
    test('存储读取失败 → error 非空且 records 为空（fail-closed）', () async {
      final store = _MemoryStore();
      store.failRead = true;
      final service = RemoteAuthorizationService(store);
      final snapshot = await service.listAuthorizationsDetailed();
      expect(snapshot.error, isNotNull);
      expect(snapshot.records, isEmpty);
    });

    test('读取正常 → error 为 null 且 records 就位', () async {
      final store = _MemoryStore();
      final service = RemoteAuthorizationService(store);
      await service.authorizeRemoteUser(
        channelType: channel,
        chatId: chatA,
        userId: 'wxid_user',
        scope: RemotePermissionScope.read,
        grantedBy: 'test',
      );
      final snapshot = await service.listAuthorizationsDetailed();
      expect(snapshot.error, isNull);
      expect(snapshot.records, hasLength(1));
      expect(snapshot.records.single.scope, RemotePermissionScope.read);
    });
  });

  group('Drift 审计存储 — DB 级事件类型筛选（真实表）', () {
    test('eventTypes 下沉到 SQL，历史事件按类型正确筛出', () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final store = DriftRemoteAuthorizationAuditStore(db);
      await store.append(_event('grant', chatA));
      await store.append(_event('deny_message', chatA));
      await store.append(_event('allow_tool', chatA));
      await store.append(_event('deny_tool', chatA));

      final denied = await store.query(eventTypes: {'deny_message', 'deny_tool'});
      expect(denied.map((e) => e.event).toList(), ['deny_tool', 'deny_message']);

      final grants = await store.query(eventTypes: {'grant'});
      expect(grants.map((e) => e.event).toList(), ['grant']);

      final all = await store.query();
      expect(all, hasLength(4));
    });
  });
}
