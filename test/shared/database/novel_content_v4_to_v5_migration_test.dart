// 职责: 验证内容库 schema v4 → v5 的直接升级：新增 Arcs（叙事弧线）与
//       ReaderPerspectives（读者认知）两张表，旧表（含 M4 影响审计）结构与
//       数据完整保留，新表结构正确，Typed DAO 读取正常。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (schemaVersion=5, onUpgrade)
//   lib/shared/database/novel_content_daos/arc_dao.dart
//   lib/shared/database/novel_content_daos/reader_perspective_dao.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md（发布升级回归：上一正式版 v4 直接升 v5）

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';

void main() {
  /// 构造一份「带真实旧数据的 v4 fixture」：
  /// 1. 以当前 schema 建库，写入旧数据（含 M4 影响审计，不含 arcs / reader_perspectives）
  /// 2. 删除 Arcs、ReaderPerspectives 表（模拟 v4 本就没有这两张表）
  /// 3. 将 user_version 降回 4，模拟「上一正式版」
  Future<File> buildV4Fixture() async {
    final directory = await Directory.systemTemp.createTemp('rv-v4-fixture-');
    final file = File('${directory.path}/content.sqlite');
    var db = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      // 旧数据：人物 + 章节 + M2 锁定/正典 + M4 影响审计。
      await db.into(db.characterProfiles).insert(
            CharacterProfilesCompanion.insert(
              id: 'c_hero',
              name: '林晚',
              appearance: const Value('黑色长发，左眼角有泪痣'),
              biography: const Value('v4 时代旧档案，升级后必须原样保留。'),
            ),
          );
      await db.into(db.chapters).insert(
            ChaptersCompanion.insert(
              id: 'ch_vol1',
              type: 'volume',
              siblingOrder: 0,
              title: const Value('第一卷 风起'),
              outline: const Value('v4 时代旧卷纲'),
            ),
          );
      await db.into(db.chapters).insert(
            ChaptersCompanion.insert(
              id: 'ch_1',
              type: 'chapter',
              parentId: const Value('ch_vol1'),
              siblingOrder: 0,
              title: const Value('第一章 初雪'),
              content: const Value('v4 时代旧正文内容。'),
              wordCount: const Value(11),
            ),
          );
      // M2 内容级锁 + 正典。
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
              fact: const Value('林晚为女主，v4 正典内容。'),
              source: 'migration_test',
            ),
          );
      // M4 影响审计（v4 引入，升级后同样要保留）。
      await db.into(db.impactAudits).insert(
            ImpactAuditsCompanion.insert(
              id: 'ia_1',
              changeId: 'wch_1',
              resourcePath: 'characters/c_hero',
              resourceType: 'character',
              resourceId: 'c_hero',
              resultJson: '{"summary":"v4 影响审计"}',
              status: const Value(impactAuditStatusRecorded),
              hitCount: const Value(1),
            ),
          );
      await db.close();
    } catch (_) {
      await db.close();
      rethrow;
    }

    // 用 sqlite3 删除新表并把版本降到 4（模拟真实 v4 库）。
    final db2 = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      await db2.customStatement('DROP TABLE IF EXISTS arcs');
      await db2.customStatement('DROP TABLE IF EXISTS reader_perspectives');
      await db2.customStatement('PRAGMA user_version = 4');
      expect(
        (await db2
                .customSelect('PRAGMA user_version')
                .getSingle())
            .data['user_version'],
        4,
      );
      await db2.close();
    } catch (_) {
      await db2.close();
      rethrow;
    }
    return file;
  }

  test('v4 → v5 直接升级：新增 Arcs/ReaderPerspectives 表、旧数据保留、DAO 读取正常', () async {
    final file = await buildV4Fixture();
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
              "AND name IN ('arcs', 'reader_perspectives')",
            )
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(tables, {'arcs', 'reader_perspectives'});

    // 3. 新表结构正确（主键）。
    for (final tableName in ['arcs', 'reader_perspectives']) {
      final pk = (await db
              .customSelect('PRAGMA table_info($tableName)')
              .get())
          .where((r) => r.read<int>('pk') > 0)
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(pk, {'id'}, reason: '$tableName 主键应为 id');
    }

    // 4. 旧数据零丢失（M2/M4 表 + 人物/章节关键字段原样）。
    Future<int> count(String sql) async =>
        (await db.customSelect(sql).getSingle()).data.values.single as int;
    expect(await count('SELECT COUNT(*) FROM character_profiles'), 1);
    expect(await count('SELECT COUNT(*) FROM chapter_nodes'), 2);
    expect(await count('SELECT COUNT(*) FROM content_locks'), 1);
    expect(await count('SELECT COUNT(*) FROM canon_entries'), 1);
    expect(await count('SELECT COUNT(*) FROM impact_audits'), 1);
    final hero = await db.customSelect(
      "SELECT name, biography, appearance FROM character_profiles WHERE id='c_hero'",
    ).getSingle();
    expect(hero.read<String>('name'), '林晚');
    expect(hero.read<String>('biography'), 'v4 时代旧档案，升级后必须原样保留。');

    final audit = await db.impactAuditDao.getByChangeId('wch_1');
    expect(audit, isNotNull);
    expect(audit!.status, impactAuditStatusRecorded);

    // 5. 通过 Typed DAO 读写新表（Arcs）。
    await db.into(db.arcs).insert(
          ArcsCompanion.insert(
            id: 'arc_main_1',
            projectId: const Value('novel_x'),
            type: arcTypeMain,
            title: const Value('主线：夺回星核'),
            goal: const Value('林晚夺回星核，揭开身世'),
            status: const Value(arcStatusActive),
            sortOrder: const Value(1),
            startChapterId: const Value('ch_1'),
          ),
        );
    final arcs = await db.arcDao.listByProject('novel_x');
    expect(arcs, hasLength(1));
    expect(arcs.single.type, arcTypeMain);
    expect(arcs.single.status, arcStatusActive);
    await db.arcDao.updateStatus('arc_main_1', arcStatusCompleted);
    expect(
      (await db.arcDao.getById('arc_main_1'))!.status,
      arcStatusCompleted,
    );
    await db.arcDao.softDelete('arc_main_1');
    expect(await db.arcDao.listByProject('novel_x'), isEmpty);

    // 6. 通过 Typed DAO 读写新表（ReaderPerspectives，含 uniqueKeys 覆盖）。
    await db.into(db.readerPerspectives).insert(
          ReaderPerspectivesCompanion.insert(
            id: 'rp_1',
            factId: 'f_secret',
            subject: 'reader',
            state: const Value(readerPerspectiveStateAware),
            storyTime: const Value('卷2第7章'),
            disclosureAnchor: const Value('卷2第9章·场景3'),
            evidence: const Value('ch_21: "Shen Yan appears"'),
          ),
        );
    final rp1 = await db.readerPerspectiveDao.listByFact('f_secret');
    expect(rp1, hasLength(1));
    expect(rp1.single.subject, 'reader');
    expect(rp1.single.state, readerPerspectiveStateAware);

    // uniqueKeys {factId, subject, deletedAt}：同键覆盖保持单条。
    await db.readerPerspectiveDao.upsert(
      ReaderPerspectivesCompanion(
        id: const Value('rp_1'),
        factId: const Value('f_secret'),
        subject: const Value('reader'),
        state: const Value(readerPerspectiveStateRevealed),
        updatedAt: Value(DateTime.now()),
      ),
    );
    expect(await db.readerPerspectiveDao.listByFact('f_secret'), hasLength(1));
    expect(
      (await db.readerPerspectiveDao.listByFact('f_secret')).single.state,
      readerPerspectiveStateRevealed,
    );
    await db.readerPerspectiveDao.softDelete('rp_1');
    expect(await db.readerPerspectiveDao.listByFact('f_secret'), isEmpty);

    // 7. 新表默认值（deletedAt 零点哨兵、status/state 默认常量）。
    await db.into(db.arcs).insert(
          ArcsCompanion.insert(id: 'arc_2', type: arcTypeSub),
        );
    final arc2 = (await db.arcDao.getById('arc_2'))!;
    expect(arc2.deletedAt, notDeletedSentinel);
    expect(arc2.status, arcStatusDraft);
  });
}