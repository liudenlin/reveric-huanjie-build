// 职责: M5 SmartDocumentImportService 测试 — ZIP 解包/路径安全/DOCX 提取/资料入库。
// 关联文件:
//   lib/shared/services/smart_document_import_service.dart
//   lib/shared/services/documents_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（总纲 §4 M5）：多格式导入（TXT/MD/CSV/DOCX 进 ZIP 批量导入资料库）；
//   来源可溯（按文件名落库）；冲突语义由 M3 候选层承接（此处验证文档入库幂等）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/documents_service.dart';
import 'package:reveric/shared/services/smart_document_import_service.dart';

void main() {
  late NovelContentDatabase db;
  late DocumentsService documents;
  late SmartDocumentImportService service;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    documents = DocumentsService(db);
    service = SmartDocumentImportService(db: db, documentsService: documents);
  });

  tearDown(() async => db.close());

  /// 构造一段合法 ZIP 字节：两个文本 + 一个 docx 条目。
  Uint8List makeZip({
    List<(String, String)> texts = const [],
    List<(String, Uint8List)> binaries = const [],
  }) {
    final archive = Archive();
    for (final (path, text) in texts) {
      archive.addFile(ArchiveFile.bytes(path, utf8.encode(text)));
    }
    for (final (path, bytes) in binaries) {
      archive.addFile(ArchiveFile.bytes(path, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// 构造最小合法 DOCX 字节（zip 内的 word/document.xml 含一个 w:t 段落）。
  Uint8List makeDocx(String paragraphText) {
    final xml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>$paragraphText</w:t></w:r></w:p>
  </w:body>
</w:document>''';
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes('word/document.xml', utf8.encode(xml)),
      );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  group('SmartDocumentImportService', () {
    test('unpackZip 解析文本与二进制条目', () {
      final bytes = makeZip(
        texts: [
          ('设定集.txt', '第一章 世界观'),
          ('人物表.md', '# 林晚'),
        ],
        binaries: [
          ('封面.png', Uint8List.fromList([1, 2, 3])),
        ],
      );
      final result = service.unpackZip(bytes);
      expect(result, isNotNull);
      expect(result!.entries, hasLength(3));
      final texts = result.entries.where((e) => e.isText).toList();
      expect(texts, hasLength(2));
      expect(texts.map((e) => e.path), contains('设定集.txt'));
      expect(texts.map((e) => e.path), contains('人物表.md'));
      expect(result.entries.any((e) => e.path == '封面.png'), isTrue);
    });

    test('unpackZip 拒绝路径穿越条目', () {
      final bytes = makeZip(
        texts: [('../evil.txt', '逃逸内容')],
      );
      expect(() => service.unpackZip(bytes), throwsFormatException);
    });

    test('unpackZip 非 zip 字节返回 null', () {
      expect(
        service.unpackZip(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7])),
        isNull,
      );
    });

    test('extractDocxText 提取段落文本', () {
      final text = extractDocxText(makeDocx('林晚执剑立于雪中。'));
      expect(text.trim(), contains('林晚执剑立于雪中。'));
    });

    test('extractDocxText 缺 document.xml 抛 FormatException', () {
      final zip = makeZip(texts: [('readme.txt', '不是docx')]);
      expect(() => extractDocxText(zip), throwsFormatException);
    });

    test('importZipAsDocuments 批量导入资料文档', () async {
      final bytes = makeZip(
        texts: [
          ('设定集.txt', '第一章 世界观：灵气复苏。'),
          ('人物表.md', '# 林晚\n- 女主\n- 剑修'),
        ],
      );
      final result = await service.importZipAsDocuments(bytes: bytes);
      expect(result.okCount, 2);
      // 文档落库（同名标题 + material 类型）。
      final docs = await db.documentDao.getByType(documentTypeMaterial);
      expect(docs, hasLength(2));
      final setting = docs.firstWhere((d) => d.title == '设定集');
      expect(setting.content, contains('灵气复苏'));
      final roster = docs.firstWhere((d) => d.title == '人物表');
      expect(roster.content, contains('剑修'));
    });

    test('importZipAsDocuments 同名文档幂等覆盖（不重复导入）', () async {
      final first = await service.importZipAsDocuments(
        bytes: makeZip(texts: [('设定集.txt', 'v1 内容')]),
      );
      expect(first.okCount, 1);
      final second = await service.importZipAsDocuments(
        bytes: makeZip(texts: [('设定集.txt', 'v2 内容')]),
      );
      expect(second.okCount, 1);
      final docs = await db.documentDao.getByType(documentTypeMaterial);
      expect(docs, hasLength(1), reason: '同名文档应更新而非新增');
      expect(docs.single.content, 'v2 内容');
    });

    test('importZipAsDocuments 含 DOCX 解析导入', () async {
      final bytes = makeZip(
        texts: [('开场.txt', '第一幕')],
        binaries: [('大纲.docx', makeDocx('第二幕：冲突升级'))],
      );
      final result = await service.importZipAsDocuments(bytes: bytes);
      expect(result.okCount, 2);
      final docs = await db.documentDao.getByType(documentTypeMaterial);
      expect(docs, hasLength(2));
      final outline = docs.firstWhere((d) => d.title == '大纲');
      expect(outline.content, contains('冲突升级'));
    });

    test('importTextDocument 空文本跳过', () async {
      final id = await service.importTextDocument(
        fileName: '空.txt',
        text: '   ',
        type: documentTypeMaterial,
      );
      expect(id, isNull);
    });
  });
}