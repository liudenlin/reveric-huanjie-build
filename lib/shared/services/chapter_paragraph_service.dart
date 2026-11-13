// 职责: R-10 段落稳定锚点服务 — 正文保存时同事务重算段落、惰性存量回填、标记定位。
// 关联文件:
//   lib/shared/services/novel_content.dart (正文写入单点：三方法挂钩)
//   lib/shared/database/novel_content_daos/chapter_paragraph_dao.dart
//   lib/shared/services/chapter_paragraph_rebind.dart (旧→新 remap)
//   lib/shared/utils/chapter_paragraph.dart (切段/hash/ID)
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/db-migration.md（v7→v8 存量回填）
//
// 正文 content 仍是唯一真源；段落表是"保存时重算一次"的派生索引。
// 本服务在 NovelContentService._writeChapterContent 的同一事务内调用
// [recomputeForChapter]，保证 content 与段落表不裂开。
// 存量库（v7→v8）首次读该章时 [backfillIfNeeded] 惰性建 ID，避免升级阻塞扫全书。

import 'package:drift/drift.dart' show Value;

import '../database/novel_content_database.dart';
import '../database/novel_content_daos/chapter_paragraph_dao.dart';
import '../logger/app_logger.dart';
import '../utils/chapter_paragraph.dart';
import 'chapter_paragraph_rebind.dart';

final _log = AppLogger.forModule('ChapterParagraph');

/// 一次重算结果，供调用方/测试断言与后续批注重绑。
class ChapterParagraphRecomputeResult {
  const ChapterParagraphRecomputeResult({
    required this.rebind,
    required this.activeCount,
    required this.backfilled,
  });

  final ParagraphRebind rebind;
  final int activeCount;

  /// 本次是否触发了存量回填（空段落表首次建 ID）。
  final bool backfilled;
}

/// 段落稳定锚点服务（有依赖、单例，由调用方 Provider 注入 db）。
class ChapterParagraphService {
  const ChapterParagraphService(this.db);

  final NovelContentDatabase db;

  ChapterParagraphDao get _dao => db.chapterParagraphDao;

  /// 存量回填：该章无 active 段落时，按切好的新段首次分配稳定 ID。
  ///
  /// [texts] 由调用方切好，避免重复 split；只在 [recomputeForChapter]
  /// 内部被调用，且必须已在事务中。若表中有 retired 历史段，本方法只新增
  /// active 段，不覆盖 retired（retired 不参与 active 快照，无需 remap）。
  Future<bool> _backfillIfEmpty(String chapterId, List<String> texts) async {
    final now = DateTime.now();
    final rows = <ChapterParagraphsCompanion>[];
    for (var i = 0; i < texts.length; i++) {
      rows.add(
        ChapterParagraphsCompanion(
          // id 与 paragraphId 同值：一段一行，天然幂等，省掉内部 uuid。
          id: Value(chapterParagraphId(chapterId, i)),
          paragraphId: Value(chapterParagraphId(chapterId, i)),
          chapterId: Value(chapterId),
          sortOrder: Value(i),
          textHash: Value(chapterParagraphTextHash(texts[i])),
          revisionId: const Value(''),
          status: Value(chapterParagraphStatusActive),
          createdAt: Value(now),
          updatedAt: Value(now),
          deletedAt: Value(notDeletedSentinel),
        ),
      );
    }
    await _dao.upsertAll(rows);
    if (rows.isNotEmpty) {
      _log.debug('backfill chapter=$chapterId paragraphs=${rows.length}');
    }
    return true;
  }

  /// 正文保存时重算该章段落（必须在 [db.transaction] 内调用）。
  ///
  /// [oldParagraphs] 由调用方在写 content **之前**读出（写后读不到旧文本哈希）。
  /// 若段落表为空则先存量回填，本次不再做 remap（首次建 ID 无旧段可比）。
  Future<ChapterParagraphRecomputeResult> recomputeForChapter({
    required String chapterId,
    required String newContent,
    required List<ParagraphSnapshot> oldParagraphs,
  }) async {
    final newTexts = splitChapterParagraphs(newContent);

    // 首次（空表）：直接建 ID，无需重绑定。
    final backfilled = oldParagraphs.isEmpty
        ? await _backfillIfEmpty(chapterId, newTexts)
        : false;
    if (backfilled) {
      return ChapterParagraphRecomputeResult(
        rebind: rebindChapterParagraphs(
          oldParagraphs: const [],
          newTexts: newTexts,
          chapterId: chapterId,
        ),
        activeCount: newTexts.length,
        backfilled: true,
      );
    }

    // 已有段落：三层重绑定。
    final rebind = rebindChapterParagraphs(
      oldParagraphs: oldParagraphs,
      newTexts: newTexts,
      chapterId: chapterId,
    );
    final now = DateTime.now();

    // 1. 新段落集：active，继承或新分配 ID，同 paragraphId 幂等 upsert。
    final rows = <ChapterParagraphsCompanion>[];
    for (final p in rebind.newParagraphs) {
      rows.add(
        ChapterParagraphsCompanion(
          id: Value(p.paragraphId),
          paragraphId: Value(p.paragraphId),
          chapterId: Value(chapterId),
          sortOrder: Value(p.order),
          textHash: Value(p.textHash),
          revisionId: Value(p.revisionId),
          status: Value(chapterParagraphStatusActive),
          mergedFrom: Value(p.mergedFrom.isEmpty ? null : p.mergedFrom),
          splitInto: Value(p.splitInto.isEmpty ? null : p.splitInto),
          // 非首次重算不覆盖既有段的创建时间：insertOnConflictUpdate
          // 对冲突行会更新所有显式列，传 now 会把旧段 createdAt 刷成当前时间。
          createdAt: const Value.absent(),
          updatedAt: Value(now),
          deletedAt: Value(notDeletedSentinel),
        ),
      );
    }
    await _dao.upsertAll(rows);

    // 2. 消失段：更新 status + remap 溯源（不物理删，保留历史）。
    for (final retired in rebind.retiredParagraphs) {
      await _dao.updateStatus(
        retired.paragraphId,
        retired.status,
        mergedFrom: retired.mergedFrom.isEmpty ? null : retired.mergedFrom,
        splitInto: retired.splitInto.isEmpty ? null : retired.splitInto,
      );
    }

    return ChapterParagraphRecomputeResult(
      rebind: rebind,
      activeCount: rebind.newParagraphs.length,
      backfilled: false,
    );
  }

  /// 读某章当前 active 段落的快照（重算前取旧段集用）。
  ///
  /// [content] 是该章**保存前**的正文全文。段落表只存 hash 不存全文，
  /// 但重绑定第 2 层相似度需要旧段文本；这里按序号把旧正文切出的段落
  /// 填回快照，保证「小改一段继承 ID」能真正比较首尾。
  Future<List<ParagraphSnapshot>> loadActiveSnapshots(
    String chapterId, {
    String? content,
  }) async {
    final rows = await _dao.listActiveByChapter(chapterId);
    final texts = content == null
        ? const <String>[]
        : splitChapterParagraphs(content);
    return [
      for (var i = 0; i < rows.length; i++)
        ParagraphSnapshot(
          paragraphId: rows[i].paragraphId,
          order: rows[i].sortOrder,
          textHash: rows[i].textHash,
          text: i < texts.length ? texts[i] : '',
          status: rows[i].status,
          revisionId: rows[i].revisionId,
          mergedFrom: rows[i].mergedFrom ?? const [],
          splitInto: rows[i].splitInto ?? const [],
        ),
    ];
  }
}
