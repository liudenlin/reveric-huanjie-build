// 职责: M7 ResearchTaskDao — 研究任务（发起→审批→执行→回填）数据访问。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (ResearchTasks 表)
//   lib/shared/services/research_task_service.dart (研究任务编排服务)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v6→v7 createTable，保旧数据）
//
// §M7 研究任务：一条记录 = 一个独立窗口执行的研究任务；
// 状态机 pending_approval→approved→running→completed/failed/cancelled/budget_exceeded。

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'research_task_dao.drift.dart';

/// 研究任务 DAO。
@DriftAccessor(tables: [ResearchTasks])
class ResearchTaskDao extends DatabaseAccessor<NovelContentDatabase>
    with _$ResearchTaskDaoMixin {
  ResearchTaskDao(super.db);

  /// 按项目列出全部任务（新→旧）。
  Future<List<ResearchTaskRow>> listByProject(String projectId) {
    return (select(researchTasks)
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

  /// 按状态列出（如 pending_approval 待审批 / running 执行中）。
  Future<List<ResearchTaskRow>> listByStatus(String status) {
    return (select(researchTasks)
          ..where(
            (t) =>
                t.status.equals(status) & t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  /// 流式观察全部未删除任务（全局视图）。
  Stream<List<ResearchTaskRow>> watchAll() {
    return (select(researchTasks)
          ..where((t) => t.deletedAt.equals(notDeletedSentinel))
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  Future<ResearchTaskRow?> getById(String id) {
    return (select(researchTasks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 幂等写入（同 id 覆盖）。
  Future<void> upsert(ResearchTasksCompanion entry) {
    return into(researchTasks).insertOnConflictUpdate(entry);
  }

  /// 更新状态并刷新 updatedAt（可选写错误码/结论/完成时间）。
  Future<void> updateStatus(
    String id,
    String status, {
    String errorCode = '',
    String resultText = '',
    DateTime? completedAt,
    DateTime? approvedAt,
  }) {
    return (update(researchTasks)..where((t) => t.id.equals(id))).write(
      ResearchTasksCompanion(
        status: Value(status),
        errorCode: Value(errorCode),
        resultText: Value(resultText),
        completedAt: completedAt == null ? const Value.absent() : Value(completedAt),
        approvedAt: approvedAt == null ? const Value.absent() : Value(approvedAt),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 只更新 metadataJson（R-37 来源记录）并刷新 updatedAt。
  /// update 而非 upsert：insert 校验会要求 title/prompt 必填。
  Future<void> updateMetadata(String id, String metadataJson) {
    return (update(researchTasks)..where((t) => t.id.equals(id))).write(
      ResearchTasksCompanion(
        metadataJson: Value(metadataJson),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 累计已消耗 token/费用（预算熔断数据源）。
  /// 返回更新后的最新累计值，供调用方判断是否超限。
  Future<ResearchTaskRow?> addSpent(
    String id,
    int deltaTokens,
    int deltaCostMicros,
  ) async {
    await customUpdate(
      'UPDATE research_tasks SET spent_tokens = spent_tokens + ?1, '
      'spent_cost_micros = spent_cost_micros + ?2, '
      'updated_at = ?3 WHERE id = ?4',
      variables: [
        Variable.withInt(deltaTokens),
        Variable.withInt(deltaCostMicros),
        Variable.withDateTime(DateTime.now()),
        Variable.withString(id),
      ],
      updates: {researchTasks},
    );
    return getById(id);
  }

  /// 软删除。
  Future<void> softDelete(String id) {
    return (update(researchTasks)..where((t) => t.id.equals(id))).write(
      ResearchTasksCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
