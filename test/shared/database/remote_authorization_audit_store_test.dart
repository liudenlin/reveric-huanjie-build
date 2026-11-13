// P0-B B3（纳入仓库 test/shared/database）: 远程授权审计持久化（remote_authorization_audit 表）验证。
// 用内存 AppDatabase（NativeDatabase.memory，完整 v6 schema）跑真实 store，
// 验证：追加式 append、按时间/用户/渠道/Job 查询、保留期限清理、敏感详情
// 脱敏、审计写入失败不影响授权判定、服务层 grant/revoke/deny/allow 事件落库。
// 运行（隔离副本 cwd，需临时禁用 super_native_extensions hook + 清代理）:
//   fvm flutter test b3_audit_test.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/remote_authorization_audit_store.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';

/// 测试用内存授权存储（实现 RemoteAuthorizationStore）。
class _MemoryAuthStore extends RemoteAuthorizationStore {
  String? _value;

  @override
  Future<String?> read(String key) async => _value;

  @override
  Future<void> write(String key, String value) async => _value = value;
}

/// 测试用内存审计存储（实现 RemoteAuthorizationAuditStore，记录调用）。
class _MemoryAuditStore implements RemoteAuthorizationAuditStore {
  final List<RemoteAuthorizationAuditEvent> events = [];

  /// 置 true 时 append 抛错（验证审计失败不影响授权判定）。
  bool failOnAppend = false;

  @override
  Future<void> append(RemoteAuthorizationAuditEvent event) async {
    if (failOnAppend) {
      throw StateError('forced audit append failure');
    }
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

void main() {
  group('DriftRemoteAuthorizationAuditStore（落库）', () {
    late AppDatabase db;
    late DriftRemoteAuthorizationAuditStore store;

    setUp(() {
      // ignore: invalid_use_of_visible_for_testing_member
      db = AppDatabase.forTest(NativeDatabase.memory());
      store = DriftRemoteAuthorizationAuditStore(db);
    });

    tearDown(() async {
      await db.close();
    });

    RemoteAuthorizationAuditEvent ev({
      String event = 'deny_tool',
      String channel = 'wechat',
      String chat = 'chat1',
      String? user,
      String? detail,
      String? job,
      DateTime? at,
    }) => RemoteAuthorizationAuditEvent(
      event: event,
      channelType: channel,
      chatId: chat,
      userId: user,
      detail: detail,
      jobId: job,
      at: at ?? DateTime.parse('2026-01-01T00:00:00.000Z'),
    );

    test('append 追加式：逐条落库，事件可查询回读', () async {
      await store.append(ev(event: 'grant', detail: 'scope=write'));
      await store.append(
        ev(event: 'deny_message', detail: 'no valid authorization record'),
      );
      final all = await store.query();
      expect(all.length, 2);
      expect(all[0].event, 'deny_message'); // at 倒序，后写的在前
      expect(all[1].event, 'grant');
      expect(all[1].detail, 'scope=write');
    });

    test('query 按渠道 / 会话 / 用户 / Job / 时间过滤', () async {
      final base = DateTime.parse('2026-01-01T00:00:00.000Z');
      await store.append(
        ev(event: 'grant', channel: 'wechat', chat: 'c1', user: 'u1', job: 'j1', at: base),
      );
      await store.append(
        ev(event: 'deny_tool', channel: 'qq', chat: 'c2', user: 'u2', job: 'j2', at: base.add(const Duration(hours: 1))),
      );
      await store.append(
        ev(event: 'allow_tool', channel: 'wechat', chat: 'c3', user: null, job: null, at: base.add(const Duration(hours: 2))),
      );

      expect((await store.query(channelType: 'wechat')).length, 2);
      expect((await store.query(chatId: 'c1')).length, 1);
      expect((await store.query(userId: 'u1')).length, 1);
      expect((await store.query(jobId: 'j1')).length, 1);
      expect((await store.query(userId: 'u9')).length, 0);
      expect(
        (await store.query(since: base.add(const Duration(hours: 1)))).length,
        2,
        reason: 'since 过滤（含 1 小时后）',
      );
      expect(
        (await store.query(until: base.add(const Duration(hours: 1)))).length,
        2,
        reason: 'until 过滤（含 1 小时前）',
      );
      expect((await store.query(limit: 1)).length, 1, reason: 'limit 生效');
    });

    test('cleanupBefore / cleanupExpired 按保留期限清理', () async {
      final base = DateTime.parse('2026-01-01T00:00:00.000Z');
      final now = DateTime.parse('2026-04-01T00:00:00.000Z');
      // 90 天前 = 2026-01-01 00:00:00，正好在边界；更早的应被清。
      await store.append(ev(at: base));
      await store.append(ev(at: base.subtract(const Duration(days: 1))));
      await store.append(ev(at: now));

      final deleted = await store.cleanupBefore(
        now.subtract(const Duration(days: remoteAuthorizationAuditRetentionDays)),
      );
      expect(deleted, 1, reason: '仅早于保留期限的 1 条被清');
      expect((await store.query()).length, 2);

      // cleanupExpired 基于传入 now。
      final deleted2 = await store.cleanupExpired(now: now);
      expect(deleted2, 0, reason: '剩余均在保留期内');
    });
  });

  group('RemoteAuthorizationService 审计接线（内存审计存储）', () {
    test('grant / revoke / deny / allow 事件均写入审计存储', () async {
      final authStore = _MemoryAuthStore();
      final auditStore = _MemoryAuditStore();
      final service = RemoteAuthorizationService(
        authStore,
        auditStore: auditStore,
      );

      await service.authorizeRemoteUser(
        channelType: 'wechat',
        chatId: 'chat1',
        userId: 'u1',
        scope: RemotePermissionScope.write,
      );
      await service.isToolAuthorized(
        'list_novels',
        channelType: 'wechat',
        chatId: 'chat1',
        userId: 'u1',
      );
      await service.isMessageAuthorized(
        channelType: 'wechat',
        chatId: 'chat1',
        userId: 'u1',
      );
      await service.revokeRemoteUser(
        channelType: 'wechat',
        chatId: 'chat1',
        userId: 'u1',
      );

      final events = auditStore.events.map((e) => e.event).toList();
      expect(events, contains('grant'));
      expect(events, contains('allow_tool'));
      expect(events, contains('allow_message'));
      expect(events, contains('revoke'));
    });

    test('敏感详情脱敏：token / api_key / bearer 一律 <redacted>', () async {
      // 1. 公开脱敏函数直接验证（服务层 `_audit` 调用同一函数）。
      const raw =
          'tool=x api_key=sk-12345678 token=abc.def.ghi '
          'Authorization: Bearer xyz secret=p@ss';
      final sanitized = sanitizeRemoteAuthorizationDetail(raw);
      expect(sanitized, isNot(contains('sk-12345678')));
      expect(sanitized, isNot(contains('abc.def.ghi')));
      expect(sanitized, isNot(contains('xyz')));
      expect(sanitized, isNot(contains('p@ss')));
      expect(sanitized, contains('<redacted>'));
      expect(sanitized, contains('api_key=<redacted>'));
      expect(sanitized, contains('token=<redacted>'));
      expect(sanitized, contains('Authorization: Bearer <redacted>'));
      expect(sanitized, contains('secret=<redacted>'));
      // 普通事件描述不受影响。
      expect(
        sanitizeRemoteAuthorizationDetail('scope=write tool=list_novels'),
        'scope=write tool=list_novels',
      );

      // 2. 写入边界（Drift store）纵深防御：绕过服务层直接 append 也不落敏感值。
      // ignore: invalid_use_of_visible_for_testing_member
      final auditDb = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(() => auditDb.close());
      final store = DriftRemoteAuthorizationAuditStore(auditDb);
      await store.append(
        RemoteAuthorizationAuditEvent(
          event: 'deny_tool',
          channelType: 'wechat',
          chatId: 'chat1',
          userId: 'u1',
          detail: 'tool=mcp__foo api_key=sk-999 token=aaa.bbb.ccc',
          at: DateTime.now(),
        ),
      );
      final rows = await auditDb.select(auditDb.remoteAuthorizationAudit).get();
      expect(rows, isNotEmpty);
      expect(rows.last.detail, isNot(contains('sk-999')));
      expect(rows.last.detail, isNot(contains('aaa.bbb.ccc')));
      expect(rows.last.detail, contains('<redacted>'));
    });

    test('审计写入失败不影响授权判定（fail-closed 不因审计异常放行）', () async {
      final authStore = _MemoryAuthStore();
      final auditStore = _MemoryAuditStore()..failOnAppend = true;
      final service = RemoteAuthorizationService(
        authStore,
        auditStore: auditStore,
      );

      // 无授权记录 → 即使审计存储抛错，仍 deny-by-default 拒绝。
      final denied = await service.isToolAuthorized(
        'list_novels',
        channelType: 'wechat',
        chatId: 'chat1',
        userId: 'u1',
      );
      expect(denied, isFalse, reason: '审计失败不得把拒绝变成放行');

      // 有授权记录（write）→ 仍放行；审计失败不回滚授权判定。
      await service.authorizeRemoteUser(
        channelType: 'wechat',
        chatId: 'chat1',
        userId: 'u1',
        scope: RemotePermissionScope.write,
      );
      final allowed = await service.isToolAuthorized(
        'list_novels',
        channelType: 'wechat',
        chatId: 'chat1',
        userId: 'u1',
      );
      expect(allowed, isTrue, reason: '审计失败不得撤销已做出的授权判定');
    });
  });

  group('服务层落库集成（真实 Drift 审计存储）', () {
    test('授权服务事件经 Drift 审计存储落库', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(() => db.close());
      final auditStore = DriftRemoteAuthorizationAuditStore(db);
      final service = RemoteAuthorizationService(
        _MemoryAuthStore(),
        auditStore: auditStore,
      );

      await service.authorizeRemoteUser(
        channelType: 'wechat',
        chatId: 'chat1',
        userId: 'u1',
        scope: RemotePermissionScope.write,
      );
      // 内存环形缓冲同步；持久化 append 是 fire-and-forget —— 轮询等待落库。
      var rows = <RemoteAuthorizationAuditData>[];
      for (var i = 0; i < 40; i++) {
        rows = await db.select(db.remoteAuthorizationAudit).get();
        if (rows.any((r) => r.event == 'grant')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(rows, isNotEmpty);
      expect(rows.any((r) => r.event == 'grant'), isTrue);
      expect(rows.first.channelType, 'wechat');
      expect(rows.first.detail, isNot(contains('<redacted>')));
    });
  });
}
