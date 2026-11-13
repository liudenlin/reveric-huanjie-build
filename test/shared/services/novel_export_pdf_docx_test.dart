// 职责: 验证整书 PDF（内嵌中文字体）与 DOCX（OOXML 打包）成书导出。
// 关联文件:
//   lib/shared/services/novel_export.dart
//   lib/shared/models/chapter.dart

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/chapter.dart';
import 'package:reveric/shared/services/novel_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('buildPdf 生成合法 PDF 并内嵌中文字体', () async {
    final fontData = await rootBundle.load(
      'assets/fonts/LXGWWenKai-Regular.ttf',
    );
    final bytes = await NovelExportService.buildPdf(
      title: '《示例作品》',
      author: '示例作者',
      chapters: [
        _chapter(id: 'volume_1', type: nodeTypeVolume, title: '第一卷'),
        _chapter(id: 'chapter_1', title: '风起', content: '第一章正文。\n第二段内容。'),
      ],
      fontData: fontData,
    );

    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('buildDocx 生成合法 DOCX 并保留标题、作者与正文', () {
    final bytes = NovelExportService.buildDocx(
      title: '《示例作品》',
      author: '示例作者',
      chapters: [
        _chapter(id: 'volume_1', type: nodeTypeVolume, title: '第一卷'),
        _chapter(id: 'chapter_1', title: '风起', content: '第一章正文。\n第二段内容。'),
      ],
    );

    final archive = ZipDecoder().decodeBytes(bytes);
    final files = {for (final file in archive.files) file.name: file};
    expect(files, contains('[Content_Types].xml'));
    expect(files, contains('_rels/.rels'));
    expect(files, contains('word/document.xml'));
    expect(files, contains('docProps/core.xml'));

    final xml = utf8.decode(files['word/document.xml']!.content);
    expect(xml, contains('示例作品'));
    expect(xml, contains('作者：示例作者'));
    expect(xml, contains('第一卷'));
    expect(xml, contains('第一章 风起'));
    expect(xml, contains('第一章正文。'));
    expect(xml, contains('第二段内容。'));
  });

  test('buildDocx 转义 XML 特殊字符', () {
    final bytes = NovelExportService.buildDocx(
      title: 'A & B <tag>',
      chapters: [_chapter(id: 'chapter_1', title: '风起', content: '正文 & <b>')],
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = {for (final file in archive.files) file.name: file};
    final xml = utf8.decode(files['word/document.xml']!.content);
    expect(xml, contains('A &amp; B &lt;tag&gt;'));
    expect(xml, contains('正文 &amp; &lt;b&gt;'));
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
