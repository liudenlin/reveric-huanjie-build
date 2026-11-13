// 职责: R-33 单部局部(project) AgentSkill 覆盖集增删改查 —— 按 novel 维度读写，
//   `novel_id + name` 唯一，references 独立子表。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/providers/project_agent_skill_providers.dart
//   lib/shared/models/novel_agent_skill.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md
//   .agents/rules/db-query-aggregation.md
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../app_database.dart';
import '../../models/agent_skill_reference.dart';

part 'novel_agent_skill_override_dao.drift.dart';

@DriftAccessor(
  tables: [NovelAgentSkillOverrides, NovelAgentSkillOverrideReferences],
)
class NovelAgentSkillOverrideDao extends DatabaseAccessor<AppDatabase>
    with _$NovelAgentSkillOverrideDaoMixin {
  NovelAgentSkillOverrideDao(super.db);

  /// 某作品的全部 project 层覆盖（不含 references，供列表）。
  Future<List<NovelAgentSkillOverride>> getByNovelId(String novelId) {
    return (select(novelAgentSkillOverrides)
          ..where((t) => t.novelId.equals(novelId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// 某作品覆盖集的 watch 流（主表变化即推送；references 随主表一起写）。
  Stream<List<NovelAgentSkillOverride>> watchByNovelId(String novelId) {
    return (select(novelAgentSkillOverrides)
          ..where((t) => t.novelId.equals(novelId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .watch();
  }

  /// 主列表与 references 一起读取，供管理界面与完整快照场景。
  Future<Map<String, List<AgentSkillReferenceFile>>> getReferencesBySkillIds(
    Iterable<String> skillIds,
  ) async {
    final ids = skillIds.toList(growable: false);
    if (ids.isEmpty) {
      return const {};
    }
    final rows =
        await (select(novelAgentSkillOverrideReferences)
              ..where((t) => t.skillId.isIn(ids))
              ..orderBy([(t) => OrderingTerm.asc(t.path)]))
            .get();
    final result = <String, List<AgentSkillReferenceFile>>{};
    for (final row in rows) {
      (result[row.skillId] ??= <AgentSkillReferenceFile>[]).add(
        AgentSkillReferenceFile(path: row.path, content: row.content),
      );
    }
    return result;
  }

  Future<NovelAgentSkillOverride?> getById(String id) {
    return (select(
      novelAgentSkillOverrides,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<NovelAgentSkillOverride?> getByNovelIdAndName(
    String novelId,
    String name,
  ) {
    return (select(novelAgentSkillOverrides)
          ..where((t) => t.novelId.equals(novelId))
          ..where((t) => t.name.equals(name)))
        .getSingleOrNull();
  }

  /// 原子写入覆盖快照并替换其 references 子表内容。
  Future<void> upsertWithReferences({
    required NovelAgentSkillOverridesCompanion skill,
    required Iterable<AgentSkillReferenceFile> references,
  }) async {
    await transaction(() async {
      await into(novelAgentSkillOverrides).insertOnConflictUpdate(skill);
      await (delete(
        novelAgentSkillOverrideReferences,
      )..where((t) => t.skillId.equals(skill.id.value))).go();
      final now = DateTime.now();
      for (final ref in references) {
        await into(novelAgentSkillOverrideReferences).insert(
          NovelAgentSkillOverrideReferencesCompanion.insert(
            skillId: skill.id.value,
            path: ref.path,
            content: ref.content,
            byteSize: utf8.encode(ref.content).length,
            sha256: Value(sha256.convert(utf8.encode(ref.content)).toString()),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
      }
    });
  }

  /// 删除覆盖及其 references。
  ///
  /// 显式删子表而不依赖表定义上的级联 —— 本库没有开启 `PRAGMA foreign_keys`，
  /// 只删主表会在 references 里留下永久孤儿行。
  Future<int> hardDelete(String id) async {
    return transaction(() async {
      await (delete(
        novelAgentSkillOverrideReferences,
      )..where((t) => t.skillId.equals(id))).go();
      return (delete(
        novelAgentSkillOverrides,
      )..where((t) => t.id.equals(id))).go();
    });
  }
}
