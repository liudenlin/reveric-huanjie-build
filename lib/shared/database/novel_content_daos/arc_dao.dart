// 职责: M6b 叙事弧线数据访问对象 — 6 类弧线的读写。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (Arcs 表 / arc 常量)
//   lib/shared/services/arcs/arc_service.dart (弧线服务)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v4→v5 createTable，保旧数据）
//
// 弧线是剧情推进骨架：主线/支线/角色弧/关系弧/主题弧/伏笔弧。
// 本 DAO 提供按作品/类型查询、CRUD 与软删除；状态迁移与上下文
// 组装在服务层。

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'arc_dao.drift.dart';

/// 叙事弧线 DAO。
@DriftAccessor(tables: [Arcs])
class ArcDao extends DatabaseAccessor<NovelContentDatabase>
    with _$ArcDaoMixin {
  ArcDao(super.db);

  /// 某作品全部未删除弧线（sortOrder 升序）。
  Future<List<ArcRow>> listByProject(String projectId) {
    return (select(arcs)
          ..where((t) => t.projectId.equals(projectId) & t.deletedAt.equals(notDeletedSentinel))
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
  }

  /// 某作品指定类型弧线。
  Future<List<ArcRow>> listByType(String projectId, String type) {
    return (select(arcs)
          ..where(
            (t) =>
                t.projectId.equals(projectId) &
                t.type.equals(type) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
  }

  Future<ArcRow?> getById(String id) {
    return (select(arcs)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 关联到某对象的弧线（角色弧/关系弧/伏笔弧按 relatedObjectId 反查）。
  Future<List<ArcRow>> listByRelatedObject(String relatedObjectId) {
    return (select(arcs)
          ..where(
            (t) =>
                t.relatedObjectId.equals(relatedObjectId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
  }

  Future<void> upsert(ArcsCompanion entry) {
    return into(arcs).insertOnConflictUpdate(entry);
  }

  /// 更新弧线状态（draft/active/completed/abandoned）。
  Future<void> updateStatus(String id, String status) {
    return (update(arcs)..where((t) => t.id.equals(id))).write(
      ArcsCompanion(
        status: Value(status),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 软删除（deletedAt = now），保留历史用于回溯。
  Future<void> softDelete(String id) {
    return (update(arcs)..where((t) => t.id.equals(id))).write(
      ArcsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}