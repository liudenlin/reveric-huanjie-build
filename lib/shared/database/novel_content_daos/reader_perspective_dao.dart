// 职责: M6c 读者认知数据访问对象 — 叙事时间与人物认知分离的记录读写。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (ReaderPerspectives 表)
//   lib/shared/services/perspectives/reader_perspective_service.dart (认知查询)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v4→v5 createTable，保旧数据）
//
// §3.3：同一事件在 storyTime / readingOrder / knowledgeTime / disclosureTime
// 上可能不同；本表按事实 + 主体（reader 或 character:<id>）记录认知状态。

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'reader_perspective_dao.drift.dart';

/// 读者认知 DAO。
@DriftAccessor(tables: [ReaderPerspectives])
class ReaderPerspectiveDao extends DatabaseAccessor<NovelContentDatabase>
    with _$ReaderPerspectiveDaoMixin {
  ReaderPerspectiveDao(super.db);

  /// 某事实的全部认知记录（读者视角 + 各角色视角）。
  Future<List<ReaderPerspectiveRow>> listByFact(String factId) {
    return (select(readerPerspectives)
          ..where(
            (t) => t.factId.equals(factId) & t.deletedAt.equals(notDeletedSentinel),
          ))
        .get();
  }

  /// 某主体的全部已知/未知事实（上下文组装「某角色此刻知道什么」）。
  Future<List<ReaderPerspectiveRow>> listBySubject(String subject) {
    return (select(readerPerspectives)
          ..where(
            (t) =>
                t.subject.equals(subject) &
                t.deletedAt.equals(notDeletedSentinel),
          ))
        .get();
  }

  Future<ReaderPerspectiveRow?> getById(String id) {
    return (select(readerPerspectives)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 幂等写入（同 factId+subject 覆盖，保 uniqueKeys）。
  Future<void> upsert(ReaderPerspectivesCompanion entry) {
    return into(readerPerspectives).insertOnConflictUpdate(entry);
  }

  /// 更新认知状态（unknown/aware/misled/revealed）。
  Future<void> updateState(String id, String state) {
    return (update(readerPerspectives)..where((t) => t.id.equals(id))).write(
      ReaderPerspectivesCompanion(
        state: Value(state),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 软删除。
  Future<void> softDelete(String id) {
    return (update(readerPerspectives)..where((t) => t.id.equals(id))).write(
      ReaderPerspectivesCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}