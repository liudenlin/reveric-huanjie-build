// 职责: R-10 S1 集成测试 — 正文保存三方法挂钩后段落表同事务重算，ID 稳定、ORPHANED 溯源。
// 关联文件:
//   lib/shared/services/novel_content.dart (updateChapterContent / updateFormattedChapterContent 挂钩)
//   lib/shared/services/chapter_paragraph_service.dart
//   lib/shared/database/novel_content_daos/chapter_paragraph_dao.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（方案 §6 S1）：新建/保存/批量排版后，该章 active 段落数 == 正文非空行数、
//   ID 稳定；小改正文不漂 ID；删段保留 ORPHANED 溯源；批量排版路径也同步。

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/utils/chapter_paragraph.dart';

void main() {
  late NovelContentDatabase database;
  late NovelContentService service;

  setUp(() async {
    database = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = NovelContentService(database);
    await database.chapterDao.insert(
      ChaptersCompanion.insert(
        id: 'ch_1',
        type: nodeTypeChapter,
        siblingOrder: 1,
        title: const Value('标题'),
        content: const Value('初始正文'),
      ),
    );
  });

  tearDown(() => database.close());

  Future<List<String>> activeIds() async =>
      (await database.chapterParagraphDao.listActiveByChapter(
        'ch_1',
      )).map((p) => p.paragraphId).toList();

  test('首次 updateChapterContent：按非空行建稳定 ID', () async {
    const content = '甲段。\n\n乙段。\n丙段。';
    await service.updateChapterContent(
      chapterId: 'ch_1',
      title: '标题',
      outline: '',
      content: content,
    );
    final ids = await activeIds();
    expect(ids, ['p-ch_1-0000', 'p-ch_1-0001', 'p-ch_1-0002']);
    final active = await database.chapterParagraphDao.listActiveByChapter(
      'ch_1',
    );
    expect(active.map((p) => p.textHash).toSet(), hasLength(3));
  });

  test('小改某段：其余段 ID 不变，改动段继承旧 ID、hash 更新', () async {
    await service.updateChapterContent(
      chapterId: 'ch_1',
      title: '标题',
      outline: '',
      content: '第一段甲乙丙丁。\n第二段独立内容。',
    );
    final before = await database.chapterParagraphDao.listActiveByChapter(
      'ch_1',
    );
    expect(before, hasLength(2));

    // 第一段中间改一字（前后不变，相似度 ≥ 0.8）；第二段原样。
    await service.updateChapterContent(
      chapterId: 'ch_1',
      title: '标题',
      outline: '',
      content: '第一段甲乙X丁。\n第二段独立内容。',
    );
    final after = await database.chapterParagraphDao.listActiveByChapter(
      'ch_1',
    );
    expect(after, hasLength(2));
    expect(after.map((p) => p.paragraphId), before.map((p) => p.paragraphId));
    expect(
      after[0].textHash,
      isNot(before[0].textHash),
      reason: '改动段 hash 必须更新',
    );
    expect(after[1].textHash, before[1].textHash);
  });

  test('删除一段：旧段保留 ORPHANED 溯源，active 只含现存段', () async {
    await service.updateChapterContent(
      chapterId: 'ch_1',
      title: '标题',
      outline: '',
      content: '甲段。\n乙段将被删。\n丙段。',
    );
    final before = await database.chapterParagraphDao.listActiveByChapter(
      'ch_1',
    );

    await service.updateChapterContent(
      chapterId: 'ch_1',
      title: '标题',
      outline: '',
      content: '甲段。\n丙段。',
    );
    final active = await database.chapterParagraphDao.listActiveByChapter(
      'ch_1',
    );
    expect(active, hasLength(2), reason: 'active 只含现存段');
    expect(active.map((p) => p.paragraphId), [
      before[0].paragraphId,
      before[2].paragraphId,
    ]);

    final all = await database.chapterParagraphDao.listAllByChapter('ch_1');
    final orphan = all.singleWhere(
      (p) => p.paragraphId == before[1].paragraphId,
    );
    expect(orphan.status, chapterParagraphStatusOrphaned);
  });

  test('updateFormattedChapterContent（批量排版）：段落表同事务同步', () async {
    // 批量排版会重排标点；这里用足够长的段落保证改动后相似度 ≥ 0.80，
    // 与 S2 的 θ 边界一致（3 字短段只改末字符会跌破阈值，属于方案已知风险）。
    const oldContent = '旧甲甲乙丙。\n旧乙丁戊己。';
    await service.updateChapterContent(
      chapterId: 'ch_1',
      title: '标题',
      outline: '',
      content: oldContent,
    );
    final before = await activeIds();
    expect(before, hasLength(2));

    // 批量排版：段数不变、末标点变化但相似度仍达 θ。
    await service.updateFormattedChapterContent(
      chapterId: 'ch_1',
      content: '旧甲甲乙丙！\n旧乙丁戊己！',
    );
    final after = await database.chapterParagraphDao.listActiveByChapter(
      'ch_1',
    );
    expect(after, hasLength(2));
    expect(after.map((p) => p.paragraphId), before, reason: '排版不漂 ID');
    final body = await database.chapterDao.getBodyById('ch_1');
    expect(body, '旧甲甲乙丙！\n旧乙丁戊己！');
  });

  test('content 与段落表同事务：写 content 抛错时段落不变', () async {
    await service.updateChapterContent(
      chapterId: 'ch_1',
      title: '标题',
      outline: '',
      content: '甲。\n乙。',
    );
    final before = await activeIds();

    // 目标章节不存在 → update 0 行路径由 updateFormatted 抛 StateError，
    // 事务回滚，段落表不应出现该章的新段落。
    await expectLater(
      service.updateFormattedChapterContent(
        chapterId: 'nonexistent',
        content: '孤立段。',
      ),
      throwsStateError,
    );
    expect(await activeIds(), before);
    expect(
      await database.chapterParagraphDao.hasAnyForChapter('nonexistent'),
      isFalse,
    );
  });
}
