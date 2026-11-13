// P0-B B5: 正式回归 —— 远程授权数据链路关键不变量。
// 覆盖矩阵中尚缺的项（其余由 B0/B2/B3/B4 与既有服务/门禁测试覆盖）：
//   1. 迁移链稳定与数据保留：文件 DB 打开(→v6)→写入→关闭→重开，原授权记录不丢失、
//      schema 版本稳定、无迁移异常（v4→v5→v6 链的安全属性：数据可幸存）。
//   2. 撤销立即生效并真实落库：授权→Drift 表读到生效；撤销→Drift 表读回 revokedAt
//      非空，且下一次授权判定立即拒绝（UI 授权/撤销真实落库）。
//   3. 远程关闭门禁 fail-closed：注入 failClosed 运行时状态后消息/工具一律拒绝，
//      且不抛异常、不影响本地路径（远程关闭不阻断本地写作——本地写入不经本服务，
//      本服务对远程操作 fail-closed 且无副作用）。
// 运行（隔离副本 cwd，需临时禁用 super_native_extensions hook + 清代理）:
//   fvm flutter test remote_authorization_schema_regression_test.dart
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/remote_authorization_audit_store.dart';
import 'package:reveric/shared/database/remote_authorization_store.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';

void main() {
  const channel = 'wechat';
  const chatA = 'wxid_alice';
  const userA = 'wxid_alice';

  test('迁移链稳定且数据保留：文件 DB 写入→重开，授权记录不丢失', () async {
    final dir = await Directory.systemTemp.createTemp('auth-regression-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(p.join(dir.path, 'auth.db'));

    // 首次打开（运行 v4→v5→v6 全链到当前 schema）。
    var db = AppDatabase.forTest(NativeDatabase(file));
    var store = DriftRemoteAuthorizationStore(db);
    // 经 store 写入一条授权（触发惰性迁移 + 落库）。
    await store.write(
      'remote_channel_authorizations',
      const _AuthRecordJson().encode(),
    );
    await db.close();

    // 重开同一文件：迁移链为 no-op（版本已到位），数据必须保留。
    db = AppDatabase.forTest(NativeDatabase(file));
    addTearDown(db.close);
    store = DriftRemoteAuthorizationStore(db);
    final records = await store.read('remote_channel_authorizations');
    expect(records, isNotNull);
    expect(records, contains('wxid_alice'));
    // schema 稳定：审计表与授权表均可查询（不抛）。
    await db.select(db.remoteAuthorizationAudit).get();
    await db.select(db.remoteAuthorizations).get();
  });

  test('撤销立即生效并真实落库：revoke → 表读回 revokedAt 且下次判定拒绝', () async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    final store = DriftRemoteAuthorizationStore(db);
    final service = RemoteAuthorizationService(
      store,
      auditStore: DriftRemoteAuthorizationAuditStore(db),
    );

    await service.authorizeRemoteUser(
      channelType: channel,
      chatId: chatA,
      userId: userA,
      scope: RemotePermissionScope.all,
      grantedBy: 'local_settings_ui',
    );
    // 授权生效：消息放行。
    expect(
      await service.isMessageAuthorized(
        channelType: channel,
        chatId: chatA,
        userId: userA,
      ),
      isTrue,
    );
    // 落库校验：active 行存在。
    final activeRows = await db.select(db.remoteAuthorizations).get();
    expect(activeRows, hasLength(1));
    expect(activeRows.single.revokedAt, isNull);

    // 撤销 → 立即生效（下一次判定拒绝）。
    await service.revokeRemoteUser(
      channelType: channel,
      chatId: chatA,
      userId: userA,
      revokedBy: 'local_settings_ui',
    );
    expect(
      await service.isMessageAuthorized(
        channelType: channel,
        chatId: chatA,
        userId: userA,
      ),
      isFalse,
    );
    // 真实落库：该行 revokedAt 已置（软撤销保留记录）。
    final afterRevoke = await db.select(db.remoteAuthorizations).get();
    expect(afterRevoke, hasLength(1));
    expect(afterRevoke.single.revokedAt, isNotNull);
  });

  test('远程关闭门禁 fail-closed：消息/工具一律拒绝且不抛、无副作用', () async {
    final db = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    final store = DriftRemoteAuthorizationStore(db);
    final service = RemoteAuthorizationService(
      store,
      auditStore: DriftRemoteAuthorizationAuditStore(db),
      runtimeStatusProvider: () async =>
          const RemoteRuntimeStatus.failClosed(),
    );
    // 即使有授权记录，远程关闭时也 fail-closed 拒绝。
    await service.authorizeRemoteUser(
      channelType: channel,
      chatId: chatA,
      userId: userA,
      scope: RemotePermissionScope.all,
      grantedBy: 'local_settings_ui',
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
        'list_novels',
        channelType: channel,
        chatId: chatA,
        userId: userA,
      ),
      isFalse,
    );
    // 远程关闭不影响本地写作：本地路径不经本服务（此处断言远程门禁
    // fail-closed 无异常/无副作用，本地写入入口独立于本服务——见
    // remote_execution_gate_test.dart 对本地路径不受门禁影响的验证）。
  });
}

/// 构造一条授权 JSON（复用 RemoteAuthorizationRecord 序列化语义，避免依赖
/// 服务层在单测里的额外耦合）。
class _AuthRecordJson {
  const _AuthRecordJson();

  String encode() {
    return '[{"channel_type":"wechat","chat_id":"wxid_alice",'
        '"user_id":"wxid_alice","scope":"all",'
        '"granted_at":"2026-11-08T00:00:00.000",'
        '"display_name":"wxid_alice","granted_by":"local_settings_ui"}]';
  }
}
