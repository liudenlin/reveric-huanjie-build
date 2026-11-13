// 职责: M2 内容级锁定 + 四态正典数据访问对象。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (ContentLocks/CanonEntries 表)
//   lib/shared/services/content_lock_service.dart (锁定判定服务)
//   lib/shared/services/canon_service.dart (正典操作服务)

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'content_lock_dao.drift.dart';

/// 内容级锁定 DAO — 锁定表的基础读写（服务层封装判定逻辑）。
@DriftAccessor(tables: [ContentLocks])
class ContentLockDao extends DatabaseAccessor<NovelContentDatabase>
    with _$ContentLockDaoMixin {
  ContentLockDao(super.db);

  Stream<List<ContentLock>> watchActive() {
    return (select(contentLocks)
          ..where((t) => t.active.equals(true))
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  Future<List<ContentLock>> listActive() {
    return (select(contentLocks)
          ..where((t) => t.active.equals(true))
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  Future<ContentLock?> findById(String id) {
    return (select(contentLocks)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 解锁（软删除；AI 不可调用，仅作者显式操作）。
  Future<void> deactivate(String id) {
    return (update(contentLocks)..where((t) => t.id.equals(id))).write(
      ContentLocksCompanion(
        active: const Value(false),
        updatedAt: Value(DateTime.now()),
        deletedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 新增锁定（仅用户/系统可调用）。
  Future<void> insertLock(ContentLocksCompanion entry) {
    return into(contentLocks).insert(entry);
  }
}

/// 四态正典 DAO — 正式事实 / 讨论 / 提案 / 废弃 管理。
@DriftAccessor(tables: [CanonEntries])
class CanonEntryDao extends DatabaseAccessor<NovelContentDatabase>
    with _$CanonEntryDaoMixin {
  CanonEntryDao(super.db);

  Stream<List<CanonEntry>> watchAll() {
    return (select(canonEntries)..orderBy([
          (t) => OrderingTerm(
            expression: t.updatedAt,
            mode: OrderingMode.desc,
          ),
        ]))
        .watch();
  }

  Future<List<CanonEntry>> listAll() {
    return (select(canonEntries)
          ..where((t) => t.deletedAt.equals(notDeletedSentinel))
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.updatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  Future<List<CanonEntry>> listByResource(String resourceType, String resourceId) {
    return (select(canonEntries)
          ..where(
            (t) =>
                t.resourceType.equals(resourceType) &
                t.resourceId.equals(resourceId) &
                t.deletedAt.equals(notDeletedSentinel),
          ))
        .get();
  }

  /// 当前资源生效的正典条目（按最新）。
  Future<CanonEntry?> currentFor(String resourceType, String resourceId) {
    return (select(canonEntries)
          ..where(
            (t) =>
                t.resourceType.equals(resourceType) &
                t.resourceId.equals(resourceId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<CanonEntry?> findById(String id) {
    return (select(canonEntries)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 按正典层级过滤。
  Future<List<CanonEntry>> listByLevel(String level) {
    return (select(canonEntries)
          ..where(
            (t) =>
                t.level.equals(level) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc)]))
        .get();
  }

  /// 写入正典条目；同一资源已有更高层级的 canon 时调用方需先裁决。
  Future<void> upsert(CanonEntriesCompanion entry) {
    return into(canonEntries).insertOnConflictUpdate(entry);
  }

  /// 废弃（软删除）。
  Future<void> deprecate(String id, {String? decisionNote}) {
    return (update(canonEntries)..where((t) => t.id.equals(id))).write(
      CanonEntriesCompanion(
        level: const Value(canonLevelDeprecated),
        decisionNote: Value(decisionNote ?? ''),
        updatedAt: Value(DateTime.now()),
        deletedAt: Value(DateTime.now()),
      ),
    );
  }
}