// 职责: M6e DecisionLogDao — 作者最终裁决账本（Append-only）数据访问。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (DecisionLogs 表)
//   lib/shared/services/memory_proposal_service.dart (裁决服务)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v5→v6 createTable，保旧数据）
//
// §4.1 DecisionLog：作者最终裁决的 Append-only 账本；一条提案的每次
// 裁决动作追加一条记录，不可静默覆盖。本表不做软删除/更新。

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'decision_log_dao.drift.dart';

/// 作者最终裁决账本 DAO。
@DriftAccessor(tables: [DecisionLogs])
class DecisionLogDao extends DatabaseAccessor<NovelContentDatabase>
    with _$DecisionLogDaoMixin {
  DecisionLogDao(super.db);

  /// 按提案列出全部裁决历史（新→旧）。
  Future<List<DecisionLogRow>> listByProposal(String proposalId) {
    return (select(decisionLogs)
          ..where((t) => t.proposalId.equals(proposalId))
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  /// 全部裁决记录（新→旧，审计用）。
  Future<List<DecisionLogRow>> listAll({int? limit}) {
    final query = select(decisionLogs)
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

  /// 追加一条裁决记录（Append-only，无软删除路径）。
  Future<void> append(DecisionLogsCompanion entry) {
    return into(decisionLogs).insert(entry);
  }
}
