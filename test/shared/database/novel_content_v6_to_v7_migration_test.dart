// 职责: 验证内容库 schema v6 → v7 的直接升级：新增 ResearchTasks（M7 研究任务）
//       与 AssetVersions（M5 资产版本历史）两张表，旧表（M2/M3/M4/M6）结构与
//       数据完整保留，新表结构正确、Typed DAO 读写正常。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (schemaVersion=7, onUpgrade)
//   lib/shared/database/novel_content_daos/research_task_dao.dart
//   lib/shared/database/novel_content_daos/asset_version_dao.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md（发布升级回归：上一正式版 v6 直接升 v7）

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';

void main() {
  /// 构造一份「带真实旧数据的 v6 fixture」：
  /// 1. 以当前 schema 建库，写入旧数据（M2 锁定/M3 正典/M6e 提案/账本）
  /// 2. 删除 ResearchTasks、AssetVersions 表（模拟 v6 本就没有这两张表）
  /// 3. 将 user_version 降回 6，模拟「上一正式版」
  Future<File> buildV6Fixture() async {
    final directory = await Directory.systemTemp.createTemp('rv-v6-fixture-');
    final file = File('${directory.path}/content.sqlite');
    var db = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      // 旧数据：M2 内容级锁 + 正典。
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
          fact: const Value('林晚为女主，v6 正典内容。'),
          source: 'migration_test',
        ),
      );
      // M6e 记忆提案 + 裁决账本。
      await db.into(db.factProposals).insert(
        FactProposalsCompanion.insert(
          id: 'prop_1',
          projectId: const Value('novel_x'),
          targetType: 'character',
          targetId: 'c_hero',
          reviewStatus: const Value(proposalReviewStatusPending),
        ),
      );
      await db.into(db.decisionLogs).insert(
        DecisionLogsCompanion.insert(
          id: 'dec_1',
          proposalId: 'prop_1',
          decision: decisionActionAccept,
        ),
      );
      await db.close();
    } catch (_) {
      await db.close();
      rethrow;
    }

    // 用 sqlite3 删除新表并把版本降到 6（模拟真实 v6 库）。
    final db2 = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      await db2.customStatement('DROP TABLE IF EXISTS research_tasks');
      await db2.customStatement('DROP TABLE IF EXISTS asset_versions');
      await db2.customStatement('PRAGMA user_version = 6');
      expect(
        (await db2.customSelect('PRAGMA user_version').getSingle())
            .data['user_version'],
        6,
      );
      await db2.close();
    } catch (_) {
      await db2.close();
      rethrow;
    }
    return file;
  }

  test('v6 → v7 直接升级：新增 ResearchTasks/AssetVersions 表、旧数据保留、DAO 读写正常', () async {
    final file = await buildV6Fixture();
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
              "AND name IN ('research_tasks', 'asset_versions')",
            )
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(tables, {'research_tasks', 'asset_versions'});

    // 3. 新旧表主键都是 id。
    for (final tableName in ['research_tasks', 'asset_versions']) {
      final pk = (await db
              .customSelect('PRAGMA table_info($tableName)')
              .get())
          .where((r) => r.read<int>('pk') > 0)
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(pk, {'id'}, reason: '$tableName 主键应为 id');
    }

    // 4. 旧数据零丢失（M2/M6e 表 + 关键字段原样）。
    Future<int> count(String sql) async =>
        (await db.customSelect(sql).getSingle()).data.values.single as int;
    expect(await count('SELECT COUNT(*) FROM content_locks'), 1);
    expect(await count('SELECT COUNT(*) FROM canon_entries'), 1);
    expect(await count('SELECT COUNT(*) FROM fact_proposals'), 1);
    expect(await count('SELECT COUNT(*) FROM decision_logs'), 1);

    // 5. M7 ResearchTasks Typed DAO 读写。
    await db.into(db.researchTasks).insert(
      ResearchTasksCompanion.insert(
        id: 'rt_1',
        title: '研究反派动机',
        prompt: '为什么反派要夺取星核？',
        projectId: const Value('novel_x'),
        providerId: const Value('openai'),
        modelId: const Value('gpt-4o'),
        budgetTokens: const Value(50000),
        status: const Value(researchTaskStatusPendingApproval),
      ),
    );
    final tasks = await db.researchTaskDao.listByProject('novel_x');
    expect(tasks, hasLength(1));
    expect(tasks.single.budgetTokens, 50000);
    expect(tasks.single.status, researchTaskStatusPendingApproval);

    // 6. M7 addSpent 增量累计（预算熔断数据源）。
    final after = await db.researchTaskDao.addSpent('rt_1', 1000, 500);
    expect(after, isNotNull);
    expect(after!.spentTokens, 1000);
    expect(after.spentCostMicros, 500);
    final after2 = await db.researchTaskDao.addSpent('rt_1', 200, 100);
    expect(after2!.spentTokens, 1200, reason: '增量累计应为 1000+200');
    expect(after2.spentCostMicros, 600);

    // 7. M7 状态机迁移：pending→approved→running→completed。
    await db.researchTaskDao.updateStatus(
      'rt_1',
      researchTaskStatusApproved,
      approvedAt: DateTime.now(),
    );
    var task = (await db.researchTaskDao.getById('rt_1'))!;
    expect(task.status, researchTaskStatusApproved);
    expect(task.approvedAt, isNotNull);
    await db.researchTaskDao.updateStatus(
      'rt_1',
      researchTaskStatusCompleted,
      resultText: '反派为复活亡妻。',
      completedAt: DateTime.now(),
    );
    task = (await db.researchTaskDao.getById('rt_1'))!;
    expect(task.status, researchTaskStatusCompleted);
    expect(task.resultText, '反派为复活亡妻。');

    // 8. M5 AssetVersions Typed DAO 读写。
    await db.into(db.assetVersions).insert(
      AssetVersionsCompanion.insert(
        id: 'av_1',
        assetId: 'asset_face_1',
        novelId: Value('novel_x'),
        version: Value(1),
        snapshotPath: const Value('data/assets/a1.png'),
        snapshotSha256: const Value('deadbeef'),
        snapshotName: const Value('林晚_v1.png'),
        source: const Value('generated'),
      ),
    );
    final versions = await db.assetVersionDao.listByAsset('asset_face_1');
    expect(versions, hasLength(1));
    expect(versions.single.version, 1);
    expect(versions.single.source, 'generated');

    // 9. M5 currentVersion 递增逻辑。
    expect(await db.assetVersionDao.currentVersion('asset_face_1'), 1);
    await db.into(db.assetVersions).insert(
      AssetVersionsCompanion.insert(
        id: 'av_2',
        assetId: 'asset_face_1',
        novelId: Value('novel_x'),
        version: Value(2),
        snapshotPath: const Value('data/assets/a2.png'),
        snapshotSha256: const Value('cafebabe'),
      ),
    );
    expect(await db.assetVersionDao.currentVersion('asset_face_1'), 2);
    expect(await db.assetVersionDao.currentVersion('nonexistent_asset'), 0);

    // 10. 默认值：ResearchTasks/AssetVersions 软删哨兵 + 默认状态。
    await db.into(db.researchTasks).insert(
      ResearchTasksCompanion.insert(
        id: 'rt_defaults',
        title: 't',
        prompt: 'p',
      ),
    );
    final defTask = (await db.researchTaskDao.getById('rt_defaults'))!;
    expect(defTask.deletedAt, notDeletedSentinel);
    expect(defTask.status, researchTaskStatusPendingApproval);
    expect(defTask.budgetTokens, 0);
  });
}
