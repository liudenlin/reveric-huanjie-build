// 职责: 验证既有 v6 库升级到 v7 时，官方 v0.9.0 的 provider_assets 列扩展被
//       后补迁移补齐（官方把列加进了 v5，v5 已被 v6 库跳过导致漏加），且旧
//       记录保留并回填默认 kind=certification。
// 关联文件:
//   lib/shared/database/app_database_migrations.dart
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';

void main() {
  test('schema v6 backfills provider_assets columns on upgrade to v7', () async {
    final db = AppDatabase.forTest(
      NativeDatabase.memory(
        setup: (sqlite) {
          // v6 真实 schema：provider_assets 无官方 v0.9.0 的 4 列
          // （kind/context_hash/remote_url/expires_at 在 v5 里加，v6 库跳过）。
          sqlite.execute('''
            CREATE TABLE provider_assets (
              id TEXT NOT NULL PRIMARY KEY,
              asset_id TEXT NOT NULL,
              provider_id TEXT NOT NULL,
              remote_id TEXT,
              remote_task_id TEXT,
              remote_group_id TEXT,
              status TEXT NOT NULL,
              error_code TEXT,
              error_message TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              deleted_at INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO provider_assets
              (id,asset_id,provider_id,remote_id,status,created_at,updated_at,deleted_at)
              VALUES ('old','a','p','remote','active',10,20,0);
            PRAGMA user_version = 6;
          ''');
        },
      ),
    );
    addTearDown(db.close);

    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).data.values.single,
      AppDatabase.currentSchemaVersion,
    );
    final cols = await db
        .customSelect('PRAGMA table_info(provider_assets)')
        .get();
    final names = cols.map((c) => c.data['name']).toSet();
    for (final expected in ['kind', 'context_hash', 'remote_url', 'expires_at']) {
      expect(names, contains(expected), reason: 'missing $expected');
    }
    expect(
      cols.singleWhere((c) => c.data['name'] == 'kind').data['type'],
      'TEXT',
    );
    expect(
      cols.singleWhere((c) => c.data['name'] == 'kind').data['dflt_value'],
      "'certification'",
    );
    expect(
      cols.singleWhere((c) => c.data['name'] == 'expires_at').data['type'],
      'INTEGER',
    );
    // 旧记录保留，kind 回填默认 certification。
    final row = (await db
        .customSelect("SELECT id, kind FROM provider_assets WHERE id='old'")
        .get())
        .single;
    expect(row.data['id'], 'old');
    expect(row.data['kind'], 'certification');
  });
}
