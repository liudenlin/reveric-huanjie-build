// 职责: 验证 P0-D D1 授权失效策略（TTL 惰性过期）——
//       RemoteAuthorizationRecord.isActiveAt 与 RemoteAuthorizationService
//       判定路径的过期语义（不新增列、不升 schema、不迁移既有数据）。
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
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
  const userA = 'wxid_alice';
  const ttl30 = Duration(days: 30);

  RemoteAuthorizationRecord record(DateTime grantedAt) =>
      RemoteAuthorizationRecord(
        channelType: channel,
        chatId: chatA,
        userId: userA,
        scope: RemotePermissionScope.read,
        grantedAt: grantedAt,
      );

  group('RemoteAuthorizationRecord.isActiveAt — TTL 惰性过期', () {
    test('未撤销且未超 TTL → 有效', () {
      final r = record(DateTime.now().subtract(const Duration(days: 10)));
      expect(r.isActiveAt(DateTime.now(), maxAge: ttl30), isTrue);
    });

    test('未撤销但超 TTL → 过期', () {
      final r = record(DateTime.now().subtract(const Duration(days: 40)));
      expect(r.isActiveAt(DateTime.now(), maxAge: ttl30), isFalse);
    });

    test('已撤销 → 无效（无论是否超 TTL）', () {
      final base = record(DateTime.now().subtract(const Duration(days: 10)));
      final revoked = RemoteAuthorizationRecord(
        channelType: base.channelType,
        chatId: base.chatId,
        userId: base.userId,
        scope: base.scope,
        grantedAt: base.grantedAt,
        revokedAt: DateTime.now(),
      );
      expect(revoked.isActiveAt(DateTime.now(), maxAge: ttl30), isFalse);
      expect(revoked.isActiveAt(DateTime.now(), maxAge: null), isFalse);
    });

    test('maxAge null → 不过期（兼容旧行为/单元测试）', () {
      final r = record(DateTime.now().subtract(const Duration(days: 400)));
      expect(r.isActiveAt(DateTime.now(), maxAge: null), isTrue);
    });

    test('边界：grantedAt + TTL == now → 有效（not after 语义）', () {
      final granted = DateTime.now().subtract(ttl30);
      final r = record(granted);
      expect(r.isActiveAt(DateTime.now(), maxAge: ttl30), isTrue);
    });
  });

  group('RemoteAuthorizationService — 判定路径 TTL 语义', () {
    test('过期授权（40 天前 + 默认 30 天 TTL）→ 消息拒绝', () async {
      final store = _MemoryStore();
      await store.upsert(record(DateTime.now().subtract(const Duration(days: 40))));
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

    test('有效授权（10 天前 + 默认 30 天 TTL）→ 消息放行', () async {
      final store = _MemoryStore();
      await store.upsert(record(DateTime.now().subtract(const Duration(days: 10))));
      final service = RemoteAuthorizationService(store);
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });

    test('TTL 显式缩短（10 天前 + 5 天 TTL）→ 过期拒绝', () async {
      final store = _MemoryStore();
      await store.upsert(record(DateTime.now().subtract(const Duration(days: 10))));
      final service = RemoteAuthorizationService(
        store,
        authorizationTtl: const Duration(days: 5),
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

    test('TTL null（不过期）→ 40 天前仍放行', () async {
      final store = _MemoryStore();
      await store.upsert(record(DateTime.now().subtract(const Duration(days: 40))));
      final service = RemoteAuthorizationService(store, authorizationTtl: null);
      expect(
        await service.isMessageAuthorized(
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });

    test('过期授权 → 工具判定拒绝（isToolAuthorized）', () async {
      final store = _MemoryStore();
      await store.upsert(record(DateTime.now().subtract(const Duration(days: 40))));
      final service = RemoteAuthorizationService(store);
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

    test('有效授权 → 工具判定放行（list_novels 只读动作）', () async {
      final store = _MemoryStore();
      await store.upsert(record(DateTime.now().subtract(const Duration(days: 10))));
      final service = RemoteAuthorizationService(store);
      expect(
        await service.isToolAuthorized(
          'list_novels',
          channelType: channel,
          chatId: chatA,
          userId: userA,
        ),
        isTrue,
      );
    });
  });
}
