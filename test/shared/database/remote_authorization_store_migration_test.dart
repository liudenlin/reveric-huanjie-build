// P0-B B2（纳入仓库 test/shared/database）: DriftRemoteAuthorizationStore 旧 JSON 授权迁移与授权表读写验证。
// 用内存 AppDatabase（NativeDatabase.memory，完整 v5 schema）跑真实 store，
// 验证：惰性迁移、幂等、备份保留、deny-by-default、全量替换、去重、未知
// scope 丢弃、失败回滚不设标记不删 JSON、read/write 往返一致。
// 运行（隔离副本 cwd，需临时禁用 super_native_extensions hook）:
//   fvm flutter test b2_migration_test.dart
import 'dart:convert';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/remote_authorization_store.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';

void main() {
  late AppDatabase db;
  late DriftRemoteAuthorizationStore store;

  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    db = AppDatabase.forTest(NativeDatabase.memory());
    store = DriftRemoteAuthorizationStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  String legacyJson(List<Map<String, dynamic>> recs) => jsonEncode(recs);

  Future<void> seedLegacy(String json) => db.appSettingsDao.set(
    key: remoteChannelAuthorizationsKey,
    value: json,
  );

  Future<List<RemoteAuthorizationRecord>> tableRecords() async {
    final rows = await db.select(db.remoteAuthorizations).get();
    return [
      for (final r in rows)
        RemoteAuthorizationRecord(
          channelType: r.channelType,
          chatId: r.chatId,
          userId: r.userId,
          scope: RemotePermissionScope.values.firstWhere(
            (e) => e.name == r.scope,
            orElse: () => RemotePermissionScope.read,
          ),
          grantedAt: r.grantedAt,
          revokedAt: r.revokedAt,
          displayName: r.displayName,
          grantedBy: r.grantedBy,
        ),
    ];
  }

  test('惰性迁移：首次 read 导入旧 JSON、置标记、保留备份', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
        'granted_by': 'local_user',
      },
      {
        'channel_type': 'qq',
        'chat_id': 'chat2',
        'user_id': 'u9',
        'scope': 'all',
        'granted_at': '2026-01-02T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);

    final raw = await store.read(remoteChannelAuthorizationsKey);
    expect(raw, isNotNull, reason: 'read 应返回迁移后的 JSON 数组');

    final records = await tableRecords();
    expect(records.length, 2);
    expect(records[0].channelType, 'wechat');
    expect(records[0].chatId, 'chat1');
    expect(records[0].userId, isNull);
    expect(records[0].scope, RemotePermissionScope.write);
    expect(records[1].channelType, 'qq');
    expect(records[1].userId, 'u9');
    expect(records[1].scope, RemotePermissionScope.all);

    // 标记已置；旧 JSON 保留作备份（不删除）。
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1');
    expect(
      await db.appSettingsDao.get(remoteChannelAuthorizationsKey),
      legacy,
      reason: '迁移后旧 JSON 应保留作备份',
    );
  });

  test('幂等：同一 store 二次 read 与全新 store 均不重复导入', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);

    await store.read(remoteChannelAuthorizationsKey);
    await store.read(remoteChannelAuthorizationsKey); // 同 store 二次
    expect((await tableRecords()).length, 1);

    // 全新 store 实例（内存 _migrated 缓存为空，须走标记位短路）。
    final store2 = DriftRemoteAuthorizationStore(db);
    await store2.read(remoteChannelAuthorizationsKey);
    expect((await tableRecords()).length, 1, reason: '新实例不重复导入');
  });

  test('空旧 JSON：置标记、表空（deny-by-default）', () async {
    await seedLegacy('');
    final raw = await store.read(remoteChannelAuthorizationsKey);
    expect(raw, isNotNull);
    expect(await tableRecords(), isEmpty);
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1');
  });

  test('无旧 JSON：置标记、表空（deny-by-default）', () async {
    final raw = await store.read(remoteChannelAuthorizationsKey);
    expect(raw, isNotNull);
    expect(await tableRecords(), isEmpty);
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1');
  });

  test('去重：旧 JSON 同身份重复取最后一条，不触发唯一索引冲突', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'read',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-02T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);

    await store.read(remoteChannelAuthorizationsKey);
    final records = await tableRecords();
    expect(records.length, 1);
    expect(records.single.scope, RemotePermissionScope.write,
        reason: '重复身份应取最后一条（write 覆盖 read）');
  });

  test('未知 scope：视为整体损坏 → fail-closed 上抛，不降级放行、不清空表、保留 JSON', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'bogus',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);

    // P0-B.3 任务1：无效记录（未知 scope）视为整体损坏 → 显式上抛
    // （fail-closed），不得静默丢弃后当空授权提交、不得降级放行。
    await expectLater(
      store.read(remoteChannelAuthorizationsKey),
      throwsA(anything),
      reason: '无效记录必须视为整体损坏并 fail-closed 上抛',
    );
    expect(await tableRecords(), isEmpty, reason: '无效记录不得部分导入（无降级放行）');
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), isNot('1'),
        reason: '损坏不置迁移标记');
    expect(await db.appSettingsDao.get(remoteChannelAuthorizationsKey), legacy,
        reason: '损坏必须保留原始 JSON');
  });

  test('write：全量替换语义（先迁移，后写入新集合覆盖）', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);
    await store.read(remoteChannelAuthorizationsKey);
    expect((await tableRecords()).length, 1);

    // 写入全新集合（不同渠道），应清空旧表后插入。
    await store.write(
      remoteChannelAuthorizationsKey,
      legacyJson([
        {
          'channel_type': 'dingtalk',
          'chat_id': 'c9',
          'scope': 'read',
          'granted_at': '2026-02-01T00:00:00.000Z',
        },
      ]),
    );
    final records = await tableRecords();
    expect(records.length, 1);
    expect(records.single.channelType, 'dingtalk');
    expect(records.single.scope, RemotePermissionScope.read);
  });

  test('失败恢复：迁移冲突回滚、不设标记、保留旧 JSON、不清空既有表', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);

    // 预先插入一条既有授权（模拟迁移前表已有数据）。
    await db.into(db.remoteAuthorizations).insert(
      RemoteAuthorizationsCompanion.insert(
        channelType: 'wechat',
        chatId: 'chat1',
        userId: const Value(null),
        scope: 'read',
        grantedAt: DateTime.parse('2026-01-01T00:00:00.000Z'),
      ),
    );

    // 用 BEFORE INSERT 触发器强制迁移导入失败（RAISE ROLLBACK 终止事务），
    // 确定性注入故障，验证「事务回滚 + 不设标记 + 保留 JSON + 不清空既有行」。
    await db.customStatement(
      "CREATE TRIGGER force_migration_fail BEFORE INSERT ON remote_authorizations "
      "BEGIN SELECT RAISE(ROLLBACK, 'forced migration failure'); END;",
    );

    // P0-B.2：迁移失败后 read 显式上抛（fail-closed），不得静默吞错返回空；
    // 先捕获异常，再验证「回滚 + 不设标记 + 保留 JSON + 不清空既有表」副作用。
    await expectLater(
      store.read(remoteChannelAuthorizationsKey),
      throwsA(anything),
    );

    // 迁移失败：标记未设、旧 JSON 保留、表未被清空（既有行仍在）。
    expect(
      await db.appSettingsDao.get(remoteAuthorizationsMigratedKey),
      isNot('1'),
      reason: '失败不得置迁移标记',
    );
    expect(
      await db.appSettingsDao.get(remoteChannelAuthorizationsKey),
      legacy,
      reason: '失败必须保留原始 JSON',
    );
    final rows = await tableRecords();
    expect(rows.length, 1);
    expect(rows.single.scope, RemotePermissionScope.read,
        reason: '失败回滚后既有数据不丢失（deny-by-default 语义）');
  });

  // ================= P0-B.2：迁移失败 Fail-closed =================

  test('P0-B.2-1 迁移失败显式上抛（read 不再静默返回空授权）', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);
    await db.customStatement(
      "CREATE TRIGGER force_p0b2_fail BEFORE INSERT ON remote_authorizations "
      "BEGIN SELECT RAISE(ROLLBACK, 'forced p0b2 migration failure'); END;",
    );

    // P0-B.2：迁移失败必须显式上抛，不得吞错后静默返回空授权（掩盖失败）。
    await expectLater(
      store.read(remoteChannelAuthorizationsKey),
      throwsA(anything),
      reason: '迁移失败必须上抛（fail-closed），read 不得静默返回空授权',
    );
    // 标记未置、旧 JSON 保留（迁移失败未提交）。
    expect(
      await db.appSettingsDao.get(remoteAuthorizationsMigratedKey),
      isNot('1'),
    );
    expect(await db.appSettingsDao.get(remoteChannelAuthorizationsKey), legacy);
  });

  test('P0-B.2-2 迁移失败后 write 也 fail-closed 抛错（不静默覆写，无一致性风险）',
      () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);
    await db.customStatement(
      "CREATE TRIGGER force_p0b2_write_fail BEFORE INSERT ON remote_authorizations "
      "BEGIN SELECT RAISE(ROLLBACK, 'forced p0b2 write failure'); END;",
    );

    // 迁移失败后，write 必须在迁移阶段中止（_ensureMigrated 上抛），
    // 不得把新授权写入表（避免下次成功迁移清表重导旧 JSON 覆写新授权）。
    await expectLater(
      store.write(
        remoteChannelAuthorizationsKey,
        legacyJson([
          {
            'channel_type': 'dingtalk',
            'chat_id': 'c9',
            'scope': 'read',
            'granted_at': '2026-02-01T00:00:00.000Z',
          },
        ]),
      ),
      throwsA(anything),
      reason: '迁移失败后 write 必须 fail-closed 中止（不静默覆写）',
    );
    // 表未被写入新授权（仍为空，迁移从未成功）。
    expect(await tableRecords(), isEmpty);
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), isNot('1'));
  });

  test('P0-B.2-3 迁移失败可恢复：故障移除后重试成功，不残留失败态', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);
    await db.customStatement(
      "CREATE TRIGGER force_p0b2_recover BEFORE INSERT ON remote_authorizations "
      "BEGIN SELECT RAISE(ROLLBACK, 'forced p0b2 recover failure'); END;",
    );
    await expectLater(
      store.read(remoteChannelAuthorizationsKey),
      throwsA(anything),
    );

    // 移除故障：下一次操作自动重试迁移并成功。
    await db.customStatement('DROP TRIGGER force_p0b2_recover');
    final raw = await store.read(remoteChannelAuthorizationsKey);
    expect(raw, isNotNull);
    expect((await tableRecords()).length, 1);
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1');
  });

  test('read/write 往返：store.read 输出可被授权服务解析且字段一致', () async {
    await store.write(
      remoteChannelAuthorizationsKey,
      legacyJson([
        {
          'channel_type': 'wechat',
          'chat_id': 'chat1',
          'user_id': 'u5',
          'scope': 'all',
          'granted_at': '2026-03-01T00:00:00.000Z',
          'display_name': '张三',
          'granted_by': 'local_user',
        },
      ]),
    );
    final raw = await store.read(remoteChannelAuthorizationsKey);
    expect(raw, isNotNull);

    final decoded = jsonDecode(raw!) as List;
    expect(decoded.length, 1);
    final rec = RemoteAuthorizationRecord.fromJson(decoded.single);
    expect(rec, isNotNull);
    expect(rec!.channelType, 'wechat');
    expect(rec.chatId, 'chat1');
    expect(rec.userId, 'u5');
    expect(rec.scope, RemotePermissionScope.all);
    expect(rec.displayName, '张三');
    expect(rec.grantedBy, 'local_user');
  });

  // ================= P0-B.1 M1：旧授权迁移故障注入（7 类） =================

  test('P0-B.3-1a 迁移标记读取失败 → fail-closed 显式上抛、不置标记、保留 JSON、故障恢复后可重试', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);

    // 将 app_settings 表改名，使 appSettingsDao.get 抛出「no such table」，
    // 精确注入「迁移标记读取失败」语义（区别于不存在/损坏，三者不应混同）。
    await db.customStatement('ALTER TABLE app_settings RENAME TO app_settings_bak');

    // P0-B.3 任务1：迁移标记读取异常 = 迁移状态未知，必须显式上抛（fail-closed），
    // 不得与「标记不存在」同结果、不得静默返回空授权（否则可能重导旧 JSON 覆写）。
    await expectLater(
      store.read(remoteChannelAuthorizationsKey),
      throwsA(anything),
      reason: '迁移标记读取失败必须显式上抛（fail-closed）',
    );
    expect(await tableRecords(), isEmpty, reason: '标记读取失败时授权表保持空（未重导覆写）');
    // app_settings 已改名，原始 JSON 保留在 app_settings_bak（直查验证）。
    final preserved = await db.customSelect(
      'SELECT value FROM app_settings_bak WHERE key = ?',
      variables: [Variable.withString(remoteChannelAuthorizationsKey)],
    ).getSingleOrNull();
    expect(preserved?.data['value'], legacy,
        reason: '标记读取失败必须保留原始 JSON');

    // 恢复 settings 表后：标记仍未置，下一次读取应能成功迁移。
    await db.customStatement('ALTER TABLE app_settings_bak RENAME TO app_settings');
    final raw2 = await store.read(remoteChannelAuthorizationsKey);
    expect(raw2, isNotNull);
    expect((await tableRecords()).length, 1, reason: '故障恢复后重试应成功导入');
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1');
  });

  test('P0-B.3-1b 旧 JSON 损坏 → fail-closed 显式上抛、不置标记、保留原始 JSON、修复后可迁移', () async {
    // 2a 非法 JSON 字符串。
    await seedLegacy('{not valid json[');
    // P0-B.3 任务1：损坏 JSON 不得正常结束迁移检查并继续提供旧授权表内容
    // （否则 read() 静默返回空表，掩盖迁移失败）——必须显式上抛进入失败路径。
    await expectLater(
      store.read(remoteChannelAuthorizationsKey),
      throwsA(anything),
      reason: '损坏 JSON 必须显式上抛（fail-closed），不得当空授权提交',
    );
    expect(await tableRecords(), isEmpty, reason: '损坏 JSON 不得当作空授权提交');
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), isNot('1'),
        reason: '损坏 JSON 不置迁移标记');
    expect(await db.appSettingsDao.get(remoteChannelAuthorizationsKey), '{not valid json[',
        reason: '损坏 JSON 必须保留，不得清除');

    // 2b JSON 数组含无效记录（scope 非法）→ 同样视为损坏。
    await db.appSettingsDao.set(
      key: remoteChannelAuthorizationsKey,
      value: legacyJson([
        {
          'channel_type': 'wechat',
          'chat_id': 'chat1',
          'scope': 'bogus',
          'granted_at': '2026-01-01T00:00:00.000Z',
        },
      ]),
    );
    await expectLater(
      store.read(remoteChannelAuthorizationsKey),
      throwsA(anything),
    );
    expect(await tableRecords(), isEmpty, reason: '无效记录视为整体损坏');
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), isNot('1'));

    // 2c 修复 JSON 后，同一 store（_migrated 仍 false）重试成功迁移。
    await db.appSettingsDao.set(
      key: remoteChannelAuthorizationsKey,
      value: legacyJson([
        {
          'channel_type': 'qq',
          'chat_id': 'c2',
          'scope': 'read',
          'granted_at': '2026-02-01T00:00:00.000Z',
        },
      ]),
    );
    await store.read(remoteChannelAuthorizationsKey);
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1',
        reason: '修复后重试应成功迁移');
    expect((await tableRecords()).length, 1);
  });

  test('M1-3 事务中断：导入中途失败 → 整体回滚，无部分导入、不置标记、保留 JSON', () async {
    // 两条记录，第二条导入时被触发器中断：必须整事务回滚（不能留下第一条）。
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
      {
        'channel_type': 'qq',
        'chat_id': 'chat2',
        'scope': 'read',
        'granted_at': '2026-01-02T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);

    // 表当前为空；第二条 INSERT 时 RAISE(ROLLBACK) 中断整个迁移事务。
    await db.customStatement(
      "CREATE TRIGGER force_txn_interrupt BEFORE INSERT ON remote_authorizations "
      "WHEN NEW.chat_id = 'chat2' "
      "BEGIN SELECT RAISE(ROLLBACK, 'forced txn interruption'); END;",
    );

    await expectLater(
      store.read(remoteChannelAuthorizationsKey),
      throwsA(anything),
      reason: '迁移事务中断必须显式上抛（P0-B.2 fail-closed），不得静默返回',
    );

    expect(await tableRecords(), isEmpty,
        reason: '事务中断必须整体回滚，不得留下部分导入行');
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), isNot('1'),
        reason: '事务中断不置迁移标记');
    expect(await db.appSettingsDao.get(remoteChannelAuthorizationsKey), legacy,
        reason: '事务中断必须保留原始 JSON');
  });

  test('M1-4 标记写入失败：迁移后标记写失败 → 不置 _migrated、下次重试成功', () async {
    // 空 JSON → _LegacyJsonAbsent → _markMigrated 路径（单独写标记）。
    await seedLegacy('');
    await db.customStatement(
      "CREATE TRIGGER force_marker_fail BEFORE INSERT ON app_settings "
      "WHEN NEW.\"key\" = 'remote_authorizations_migrated_v5' "
      "BEGIN SELECT RAISE(ABORT, 'forced marker write failure'); END;",
    );

    await store.read(remoteChannelAuthorizationsKey);
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), isNot('1'),
        reason: '标记写入失败不得置标记（下次重试）');
    expect(await tableRecords(), isEmpty);

    // 移除故障，重试成功。
    await db.customStatement('DROP TRIGGER force_marker_fail');
    await store.read(remoteChannelAuthorizationsKey);
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1',
        reason: '标记写失败后重试应成功');
  });

  test('M1-5 重复启动：迁移成功后新实例走标记短路，不重复导入', () async {
    await seedLegacy(legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]));
    await store.read(remoteChannelAuthorizationsKey);
    expect((await tableRecords()).length, 1);

    final store2 = DriftRemoteAuthorizationStore(db);
    await store2.read(remoteChannelAuthorizationsKey);
    expect((await tableRecords()).length, 1, reason: '新实例不得重复导入');
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1');
  });

  test('M1-6 并发迁移：多路并发触发仅一个迁移事务生效，无重复行、无唯一冲突', () async {
    await seedLegacy(legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
      {
        'channel_type': 'qq',
        'chat_id': 'chat2',
        'scope': 'read',
        'granted_at': '2026-01-02T00:00:00.000Z',
      },
    ]));

    final results = await Future.wait([
      store.read(remoteChannelAuthorizationsKey),
      store.read(remoteChannelAuthorizationsKey),
      store.read(remoteChannelAuthorizationsKey),
      store.read(remoteChannelAuthorizationsKey),
      store.read(remoteChannelAuthorizationsKey),
    ]);
    for (final r in results) {
      expect(r, isNotNull);
    }
    expect((await tableRecords()).length, 2, reason: '并发迁移只导入一次，无重复行');
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1');

    // 新实例（标记短路）也不重复。
    final store2 = DriftRemoteAuthorizationStore(db);
    await store2.read(remoteChannelAuthorizationsKey);
    expect((await tableRecords()).length, 2);
  });

  test('M1-7 撤销后重启：迁移标记已置，新实例不从旧 JSON 重导入过期授权', () async {
    final legacy = legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]);
    await seedLegacy(legacy);
    await store.read(remoteChannelAuthorizationsKey); // 迁移完成，标记置位。

    final revoked = await store.revoke(channelType: 'wechat', chatId: 'chat1');
    expect(revoked, isTrue);

    // 重启：新实例读取，已撤销记录不得被旧 JSON 复活为活动。
    final store2 = DriftRemoteAuthorizationStore(db);
    final raw = await store2.read(remoteChannelAuthorizationsKey);
    final decoded = jsonDecode(raw!) as List;
    expect(decoded.length, 1);
    final rec = RemoteAuthorizationRecord.fromJson(decoded.single);
    expect(rec!.isActive, isFalse, reason: '重启后已撤销记录保持撤销态，不被旧 JSON 覆盖');
  });

  // ================= P0-B.1 M2：行级授权并发交错（2 个） =================

  test('M2-1 并发撤销 vs 并发授权不同身份：两者效果都保留，撤销不被覆盖', () async {
    await store.upsert(_rec('wechat', 'chat1', null, 'write'));

    // 并发：撤销 A 与授权 B 同时进行。旧实现「readAll→改列表→全量写回」
    // 会在某些交错下用旧快照复活 A；行级 upsert/revoke 只触碰各自身份行。
    await Future.wait([
      store.revoke(channelType: 'wechat', chatId: 'chat1'),
      store.upsert(_rec('qq', 'chat2', null, 'read')),
    ]);

    final rows = await store.listAll();
    final a = rows.singleWhere((r) => r.chatId == 'chat1');
    expect(a.isActive, isFalse, reason: '并发授权其他身份不得复活已撤销记录');
    final b = rows.singleWhere((r) => r.chatId == 'chat2');
    expect(b.isActive, isTrue, reason: '并发授权新身份必须生效');
  });

  test('M2-2 并发撤销 vs 并发同身份重授权：无部分唯一索引冲突、后写生效', () async {
    await store.upsert(_rec('wechat', 'chat1', 'u1', 'write'));

    // 并发：撤销 u1 与重新授权 u1（同身份）同时进行。行级 upsert 在事务内
    // 「删旧身份行+插最新」，不与 revoke 的部分唯一索引冲突，且后写生效。
    await Future.wait([
      store.revoke(channelType: 'wechat', chatId: 'chat1', userId: 'u1'),
      store.upsert(_rec('wechat', 'chat1', 'u1', 'all')),
    ]);

    final rows = await store.listAll(channelType: 'wechat', chatId: 'chat1');
    expect(rows.length, 1, reason: '并发同身份操作不得违反部分唯一索引');
    expect(rows.single.isActive, isTrue, reason: '重新授权（后写）应生效');
    expect(rows.single.scope, RemotePermissionScope.all);
  });

  // ================= P0-B.3 任务1：迁移标记读取失败阻断（新增） =================

  test('P0-B.3-1c 迁移标记读取失败 + 非空授权表 → fail-closed，不重导覆写既有授权', () async {
    // 表已有授权（模拟已迁移/已授权状态）：若标记读取失败被误当「未迁移」
    // 并走旧 JSON 重导，会清表覆写为旧 JSON 内容（数据一致性风险）。
    await db.into(db.remoteAuthorizations).insert(RemoteAuthorizationsCompanion.insert(
      channelType: 'wechat',
      chatId: 'chat1',
      userId: const Value(null),
      scope: 'write',
      grantedAt: DateTime.parse('2026-01-01T00:00:00.000Z'),
    ));
    // 旧 JSON 存在（chat2，若被误重导会覆写掉 chat1）。
    await seedLegacy(legacyJson([
      {
        'channel_type': 'qq',
        'chat_id': 'chat2',
        'scope': 'read',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]));
    // marker 读取抛错（app_settings 表故障）。
    await db.customStatement('ALTER TABLE app_settings RENAME TO app_settings_bak');

    // 迁移状态未知 → 所有授权读取/写入进入明确失败路径（fail-closed）。
    await expectLater(store.read(remoteChannelAuthorizationsKey), throwsA(anything));
    await expectLater(
      store.write(remoteChannelAuthorizationsKey, '[]'),
      throwsA(anything),
    );
    await expectLater(
      store.upsert(_rec('wechat', 'chat9', null, 'write')),
      throwsA(anything),
    );
    await expectLater(
      store.revoke(channelType: 'wechat', chatId: 'chat1'),
      throwsA(anything),
    );
    await expectLater(store.listAll(), throwsA(anything));
    await expectLater(
      store.readActive(channelType: 'wechat', chatId: 'chat1'),
      throwsA(anything),
    );

    // 表数据未被清表重导（chat1 保留，未变成旧 JSON 的 chat2）。
    final rows = await tableRecords();
    expect(rows.length, 1, reason: '标记读取失败不得重导覆写既有授权表');
    expect(rows.single.channelType, 'wechat');
    expect(rows.single.scope, RemotePermissionScope.write);
    // 原始 JSON 保留（未删除历史数据；app_settings 已改名，直查 app_settings_bak）。
    final preserved = await db.customSelect(
      'SELECT value FROM app_settings_bak WHERE key = ?',
      variables: [Variable.withString(remoteChannelAuthorizationsKey)],
    ).getSingleOrNull();
    expect(preserved?.data['value'], isNotNull,
        reason: '标记读取失败必须保留原始 JSON');

    // 恢复后重试：标记未置，正常迁移（旧 JSON 权威导入）。
    await db.customStatement('ALTER TABLE app_settings_bak RENAME TO app_settings');
    await store.read(remoteChannelAuthorizationsKey);
    expect(await db.appSettingsDao.get(remoteAuthorizationsMigratedKey), '1');
    final after = await tableRecords();
    expect(after.length, 1, reason: '恢复后重试应成功迁移（导入旧 JSON）');
    expect(after.single.channelType, 'qq');
  });

  test('P0-B.3-1d 迁移导入已撤销授权 → 保留 revokedAt（撤销状态不丢失）', () async {
    await seedLegacy(legacyJson([
      {
        'channel_type': 'wechat',
        'chat_id': 'chat1',
        'scope': 'write',
        'granted_at': '2026-01-01T00:00:00.000Z',
        'revoked_at': '2026-01-02T00:00:00.000Z',
      },
      {
        'channel_type': 'wechat',
        'chat_id': 'chat2',
        'scope': 'read',
        'granted_at': '2026-01-01T00:00:00.000Z',
      },
    ]));
    await store.read(remoteChannelAuthorizationsKey);
    final rows = await tableRecords();
    expect(rows.length, 2);
    final revoked = rows.singleWhere((r) => r.chatId == 'chat1');
    expect(revoked.isActive, isFalse, reason: '已撤销授权迁移后必须保持撤销态');
    expect(
      revoked.revokedAt!.toUtc(),
      DateTime.parse('2026-01-02T00:00:00.000Z'),
      reason: '迁移导入保留 revokedAt 时间戳',
    );
    final active = rows.singleWhere((r) => r.chatId == 'chat2');
    expect(active.isActive, isTrue, reason: '活动授权迁移后保持活动');
  });

}


/// P0-B.1 M2 测试辅助：构造一条授权记录（M2 行级操作用）。
RemoteAuthorizationRecord _rec(
  String channelType,
  String chatId,
  String? userId,
  String scope,
) {
  return RemoteAuthorizationRecord(
    channelType: channelType,
    chatId: chatId,
    userId: userId,
    scope: RemotePermissionScope.values.firstWhere((e) => e.name == scope),
    grantedAt: DateTime.now(),
  );
}
