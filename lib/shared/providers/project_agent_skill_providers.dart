// 职责: R-33 单部局部(project) AgentSkill 覆盖集的 Riverpod 读流与 Service 写入口
//   —— 按 novel 维度管理，provider 层按 project > user > builtin 合并同名覆盖。
// 关联文件:
//   lib/shared/database/daos/novel_agent_skill_override_dao.dart
//   lib/shared/database/app_database.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/models/agent_skill_reference.dart
//   lib/shared/providers/agent_skill_providers.dart
//   lib/shared/services/ai/chat_turn_runner.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/service-naming.md
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../models/agent_skill_reference.dart';
import '../models/novel_agent_skill.dart';
import '../utils/random_id.dart';
import 'agent_skill_providers.dart' show agentSkillAppDatabaseProvider;

// ── 行 ↔ 领域模型映射 ────────────────────────────────────────────────────────

NovelAgentSkillModel _mapOverrideToModel(
  NovelAgentSkillOverride row,
  List<AgentSkillReferenceFile> references,
) {
  return NovelAgentSkillModel(
    id: row.id,
    sourceKind: AgentSkillSourceKind.fromDbValue(row.sourceKind),
    sourceListingPublicId: row.sourceListingPublicId,
    sourceVersion: row.sourceVersion,
    sourceDisplayName: row.sourceDisplayName,
    name: row.name,
    whenToUse: row.whenToUse,
    description: row.description,
    prompt: row.prompt,
    agentScopes: row.agentScopes,
    category: row.category,
    tags: row.tags,
    references: references,
    enabled: row.enabled,
    sortOrder: row.sortOrder,
    executionBlockedReason: row.executionBlockedReason,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}

/// 主表行 + 关联 references 一次读出完整领域模型（供一次性快照与流映射复用）。
Future<List<NovelAgentSkillModel>> _mapRowsToModels(
  AppDatabase db,
  List<NovelAgentSkillOverride> rows,
) async {
  final refs = await db.novelAgentSkillOverrideDao.getReferencesBySkillIds(
    rows.map((row) => row.id),
  );
  return [
    for (final row in rows) _mapOverrideToModel(row, refs[row.id] ?? const []),
  ];
}

// ── 写入输入 ─────────────────────────────────────────────────────────────────

/// project 层覆盖的写入输入（字段与 user 层安装输入一致，额外归属 [novelId]）。
class ProjectAgentSkillOverrideInput {
  const ProjectAgentSkillOverrideInput({
    required this.novelId,
    required this.name,
    required this.description,
    required this.prompt,
    this.whenToUse = '',
    this.agentScopes = const [],
    this.category = '',
    this.tags = const [],
    this.references = const [],
    this.enabled = true,
    this.existingId,
  });

  final String novelId;
  final String name;
  final String whenToUse;
  final String description;
  final String prompt;
  final List<String> agentScopes;
  final String category;
  final List<String> tags;
  final List<AgentSkillReferenceFile> references;
  final bool enabled;

  /// 已有覆盖 id；null 表示新建。
  final String? existingId;
}

// ── Service 写入口 ───────────────────────────────────────────────────────────

/// project 层覆盖的唯一写入入口（UI 与运行回调都走这里）。
///
/// 读侧用 [projectAgentSkillOverridesProvider] 的 Drift watch 流自动刷新，
/// 写后无需手写 invalidate（符合 state-management 唯一写入入口规则）。
class ProjectAgentSkillOverrideService {
  ProjectAgentSkillOverrideService(this._db);

  final AppDatabase _db;

  /// 某作品的 project 层覆盖集一次性快照（含 references）。
  ///
  /// 供 `ChatTurnRunner` 在开轮时读取当前值。刻意不走
  /// [projectAgentSkillOverridesProvider] 的 `container.read(...future)`：
  /// Riverpod 3 中 `StreamProvider.future` 经单次读会立即关闭订阅、冷流未发首值
  /// 即被取消而永久挂起；此方法直接读 DAO，每次调用都返回最新落库值。
  Future<List<NovelAgentSkillModel>> loadByNovelId(String novelId) async {
    final rows = await _db.novelAgentSkillOverrideDao.getByNovelId(novelId);
    return _mapRowsToModels(_db, rows);
  }

  Future<NovelAgentSkillModel> upsert(
    ProjectAgentSkillOverrideInput input,
  ) async {
    final now = DateTime.now();
    final id = input.existingId ?? buildRandomId('naso');
    final existing = input.existingId == null
        ? null
        : await _db.novelAgentSkillOverrideDao.getById(id);
    final sortOrder =
        existing?.sortOrder ??
        (await _db.novelAgentSkillOverrideDao.getByNovelId(
          input.novelId,
        )).length;
    final model = NovelAgentSkillModel(
      id: id,
      sourceKind: AgentSkillSourceKind.novelLocal,
      name: input.name.trim(),
      whenToUse: input.whenToUse,
      description: input.description,
      prompt: input.prompt,
      agentScopes: input.agentScopes,
      category: input.category,
      tags: input.tags,
      references: AgentSkillReferences.sanitize(input.references),
      enabled: input.enabled,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await _db.novelAgentSkillOverrideDao.upsertWithReferences(
      skill: NovelAgentSkillOverridesCompanion(
        id: Value(model.id),
        novelId: Value(input.novelId),
        sourceKind: Value(model.sourceKind.dbValue),
        name: Value(model.name),
        whenToUse: Value(model.whenToUse),
        description: Value(model.description),
        prompt: Value(model.prompt),
        agentScopes: Value(model.agentScopes),
        category: Value(model.category),
        tags: Value(model.tags),
        enabled: Value(model.enabled),
        sortOrder: Value(model.sortOrder),
        executionBlockedReason: Value(model.executionBlockedReason),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      references: model.references,
    );
    return model;
  }

  Future<void> delete(String id) {
    return _db.novelAgentSkillOverrideDao.hardDelete(id);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await (_db.update(
      _db.novelAgentSkillOverrides,
    )..where((t) => t.id.equals(id))).write(
      NovelAgentSkillOverridesCompanion(
        enabled: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}

final projectAgentSkillOverrideServiceProvider =
    Provider<ProjectAgentSkillOverrideService>((ref) {
      final db = ref.watch(agentSkillAppDatabaseProvider);
      return ProjectAgentSkillOverrideService(db);
    });

// ── 读流 ─────────────────────────────────────────────────────────────────────

/// 某作品的 project 层覆盖集（Drift watch 流，写后自动刷新）。
///
/// 供管理界面 `ref.watch` 做响应式读取；autoDispose 让面板关闭即释放。
/// 一次性快照读（如 `ChatTurnRunner`）请改用
/// [ProjectAgentSkillOverrideService.loadByNovelId]，不要在此 `.future` 上
/// `container.read`：Riverpod 3 的单次读会立即关闭订阅，冷流未发首值即取消。
final projectAgentSkillOverridesProvider = StreamProvider.autoDispose
    .family<List<NovelAgentSkillModel>, String>((ref, novelId) {
      final db = ref.watch(agentSkillAppDatabaseProvider);
      return db.novelAgentSkillOverrideDao
          .watchByNovelId(novelId)
          .asyncMap((rows) => _mapRowsToModels(db, rows));
    });
