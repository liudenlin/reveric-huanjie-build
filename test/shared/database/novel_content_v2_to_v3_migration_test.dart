// 职责: 验证内容库 schema v2 → v3 的直接升级：新增 ContentLocks/CanonEntries 两表，
//       旧表结构与数据完整保留，新表结构正确，Typed DAO 读取正常。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (schemaVersion=3, onUpgrade)
//   lib/shared/database/novel_content_daos/content_lock_dao.dart
//   lib/shared/services/content_lock_service.dart
//   lib/shared/services/canon_service.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md（发布升级回归：上一正式版 v2 直接升 v3）

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';

void main() {
  /// 构造一份「带真实旧数据的 v2 fixture」：
  /// 1. 以当前 schema 建库，写入旧数据（不插入新表数据）
  /// 2. 删除新表（模拟 v2 本就没有这两张表）
  /// 3. 将 user_version 降回 2，模拟「上一正式版」
  Future<File> buildV2Fixture() async {
    final directory = await Directory.systemTemp.createTemp('rv-v2-fixture-');
    final file = File('${directory.path}/content.sqlite');
    var db = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      // 旧数据：人物 + 章节（卷→章）+ 设定项 + 大纲。
      await db.into(db.characterProfiles).insert(
            CharacterProfilesCompanion.insert(
              id: 'c_hero',
              name: '林晚',
              appearance: const Value('黑色长发，左眼角有泪痣'),
              biography: const Value('旧版人物档案，升级后必须原样保留。'),
            ),
          );
      await db.into(db.chapters).insert(
            ChaptersCompanion.insert(
              id: 'ch_vol1',
              type: 'volume',
              siblingOrder: 0,
              title: const Value('第一卷 风起'),
              outline: const Value('旧版卷纲'),
            ),
          );
      await db.into(db.chapters).insert(
            ChaptersCompanion.insert(
              id: 'ch_1',
              type: 'chapter',
              parentId: const Value('ch_vol1'),
              siblingOrder: 0,
              title: const Value('第一章 初雪'),
              content: const Value('旧版正文内容。'),
              wordCount: const Value(9),
            ),
          );
      await db.into(db.items).insert(
            ItemsCompanion.insert(
              id: 'it_sword',
              type: 'weapon',
              title: '断水剑',
              content: const Value('旧版设定：上古名剑。'),
            ),
          );
      await db.into(db.outlines).insert(
            OutlinesCompanion.insert(
              documentId: 'ol_1',
              title: const Value('主线大纲'),
              content: const Value('旧版大纲。'),
            ),
          );
      await db.close();
    } catch (_) {
      await db.close();
      rethrow;
    }

    // 用 sqlite3 删除新表并把版本降到 2（模拟真实 v2 库）。
    final db2 = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      await db2.customStatement('DROP TABLE IF EXISTS content_locks');
      await db2.customStatement('DROP TABLE IF EXISTS canon_entries');
      await db2.customStatement('PRAGMA user_version = 2');
      expect(
        (await db2
                .customSelect('PRAGMA user_version')
                .getSingle())
            .data['user_version'],
        2,
      );
      await db2.close();
    } catch (_) {
      await db2.close();
      rethrow;
    }
    return file;
  }

  test('v2 → v3 直接升级：新增两表、旧数据保留、DAO 读取正常', () async {
    final file = await buildV2Fixture();
    final db = NovelContentDatabase.forTest(NativeDatabase(file));
    addTearDown(db.close);

    // 1. 版本已升到当前。
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle())
          .data['user_version'],
      NovelContentDatabase.currentSchemaVersion,
    );

    // 2. 新表存在。
    final tables = (await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' "
              "AND name IN ('content_locks','canon_entries')",
            )
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(tables, {'content_locks', 'canon_entries'});

    // 3. 新表结构正确（主键）。
    Future<Set<String>> pkOf(String table) async => (await db
            .customSelect('PRAGMA table_info($table)')
            .get())
        .where((r) => r.read<int>('pk') > 0)
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(await pkOf('content_locks'), {'id'});
    expect(await pkOf('canon_entries'), {'id'});

    // 4. 旧数据零丢失（行数 + 关键字段原样）。
    Future<int> count(String sql) async =>
        (await db.customSelect(sql).getSingle()).data.values.single as int;
    expect(await count('SELECT COUNT(*) FROM character_profiles'), 1);
    expect(await count('SELECT COUNT(*) FROM chapter_nodes'), 2);
    expect(await count('SELECT COUNT(*) FROM items'), 1);
    expect(await count('SELECT COUNT(*) FROM outlines'), 1);
    final hero = await db.customSelect(
      "SELECT name, biography, appearance FROM character_profiles WHERE id='c_hero'",
    ).getSingle();
    expect(hero.read<String>('name'), '林晚');
    expect(hero.read<String>('biography'), '旧版人物档案，升级后必须原样保留。');
    expect(hero.read<String>('appearance'), '黑色长发，左眼角有泪痣');
    final chapter = await db.customSelect(
      "SELECT title, content, word_count FROM chapter_nodes WHERE id='ch_1'",
    ).getSingle();
    expect(chapter.read<String>('title'), '第一章 初雪');
    expect(chapter.read<String>('content'), '旧版正文内容。');
    expect(chapter.read<int>('word_count'), 9);

    // 5. 通过 Typed DAO 读写新表（捕获双引号标识符被当文本的假绿灯）。
    await db.into(db.contentLocks).insert(
          ContentLocksCompanion.insert(
            id: 'lk_1',
            scope: lockScopeObject,
            resourceType: 'chapter',
            resourceId: const Value('ch_1'),
            reason: const Value('终稿锁定'),
          ),
        );
    final lock = await db.contentLockDao.findById('lk_1');
    expect(lock, isNotNull);
    expect(lock!.resourceType, 'chapter');
    expect(lock.resourceId, 'ch_1');
    expect(lock.scope, lockScopeObject);
    expect(lock.active, true);

    await db.into(db.canonEntries).insert(
          CanonEntriesCompanion.insert(
            id: 'cn_1',
            resourceType: 'character',
            resourceId: 'c_hero',
            level: canonLevelCanon,
            fact: const Value('林晚为女主，旧正典内容。'),
            source: 'migration_test',
          ),
        );
    final canon = await db.canonEntryDao.findById('cn_1');
    expect(canon, isNotNull);
    expect(canon!.level, canonLevelCanon);
    expect(canon.fact, '林晚为女主，旧正典内容。');
  });
}