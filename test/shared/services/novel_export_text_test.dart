// 职责: 验证整书 TXT 与 Markdown 成书导出的标题层级、作者与正文保留。
// 关联文件:
//   lib/shared/services/novel_export.dart
//   lib/shared/models/chapter.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/chapter.dart';
import 'package:reveric/shared/services/novel_export.dart';

void main() {
  test('buildTxt 生成整书纯文本并保留分卷、章节与正文', () {
    final txt = NovelExportService.buildTxt(
      title: '《示例作品》',
      author: '示例作者',
      chapters: [
        _chapter(id: 'volume_1', type: nodeTypeVolume, title: '第一卷'),
        _chapter(id: 'chapter_1', title: '风起', content: '第一章正文。\n第二段内容。'),
        _chapter(
          id: 'chapter_2',
          title: null,
          content: '第二章正文。',
          chapterNum: 2,
        ),
      ],
    );

    expect(txt, contains('《示例作品》'));
    expect(txt, contains('作者：示例作者'));
    expect(txt, contains('第一卷'));
    expect(txt, contains('第一章 风起'));
    expect(txt, contains('第一章正文。'));
    expect(txt, contains('第二段内容。'));
    expect(txt, contains('第二章'));
    expect(txt, endsWith('\n'));
  });

  test('buildMarkdown 生成 Markdown 层级并回退未命名标题', () {
    final md = NovelExportService.buildMarkdown(
      title: '《示例作品》',
      author: '示例作者',
      chapters: [
        _chapter(id: 'volume_1', type: nodeTypeVolume, title: '第一卷'),
        _chapter(id: 'chapter_1', title: '风起', content: '第一章正文。\n第二段内容。'),
        _chapter(
          id: 'chapter_2',
          title: null,
          content: '第二章正文。',
          chapterNum: 2,
        ),
      ],
    );

    expect(md, startsWith('# 《示例作品》'));
    expect(md, contains('> 作者：示例作者'));
    expect(md, contains('## 第一卷'));
    expect(md, contains('### 第一章 风起'));
    expect(md, contains('\n第一章正文。\n'));
    expect(md, contains('\n第二段内容。\n'));
    expect(md, contains('### 第二章'));
    expect(md, endsWith('\n'));
  });

  test('buildMarkdown 空标题回退为未命名作品', () {
    final md = NovelExportService.buildMarkdown(
      title: '',
      chapters: [_chapter(id: 'chapter_1', title: '风起', content: '正文。')],
    );
    expect(md, startsWith('# 未命名作品'));
  });
}

Chapter _chapter({
  required String id,
  String type = nodeTypeChapter,
  String? title,
  String content = '',
  int siblingOrder = 0,
  int chapterNum = 1,
}) {
  return Chapter(
    id: id,
    type: type,
    siblingOrder: siblingOrder,
    title: title,
    content: content,
    chapterNum: chapterNum,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    deletedAt: notDeletedSentinel,
  );
}
