// 职责: M6e FactProposalDao — 记忆变更提案（待裁决候选）数据访问。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (FactProposals 表)
//   lib/shared/services/memory_proposal_service.dart (裁决服务)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v5→v6 createTable，保旧数据）
//
// §4.1 FactProposal：AI 产出的记忆/设定变更先落为「待裁决候选」，
// 不直接写入正式正典；审查状态机 pending→approved/rejected/deferred/modified。

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'fact_proposal_dao.drift.dart';

/// 记忆变更提案 DAO。
@DriftAccessor(tables: [FactProposals])
class FactProposalDao extends DatabaseAccessor<NovelContentDatabase>
    with _$FactProposalDaoMixin {
  FactProposalDao(super.db);

  /// 按项目列出全部提案（新→旧）。
  Future<List<FactProposalRow>> listByProject(String projectId) {
    return (select(factProposals)
          ..where(
            (t) =>
                t.projectId.equals(projectId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  /// 按审查状态列出（如 pending 待裁决）。
  Future<List<FactProposalRow>> listByStatus(String reviewStatus) {
    return (select(factProposals)
          ..where(
            (t) =>
                t.reviewStatus.equals(reviewStatus) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  /// 按目标对象反查（同对象多次提案）。
  Future<List<FactProposalRow>> listByTarget(
    String targetType,
    String targetId,
  ) {
    return (select(factProposals)
          ..where(
            (t) =>
                t.targetType.equals(targetType) &
                t.targetId.equals(targetId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  Future<FactProposalRow?> getById(String id) {
    return (select(factProposals)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 幂等写入（同 id 覆盖）。
  Future<void> upsert(FactProposalsCompanion entry) {
    return into(factProposals).insertOnConflictUpdate(entry);
  }

  /// 更新审查状态并写裁决说明（保留 createdAt，刷新 updatedAt）。
  Future<void> updateStatus(
    String id,
    String reviewStatus, {
    String resolutionNote = '',
  }) {
    return (update(factProposals)..where((t) => t.id.equals(id))).write(
      FactProposalsCompanion(
        reviewStatus: Value(reviewStatus),
        resolutionNote: Value(resolutionNote),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 软删除。
  Future<void> softDelete(String id) {
    return (update(factProposals)..where((t) => t.id.equals(id))).write(
      FactProposalsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
