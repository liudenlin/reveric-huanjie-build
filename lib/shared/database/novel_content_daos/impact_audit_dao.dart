// 职责: M4 影响审计数据访问对象 — 审计记录的基础读写。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (ImpactAudits 表)
//   lib/shared/services/impact_audit_service.dart (审计逻辑)
//   lib/shared/services/impact_audit_models.dart (审计模型)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v3→v4 createTable，保旧数据）

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'impact_audit_dao.drift.dart';

/// 影响审计 DAO — 审计记录读写；服务层封装审计判定逻辑。
@DriftAccessor(tables: [ImpactAudits])
class ImpactAuditDao extends DatabaseAccessor<NovelContentDatabase>
    with _$ImpactAuditDaoMixin {
  ImpactAuditDao(super.db);

  Stream<List<ImpactAudit>> watchAll() {
    return (select(impactAudits)..orderBy([
          (t) => OrderingTerm(
            expression: t.createdAt,
            mode: OrderingMode.desc,
          ),
        ]))
        .watch();
  }

  Future<List<ImpactAudit>> listAll({int? limit}) {
    final query = select(impactAudits)
      ..orderBy([
        (t) => OrderingTerm(
          expression: t.createdAt,
          mode: OrderingMode.desc,
        ),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.get();
  }

  /// 按变更对象（resourcePath）列出审计记录（新→旧）。
  Future<List<ImpactAudit>> listByResource(String resourcePath, {int? limit}) {
    final query = select(impactAudits)
      ..where((t) => t.resourcePath.equals(resourcePath))
      ..orderBy([
        (t) => OrderingTerm(
          expression: t.createdAt,
          mode: OrderingMode.desc,
        ),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.get();
  }

  Future<ImpactAudit?> getByChangeId(String changeId) {
    return (select(impactAudits)..where((t) => t.changeId.equals(changeId)))
        .getSingleOrNull();
  }

  Future<ImpactAudit?> getById(String id) {
    return (select(impactAudits)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 某资源当前是否仍有「待复核」审计（下游命中未确认）。
  Future<bool> hasPendingReview(String resourcePath) {
    // 与落库路径一致：stageTextChange/commit 均用 canonicalResourcePath。
    final canonical = _canonicalForQuery(resourcePath);
    final query = selectOnly(impactAudits)
      ..addColumns([impactAudits.id])
      ..where(
        impactAudits.resourcePath.equals(canonical) &
            impactAudits.status.equals(impactAuditStatusRecorded),
      )
      ..limit(1);
    return query.get().then((rows) => rows.isNotEmpty);
  }

  String _canonicalForQuery(String path) {
    final local = path.trim().replaceFirst(RegExp(r'^/+'), '');
    if (local.isEmpty) return '/';
    final root = local.split(RegExp(r'[/?]')).first;
    if (root == 'works' || root == '_schema') return '/$local';
    return local;
  }

  Future<List<ImpactAudit>> listPending({int? limit}) {
    final query = select(impactAudits)
      ..where((t) => t.status.equals(impactAuditStatusRecorded))
      ..orderBy([
        (t) => OrderingTerm(
          expression: t.createdAt,
          mode: OrderingMode.desc,
        ),
      ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.get();
  }

  Future<void> upsert(ImpactAuditsCompanion entry) {
    return into(impactAudits).insertOnConflictUpdate(entry);
  }

  /// 标记某审计为已复核（人工确认下游无碍）。
  Future<void> markReviewed(String id) {
    return (update(impactAudits)..where((t) => t.id.equals(id))).write(
      ImpactAuditsCompanion(
        status: const Value(impactAuditStatusReviewed),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}