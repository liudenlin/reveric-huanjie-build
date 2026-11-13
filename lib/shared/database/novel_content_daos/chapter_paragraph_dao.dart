// 职责: R-10 ChapterParagraphDao — 段落稳定锚点表的读写（按章重算/反查/软删）。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (ChapterParagraphs 表)
//   lib/shared/services/chapter_paragraph_service.dart (重算编排)
//   lib/shared/services/chapter_paragraph_rebind.dart (旧→新 remap)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v7→v8 createTable）
//   .agents/rules/db-query-aggregation.md
//
// 段落表是正文的派生索引：正文 content 仍是唯一真源，本 DAO 只承担
// "保存时重算该章段落 + 标记侧按 paragraphId 反查"的索引职责。

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';
import '../../utils/chapter_paragraph.dart';

part 'chapter_paragraph_dao.drift.dart';

/// 段落稳定锚点 DAO。
@DriftAccessor(tables: [ChapterParagraphs])
class ChapterParagraphDao extends DatabaseAccessor<NovelContentDatabase>
    with _$ChapterParagraphDaoMixin {
  ChapterParagraphDao(super.db);

  /// 取某章当前有效段落（active），按章内序号升序。
  /// 仅 [chapterParagraphStatusActive] 参与下一轮重绑定的"旧段集"与标记定位。
  Future<List<ChapterParagraphRow>> listActiveByChapter(String chapterId) {
    return (select(chapterParagraphs)
          ..where(
            (t) =>
                t.chapterId.equals(chapterId) &
                t.status.equals(chapterParagraphStatusActive) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.sortOrder, mode: OrderingMode.asc),
          ]))
        .get();
  }

  /// 取某章全部历史段落（含 orphaned/merged/split 溯源），按序号升序。
  Future<List<ChapterParagraphRow>> listAllByChapter(String chapterId) {
    return (select(chapterParagraphs)
          ..where(
            (t) =>
                t.chapterId.equals(chapterId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.sortOrder, mode: OrderingMode.asc),
          ]))
        .get();
  }

  /// 按稳定 ID 反查段落（标记/批注定位用）。
  Future<ChapterParagraphRow?> getByParagraphId(String paragraphId) {
    return (select(
      chapterParagraphs,
    )..where((t) => t.paragraphId.equals(paragraphId))).getSingleOrNull();
  }

  /// 该章是否已有段落索引（惰性回填判定：空 = 需首次建 ID）。
  Future<bool> hasAnyForChapter(String chapterId) async {
    final row =
        await (selectOnly(chapterParagraphs)
              ..addColumns([chapterParagraphs.id.count()])
              ..where(
                chapterParagraphs.chapterId.equals(chapterId) &
                    chapterParagraphs.deletedAt.equals(notDeletedSentinel),
              ))
            .getSingle();
    return (row.read(chapterParagraphs.id.count()) ?? 0) > 0;
  }

  /// 幂等 upsert（同 paragraphId 覆盖，重算时复用稳定 ID）。
  Future<void> upsert(ChapterParagraphsCompanion entry) {
    return into(chapterParagraphs).insertOnConflictUpdate(entry);
  }

  /// 批量 upsert：正文重算后一次性写回该章段落集。
  Future<void> upsertAll(Iterable<ChapterParagraphsCompanion> entries) async {
    for (final entry in entries) {
      await upsert(entry);
    }
  }

  /// 批量更新状态与 remap：段落消失/合并/拆分时保留溯源，不物理删。
  Future<void> updateStatus(
    String paragraphId,
    String status, {
    List<String>? mergedFrom,
    List<String>? splitInto,
  }) {
    return (update(
      chapterParagraphs,
    )..where((t) => t.paragraphId.equals(paragraphId))).write(
      ChapterParagraphsCompanion(
        status: Value(status),
        mergedFrom: Value(mergedFrom),
        splitInto: Value(splitInto),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
