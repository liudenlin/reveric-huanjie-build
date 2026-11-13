// 职责: 验证 EPUB 成书导出按 EPUB3 容器规范打包正文、目录与元数据。
// 关联文件:
//   lib/shared/services/novel_export.dart
//   lib/shared/models/chapter.dart

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/chapter.dart';
import 'package:reveric/shared/services/novel_export.dart';

void main() {
  test('buildEpub 生成合法 EPUB3 容器并保留正文与目录', () {
    final bytes = NovelExportService.buildEpub(
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

    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.files, isNotEmpty);

    final files = {for (final file in archive.files) file.name: file};
    expect(files.keys.first, 'mimetype');
    expect(files['mimetype']!.compression, CompressionType.none);
    expect(utf8.decode(files['mimetype']!.content), 'application/epub+zip');

    for (final required in [
      'META-INF/container.xml',
      'OEBPS/content.opf',
      'OEBPS/toc.ncx',
      'OEBPS/nav.xhtml',
      'OEBPS/style.css',
      'OEBPS/chapter_001.xhtml',
      'OEBPS/chapter_002.xhtml',
    ]) {
      expect(files, contains(required));
    }
    // 卷节点只做目录分组，不输出正文文件。
    expect(files, isNot(contains('OEBPS/chapter_003.xhtml')));

    final opf = _text(files['OEBPS/content.opf']!);
    expect(opf, contains('<dc:title>《示例作品》</dc:title>'));
    expect(opf, contains('<dc:creator>示例作者</dc:creator>'));
    expect(opf, contains('<itemref idref="chapter-1"/>'));
    expect(opf, contains('<itemref idref="chapter-2"/>'));

    final nav = _text(files['OEBPS/nav.xhtml']!);
    expect(nav, contains('>风起</a>'));
    expect(nav, contains('>第 2 章</a>'));

    final firstChapter = _text(files['OEBPS/chapter_001.xhtml']!);
    expect(firstChapter, contains('<h1>风起</h1>'));
    expect(firstChapter, contains('<p>第一章正文。</p>'));
    expect(firstChapter, contains('<p>第二段内容。</p>'));

    final secondChapter = _text(files['OEBPS/chapter_002.xhtml']!);
    expect(secondChapter, contains('<h1>第 2 章</h1>'));
  });

  test('buildEpub 转义 XML 特殊字符并回退未命名标题', () {
    final bytes = NovelExportService.buildEpub(
      title: 'A & B <tag> "q"',
      chapters: [
        _chapter(id: 'chapter_1', title: '章节 & <测试>', content: '正文 & <b>'),
      ],
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = {for (final file in archive.files) file.name: file};
    final opf = _text(files['OEBPS/content.opf']!);
    expect(opf, contains('A &amp; B &lt;tag&gt; &quot;q&quot;'));
    expect(
      _text(files['OEBPS/chapter_001.xhtml']!),
      contains('<h1>章节 &amp; &lt;测试&gt;</h1>'),
    );
    expect(_text(files['OEBPS/nav.xhtml']!), contains('章节 &amp; &lt;测试&gt;'));
    expect(
      _text(files['OEBPS/chapter_001.xhtml']!),
      contains('<p>正文 &amp; &lt;b&gt;</p>'),
    );
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

String _text(ArchiveFile file) {
  return utf8.decode(file.content);
}
