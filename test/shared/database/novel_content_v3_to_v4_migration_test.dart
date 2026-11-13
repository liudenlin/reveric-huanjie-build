// 职责: 验证内容库 schema v3 → v4 的直接升级：新增 ImpactAudits 表，
//       旧表（含 M2 锁定/正典）结构与数据完整保留，新表结构正确，
//       Typed DAO 读取正常。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (schemaVersion=4, onUpgrade)
//   lib/shared/database/novel_content_daos/impact_audit_dao.dart
//   lib/shared/services/impact_audit_service.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md（发布升级回归：上一正式版 v3 直接升 v4）

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';

void main() {
  /// 构造一份「带真实旧数据的 v3 fixture」：
  /// 1. 以当前 schema 建库，写入旧数据（含 M2 锁定/正典，不含 impact_audits）
  /// 2. 删除 ImpactAudits 表（模拟 v3 本就没有这张表）
  /// 3. 将 user_version 降回 3，模拟「上一正式版」
  Future<File> buildV3Fixture() async {
    final directory = await Directory.systemTemp.createTemp('rv-v3-fixture-');
    final file = File('${directory.path}/content.sqlite');
    var db = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      // 旧数据：人物 + 章节 + M2 锁定 + 正典。
      await db.into(db.characterProfiles).insert(
            CharacterProfilesCompanion.insert(
              id: 'c_hero',
              name: '林晚',
              appearance: const Value('黑色长发，左眼角有泪痣'),
              biography: const Value('v3 时代旧档案，升级后必须原样保留。'),
            ),
          );
      await db.into(db.chapters).insert(
            ChaptersCompanion.insert(
              id: 'ch_vol1',
              type: 'volume',
              siblingOrder: 0,
              title: const Value('第一卷 风起'),
              outline: const Value('v3 时代旧卷纲'),
            ),
          );
      await db.into(db.chapters).insert(
            ChaptersCompanion.insert(
              id: 'ch_1',
              type: 'chapter',
              parentId: const Value('ch_vol1'),
              siblingOrder: 0,
              title: const Value('第一章 初雪'),
              content: const Value('v3 时代旧正文内容。'),
              wordCount: const Value(11),
            ),
          );
      // M2 内容级锁 + 正典（v3 引入，升级后同样要保留）。
      await db.into(db.contentLocks).insert(
            ContentLocksCompanion.insert(
              id: 'lk_1',
              scope: lockScopeObject,
              resourceType: 'chapter',
              resourceId: const Value('ch_1'),
              reason: const Value('终稿锁定'),
            ),
          );
      await db.into(db.canonEntries).insert(
            CanonEntriesCompanion.insert(
              id: 'cn_1',
              resourceType: 'character',
              resourceId: 'c_hero',
              level: canonLevelCanon,
              fact: const Value('林晚为女主，v3 正典内容。'),
              source: 'migration_test',
            ),
          );
      await db.close();
    } catch (_) {
      await db.close();
      rethrow;
    }

    // 用 sqlite3 删除新表并把版本降到 3（模拟真实 v3 库）。
    final db2 = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      await db2.customStatement('DROP TABLE IF EXISTS impact_audits');
      await db2.customStatement('PRAGMA user_version = 3');
      expect(
        (await db2
                .customSelect('PRAGMA user_version')
                .getSingle())
            .data['user_version'],
        3,
      );
      await db2.close();
    } catch (_) {
      await db2.close();
      rethrow;
    }
    return file;
  }

  test('v3 → v4 直接升级：新增 ImpactAudits 表、旧数据保留、DAO 读取正常', () async {
    final file = await buildV3Fixture();
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
              "AND name IN ('impact_audits')",
            )
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(tables, {'impact_audits'});

    // 3. 新表结构正确（主键）。
    final pk = (await db
            .customSelect('PRAGMA table_info(impact_audits)')
            .get())
        .where((r) => r.read<int>('pk') > 0)
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(pk, {'id'});

    // 4. 旧数据零丢失（M2 表 + 人物/章节关键字段原样）。
    Future<int> count(String sql) async =>
        (await db.customSelect(sql).getSingle()).data.values.single as int;
    expect(await count('SELECT COUNT(*) FROM character_profiles'), 1);
    expect(await count('SELECT COUNT(*) FROM chapter_nodes'), 2);
    expect(await count('SELECT COUNT(*) FROM content_locks'), 1);
    expect(await count('SELECT COUNT(*) FROM canon_entries'), 1);
    final hero = await db.customSelect(
      "SELECT name, biography, appearance FROM character_profiles WHERE id='c_hero'",
    ).getSingle();
    expect(hero.read<String>('name'), '林晚');
    expect(hero.read<String>('biography'), 'v3 时代旧档案，升级后必须原样保留。');

    final lock = await db.contentLockDao.findById('lk_1');
    expect(lock, isNotNull);
    expect(lock!.active, true);
    final canon = await db.canonEntryDao.findById('cn_1');
    expect(canon, isNotNull);
    expect(canon!.level, canonLevelCanon);

    // 5. 通过 Typed DAO 读写新表（捕获双引号标识符被当文本的假绿灯）。
    await db.into(db.impactAudits).insert(
          ImpactAuditsCompanion.insert(
            id: 'ia_1',
            changeId: 'wch_1',
            resourcePath: 'characters/c_hero',
            resourceType: 'character',
            resourceId: 'c_hero',
            resultJson: '{"summary":"test"}',
            status: const Value(impactAuditStatusRecorded),
            hitCount: const Value(1),
          ),
        );
    final audit = await db.impactAuditDao.getByChangeId('wch_1');
    expect(audit, isNotNull);
    expect(audit!.id, 'ia_1');
    expect(audit.resourceType, 'character');
    expect(audit.status, impactAuditStatusRecorded);
    expect(audit.hitCount, 1);

    // 6. 待复核聚合查询。
    expect(await db.impactAuditDao.hasPendingReview('characters/c_hero'), isTrue);
    await db.impactAuditDao.markReviewed('ia_1');
    expect(await db.impactAuditDao.hasPendingReview('characters/c_hero'), isFalse);
    final reviewed = await db.impactAuditDao.getById('ia_1');
    expect(reviewed!.status, impactAuditStatusReviewed);
  });
}