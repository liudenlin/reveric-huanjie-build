// 职责: M6a 语义检索数据访问对象 — 已批准正文/设定/研究资料的分块索引读写。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (AiEmbeddingDocuments 表)
//   lib/shared/services/embedding/embedding_search_service.dart (向量化 + 混合检索)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（现有表无需 schema 变更）
//   .agents/rules/db-index-naming.md
//
// 能力（对齐专项设计 §8）：
// - 分块写入/更新（幂等：同 sourceType+sourceId+chunkIndex 覆盖，
//   内容未变化返回 false 跳过向量重算，§8.4「内容未变化不重复算向量」）
// - 按源对象失效（invalidateSource：对象删除时索引项删除，§8.4）
// - stale 标记（模型版本变更后标陈旧、后台重算，§8.4）
// - 全删重建路径（clearAll：「索引清空—重新构建—一致性测试」）

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'embedding_document_dao.drift.dart';

/// 语义检索索引 DAO — 纯数据访问；向量化与检索打分在服务层。
@DriftAccessor(tables: [AiEmbeddingDocuments])
class EmbeddingDocumentDao extends DatabaseAccessor<NovelContentDatabase>
    with _$EmbeddingDocumentDaoMixin {
  EmbeddingDocumentDao(super.db);

  /// 按 sourceId（对象稳定 ID）列出全部块（chunkIndex 升序）。
  Future<List<AiEmbeddingDocument>> listBySource({
    required String sourceType,
    required String sourceId,
  }) {
    return (select(aiEmbeddingDocuments)
          ..where(
            (t) =>
                t.sourceType.equals(sourceType) & t.sourceId.equals(sourceId),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.chunkIndex)]))
        .get();
  }

  /// 检索召回：全部块（可按 sourceType 过滤），供服务层做内存混合打分。
  /// 上限由调用方控制（limit 默认 4096），避免 SQLite LIKE 全表发散。
  Future<List<AiEmbeddingDocument>> listAllForSearch({
    List<String>? sourceTypes,
    int limit = 4096,
  }) {
    final query = select(aiEmbeddingDocuments);
    if (sourceTypes != null && sourceTypes.isNotEmpty) {
      query.where((t) => t.sourceType.isIn(sourceTypes));
    }
    query.limit(limit);
    return query.get();
  }

  /// 幂等写入单个块：以 sourceType+sourceId+chunkIndex 为逻辑键。
  /// 返回 true 表示「内容有变化或新建」，调用方应（重新）计算向量；
  /// 返回 false 表示内容未变化，跳过向量重算。
  Future<bool> upsertChunk(AiEmbeddingDocumentsCompanion entry) async {
    final sourceType = entry.sourceType.value;
    final sourceId = entry.sourceId.value;
    final chunkIndex = entry.chunkIndex.value;
    if (sourceType == null || sourceId == null || chunkIndex == null) {
      throw ArgumentError('upsertChunk 必须提供 sourceType/sourceId/chunkIndex');
    }

    final existing = await (select(aiEmbeddingDocuments)
          ..where(
            (t) =>
                t.sourceType.equals(sourceType) &
                t.sourceId.equals(sourceId) &
                t.chunkIndex.equals(chunkIndex),
          )
          ..limit(1))
        .getSingleOrNull();

    if (existing == null) {
      await into(aiEmbeddingDocuments).insert(entry);
      return true;
    }
    if (existing.content == entry.content.value) {
      // 内容文本未变化：不重算向量。
      return false;
    }
    // 内容有变化：更新原行，保持 id 稳定（外部锚点不失效）。
    final patch = entry.copyWith(
      id: Value(existing.id),
      sourceType: Value(existing.sourceType),
      sourceId: Value(existing.sourceId),
      chunkIndex: Value(existing.chunkIndex),
      createdAt: Value(existing.createdAt),
    );
    await (update(aiEmbeddingDocuments)..where((t) => t.id.equals(existing.id)))
        .write(patch);
    return true;
  }

  /// 删除某源对象的全部索引块（对象删除时的级联清理，§8.4）。
  Future<void> invalidateSource({
    required String sourceType,
    required String sourceId,
  }) {
    return (delete(aiEmbeddingDocuments)
          ..where(
            (t) =>
                t.sourceType.equals(sourceType) & t.sourceId.equals(sourceId),
          ))
        .go();
  }

  /// 全部索引块数（统计用）。
  Future<int> countAll() async {
    final query = selectOnly(aiEmbeddingDocuments)
      ..addColumns([aiEmbeddingDocuments.id.count()]);
    final row = await query.getSingle();
    return row.read(aiEmbeddingDocuments.id.count()) ?? 0;
  }

  /// 标记某对象的索引为 stale（模型/对象版本变更后待后台重算）。
  /// 保留既有 metadata 字段，仅追加 stale 标记。
  Future<void> markStale({
    required String sourceType,
    required String sourceId,
    String staleReason = 'model_or_version_changed',
  }) async {
    final existing = await (select(aiEmbeddingDocuments)
          ..where(
            (t) =>
                t.sourceType.equals(sourceType) & t.sourceId.equals(sourceId),
          )
          ..limit(1))
        .getSingleOrNull();
    final merged = <String, dynamic>{
      if (existing?.metadata != null) ...existing!.metadata!,
      'stale': true,
      'staleReason': staleReason,
      'markedAt': DateTime.now().toIso8601String(),
    };
    await (update(aiEmbeddingDocuments)
          ..where(
            (t) =>
                t.sourceType.equals(sourceType) & t.sourceId.equals(sourceId),
          ))
        .write(
          AiEmbeddingDocumentsCompanion(
            metadata: Value(merged),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  /// 清除整表（「索引清空—重建—一致性测试」路径，§8.4）。
  Future<void> clearAll() => delete(aiEmbeddingDocuments).go();
}