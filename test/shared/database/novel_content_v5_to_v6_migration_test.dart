// 职责: 验证内容库 schema v5 → v6 的直接升级：新增 FactProposals（记忆变更提案）
//       与 DecisionLogs（作者裁决账本）两张表，旧表（含 M6b 弧线/M6c 读者认知/
//       M4 影响审计）结构与数据完整保留，新表结构正确，Typed DAO 读写正常。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (schemaVersion=6, onUpgrade)
//   lib/shared/database/novel_content_daos/fact_proposal_dao.dart
//   lib/shared/database/novel_content_daos/decision_log_dao.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md（发布升级回归：上一正式版 v5 直接升 v6）

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';

void main() {
  /// 构造一份「带真实旧数据的 v5 fixture」：
  /// 1. 以当前 schema 建库，写入旧数据（含 M6b 弧线/M6c 读者认知/M4 影响审计）
  /// 2. 删除 FactProposals、DecisionLogs 表（模拟 v5 本就没有这两张表）
  /// 3. 将 user_version 降回 5，模拟「上一正式版」
  Future<File> buildV5Fixture() async {
    final directory = await Directory.systemTemp.createTemp('rv-v5-fixture-');
    final file = File('${directory.path}/content.sqlite');
    var db = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      // 旧数据：人物 + 章节 + M2 锁定/正典 + M4 影响审计 + M6b 弧线 + M6c 读者认知。
      await db.into(db.characterProfiles).insert(
            CharacterProfilesCompanion.insert(
              id: 'c_hero',
              name: '林晚',
              appearance: const Value('黑色长发，左眼角有泪痣'),
              biography: const Value('v5 时代旧档案，升级后必须原样保留。'),
            ),
          );
      await db.into(db.chapters).insert(
            ChaptersCompanion.insert(
              id: 'ch_vol1',
              type: 'volume',
              siblingOrder: 0,
              title: const Value('第一卷 风起'),
              outline: const Value('v5 时代旧卷纲'),
            ),
          );
      await db.into(db.chapters).insert(
            ChaptersCompanion.insert(
              id: 'ch_1',
              type: 'chapter',
              parentId: const Value('ch_vol1'),
              siblingOrder: 0,
              title: const Value('第一章 初雪'),
              content: const Value('v5 时代旧正文内容。'),
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
              fact: const Value('林晚为女主，v5 正典内容。'),
              source: 'migration_test',
            ),
          );
      // M4 影响审计。
      await db.into(db.impactAudits).insert(
            ImpactAuditsCompanion.insert(
              id: 'ia_1',
              changeId: 'wch_1',
              resourcePath: 'characters/c_hero',
              resourceType: 'character',
              resourceId: 'c_hero',
              resultJson: '{"summary":"v5 影响审计"}',
              status: const Value(impactAuditStatusRecorded),
              hitCount: const Value(1),
            ),
          );
      // M6b 弧线。
      await db.into(db.arcs).insert(
            ArcsCompanion.insert(
              id: 'arc_main_1',
              projectId: const Value('novel_x'),
              type: arcTypeMain,
              title: const Value('主线：夺回星核'),
              goal: const Value('林晚夺回星核'),
              status: const Value(arcStatusActive),
              sortOrder: const Value(1),
            ),
          );
      // M6c 读者认知。
      await db.into(db.readerPerspectives).insert(
            ReaderPerspectivesCompanion.insert(
              id: 'rp_1',
              factId: 'f_secret',
              subject: 'reader',
              state: const Value(readerPerspectiveStateMisled),
              disclosureAnchor: const Value('卷2第9章'),
            ),
          );
      await db.close();
    } catch (_) {
      await db.close();
      rethrow;
    }

    // 用 sqlite3 删除新表并把版本降到 5（模拟真实 v5 库）。
    final db2 = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      await db2.customStatement('DROP TABLE IF EXISTS fact_proposals');
      await db2.customStatement('DROP TABLE IF EXISTS decision_logs');
      await db2.customStatement('PRAGMA user_version = 5');
      expect(
        (await db2
                .customSelect('PRAGMA user_version')
                .getSingle())
            .data['user_version'],
        5,
      );
      await db2.close();
    } catch (_) {
      await db2.close();
      rethrow;
    }
    return file;
  }

  test('v5 → v6 直接升级：新增 FactProposals/DecisionLogs 表、旧数据保留、DAO 读写正常', () async {
    final file = await buildV5Fixture();
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
              "AND name IN ('fact_proposals', 'decision_logs')",
            )
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(tables, {'fact_proposals', 'decision_logs'});

    // 3. 新旧表主键都是 id。
    for (final tableName in ['fact_proposals', 'decision_logs']) {
      final pk = (await db
              .customSelect('PRAGMA table_info($tableName)')
              .get())
          .where((r) => r.read<int>('pk') > 0)
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(pk, {'id'}, reason: '$tableName 主键应为 id');
    }

    // 4. 旧数据零丢失（M2/M4/M6b/M6c 表 + 人物/章节关键字段原样）。
    Future<int> count(String sql) async =>
        (await db.customSelect(sql).getSingle()).data.values.single as int;
    expect(await count('SELECT COUNT(*) FROM character_profiles'), 1);
    expect(await count('SELECT COUNT(*) FROM chapter_nodes'), 2);
    expect(await count('SELECT COUNT(*) FROM content_locks'), 1);
    expect(await count('SELECT COUNT(*) FROM canon_entries'), 1);
    expect(await count('SELECT COUNT(*) FROM impact_audits'), 1);
    expect(await count('SELECT COUNT(*) FROM arcs'), 1);
    expect(await count('SELECT COUNT(*) FROM reader_perspectives'), 1);

    final hero = await db.customSelect(
      "SELECT name, biography, appearance FROM character_profiles WHERE id='c_hero'",
    ).getSingle();
    expect(hero.read<String>('name'), '林晚');
    expect(hero.read<String>('biography'), 'v5 时代旧档案，升级后必须原样保留。');

    // 弧线/读者认知读回正常（M6b/M6c 数据跨版本保留）。
    final arc = (await db.arcDao.getById('arc_main_1'))!;
    expect(arc.type, arcTypeMain);
    expect(arc.status, arcStatusActive);
    final rp = (await db.readerPerspectiveDao.getById('rp_1'))!;
    expect(rp.state, readerPerspectiveStateMisled);

    // 5. 通过 Typed DAO 读写新表（FactProposals）。
    await db.into(db.factProposals).insert(
          FactProposalsCompanion.insert(
            id: 'proposal_1',
            projectId: const Value('novel_x'),
            targetType: 'character',
            targetId: 'c_hero',
            predicate: const Value('biography'),
            proposedValue: const Value('林晚幼年随师习剑。'),
            expectedHash: const Value('rev-1'),
            evidenceJson: const Value('[{"sourceAnchor":"ch_1#0","quote":"随师习剑"}]'),
            confidence: const Value(0.9),
            sourceModel: const Value('test-model'),
            reviewStatus: const Value(proposalReviewStatusPending),
          ),
        );
    final proposal = await db.factProposalDao.listByProject('novel_x');
    expect(proposal, hasLength(1));
    expect(proposal.single.targetType, 'character');
    expect(proposal.single.reviewStatus, proposalReviewStatusPending);
    expect(proposal.single.confidence, 0.9);

    // 6. 通过 Typed DAO 读写新表（DecisionLogs，Append-only）。
    final now = DateTime.now();
    await db.into(db.decisionLogs).insert(
          DecisionLogsCompanion.insert(
            id: 'decide_1',
            proposalId: 'proposal_1',
            actor: const Value(decisionActorAuthor),
            decision: decisionActionAccept,
            comment: const Value('确认采纳'),
            expectedHash: const Value('rev-1'),
            createdAt: Value(now.add(const Duration(milliseconds: 1))),
          ),
        );
    await db.into(db.decisionLogs).insert(
          DecisionLogsCompanion.insert(
            id: 'decide_2',
            proposalId: 'proposal_1',
            actor: const Value(decisionActorAuthor),
            decision: decisionActionReject,
            comment: const Value('后改主意，全部保留账本'),
            createdAt: Value(now),
          ),
        );
    final logs = await db.decisionLogDao.listByProposal('proposal_1');
    expect(logs, hasLength(2)); // Append-only：两次裁决都保留
    expect(logs.map((l) => l.decision).toSet(),
        {decisionActionAccept, decisionActionReject});

    // 7. 默认值：提案 deletedAt 哨兵、confidence 默认、日志 actor 默认。
    await db.into(db.factProposals).insert(
          FactProposalsCompanion.insert(
            id: 'proposal_defaults',
            targetType: 'world',
            targetId: 'star_core',
          ),
        );
    final defaults = (await db.factProposalDao.getById('proposal_defaults'))!;
    expect(defaults.deletedAt, notDeletedSentinel);
    expect(defaults.reviewStatus, proposalReviewStatusPending);
    expect(defaults.confidence, 0.5);
  });
}