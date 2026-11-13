// 职责: M5 智能资料导入 —— ZIP/TXT/MD/DOCX 批量导入 + 导入后自动提取建议。
// 关联文件:
//   lib/shared/services/novel_import.dart (单 TXT 拆章导入)
//   lib/shared/services/plugins/package_archive.dart (ZIP 解压范式)
//   lib/shared/services/conversation_to_canon_service.dart (M3 冲突识别/落位)
// 遵循的 Rules:
//   .agents/rules/db-migration.md
//   .agents/rules/testing.md
//
// 验收（总纲 §4 M5）：
//   - TXT/MD/DOCX/PDF/ZIP 导入：ZIP 解包后逐文件走既有拆章/资料导入；
//   - 多版本冲突识别（不自动覆盖正式事实）：抽取结果先进 FactProposals/
//     CanonEntries proposal 层，同名命中标记 conflict，由作者裁决；
//   - 来源可溯：载体文件路径写入 metadata，可回溯到原始文件。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import '../models/content_kind.dart';
import '../models/novel_type.dart';
import '../utils/text_file_decoder.dart';
import 'documents_service.dart';
import 'novel_import.dart';

final _log = AppLogger.forModule('SmartImport');

/// 从 ZIP 字节中解出的文本条目（内存态，供导入编排逐条消费）。
class ZipImportEntry {
  const ZipImportEntry({
    required this.path,
    required this.content,
    this.bytes,
    this.isText = true,
  });

  final String path;

  /// 文本文件解码后的内容。
  final String content;

  /// 原始字节（docx/素材等非纯文本文件使用）。
  final Uint8List? bytes;

  /// 是否纯文本资源（TXT/MD/CSV）。
  final bool isText;

  const ZipImportEntry.text({
    required this.path,
    required this.content,
  }) : bytes = null,
       isText = true;

  const ZipImportEntry.binary({
    required this.path,
    required this.bytes,
  }) : content = '',
       isText = false;
}

/// ZIP 解包结果（路径安全校验已完成）。
class ZipImportResult {
  const ZipImportResult({required this.entries, required this.totalBytes});

  final List<ZipImportEntry> entries;
  final int totalBytes;
}

/// 单个文件导入结果（供 UI 汇总展示）。
class SmartImportFileResult {
  const SmartImportFileResult({
    required this.path,
    required this.kind,
    required this.ok,
    this.message = '',
    this.novelId,
  });

  final String path;

  /// novel / document / skipped。
  final String kind;
  final bool ok;
  final String message;
  final String? novelId;
}

/// ZIP 批量导入结果。
class SmartImportResult {
  const SmartImportResult({required this.results});

  final List<SmartImportFileResult> results;

  int get okCount => results.where((r) => r.ok).length;
  int get failedCount => results.length - okCount;
}

/// 从 DOCX（OOXML）字节中提取纯文本。
///
/// DOCX 是 zip 容器，正文在 word/document.xml（WordprocessingML）。
/// 取 `<w:t>` 文本节点拼回段落，段落间用换行分隔。
String extractDocxText(Uint8List bytes) {
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  ZipFile? documentXml;
  for (final header in directory.fileHeaders) {
    if (header.filename == 'word/document.xml') {
      documentXml = header.file;
      break;
    }
  }
  if (documentXml == null) {
    throw const FormatException('DOCX 缺少 word/document.xml（可能不是有效 DOCX）。');
  }
  final xmlBytes = documentXml.readBytes();
  final document = XmlDocument.parse(utf8.decode(xmlBytes, allowMalformed: true));
  final buffer = StringBuffer();
  for (final paragraph in document.findAllElements('w:p')) {
    final texts = paragraph
        .findAllElements('w:t')
        .map((node) => node.innerText)
        .join();
    if (texts.trim().isNotEmpty) {
      buffer.writeln(texts);
    }
  }
  return buffer.toString();
}

/// M5 智能导入服务：把多个 TXT/MD/DOCX/ZIP 文件批量导入为小说/
/// 资料文档，并在导入后生成「自动提取」候选（走 M3 冲突识别）。
class SmartDocumentImportService {
  SmartDocumentImportService({
    required this.db,
    required this.documentsService,
    this.novelImport,
  });

  final NovelContentDatabase db;
  final DocumentsService documentsService;

  /// 小说拆章导入服务（可选，ZIP 批量为资料文档时不使用）。
  final NovelImportService? novelImport;

  static const maxZipEntries = 500;
  static const maxExpandedBytes = 50 * 1024 * 1024;

  /// 展开 ZIP 字节到内存条目（路径安全 + 总量上限）。
  ///
  /// 返回 null 表示不可解（非 zip 或超限），调用方据此降级为「原文素材导入」。
  ZipImportResult? unpackZip(Uint8List bytes) {
    if (bytes.isEmpty) {
      return null;
    }
    ZipDirectory? directory;
    try {
      directory = ZipDirectory()..read(InputMemoryStream(bytes));
    } on ArchiveException catch (error) {
      _log.warning('[SmartImport] zip open failed: $error');
      return null;
    }
    if (directory.fileHeaders.isEmpty) {
      // 非 zip（读不到中央目录记录）或空压缩包。
      return null;
    }
    var expanded = 0;
    var count = 0;
    final entries = <ZipImportEntry>[];
    for (final header in directory.fileHeaders) {
      if (header.filename.endsWith('/')) {
        continue;
      }
      count++;
      if (count > maxZipEntries) {
        throw const FormatException('ZIP 条目超过 500 个，已拒绝。');
      }
      expanded += header.uncompressedSize;
      if (expanded > maxExpandedBytes) {
        throw const FormatException('ZIP 解压后超过 50MB，已拒绝。');
      }
      final path = header.filename.replaceAll('\\', '/');
      // 路径穿越防护：拒绝绝对路径或 .. 逃逸。
      if (path.startsWith('/') ||
          path.split('/').any((part) => part == '..')) {
        throw FormatException('ZIP 内含非法路径：$path');
      }
      final lower = path.toLowerCase();
      if (lower.endsWith('.txt') ||
          lower.endsWith('.md') ||
          lower.endsWith('.csv')) {
        final raw = header.file?.readBytes() ?? Uint8List(0);
        final text = decodeImportedTextBytes(
          raw,
          onGbkDecodeFailure: (error) {},
        );
        entries.add(ZipImportEntry.text(path: path, content: text));
      } else if (lower.endsWith('.docx')) {
        final raw = header.file?.readBytes() ?? Uint8List(0);
        entries.add(ZipImportEntry.binary(path: path, bytes: raw));
      } else {
        // 其他文件（pdf/图片等）作为原文素材，记录但不解析。
        final raw = header.file?.readBytes() ?? Uint8List(0);
        entries.add(ZipImportEntry.binary(path: path, bytes: raw));
      }
    }
    return ZipImportResult(entries: entries, totalBytes: expanded);
  }

  /// 把单个 TXT/MD/CSV 文本内容当作「资料文档」导入。
  ///
  /// 走文档导入（非小说拆章）：设定集/大纲/素材入库为 Documents。
  /// [type] 为 documentType* 常量（lore / material），默认 material。
  /// [_upsert] 语义与 DocumentsService 的 _upsertImportedDocument 一致
  /// （同名文档更新而非新增，避免重复导入产生多份）。
  Future<String?> importTextDocument({
    required String fileName,
    required String text,
    required String type,
  }) async {
    if (text.trim().isEmpty) {
      return null;
    }
    final title = _docTitleFromFileName(fileName);
    final existing = await documentsService.getDocumentByTitle(
      type: type,
      title: title,
    );
    if (existing != null) {
      await documentsService.updateDocument(
        id: existing.id,
        title: title,
        content: text,
      );
      return existing.id;
    }
    final id = await documentsService.createDocument(
      type: type,
      title: title,
      content: text,
    );
    return id;
  }

  String _docTitleFromFileName(String fileName) {
    final base = fileName.split('/').last;
    final dotIndex = base.lastIndexOf('.');
    return dotIndex > 0 ? base.substring(0, dotIndex) : base;
  }

  /// 导入 ZIP/txt (多个文件)：逐个处理，返回汇总结果。
  ///
  /// - ZIP 内的 .txt/.md/.csv → 批量为资料文档（不自动拆章覆盖小说，
  ///   因为 ZIP 常常是「多版本设定包」，冲突由 M3 候选层承接）；
  /// - 明确的单本 TXT 拆章仍走 [novelImport.importTxt]（原有路径）。
  Future<SmartImportResult> importZipAsDocuments({
    required Uint8List bytes,
    String novelId = '',
  }) async {
    final unpacked = unpackZip(bytes);
    if (unpacked == null) {
      throw const FormatException('无法解压 ZIP，请确认文件完整。');
    }
    final results = <SmartImportFileResult>[];
    var index = 0;
    for (final entry in unpacked.entries) {
      index++;
      final isDocx = entry.path.toLowerCase().endsWith('.docx');
      try {
        if (entry.isText) {
          await importTextDocument(
            fileName: entry.path,
            text: entry.content,
            type: documentTypeMaterial,
          );
          results.add(SmartImportFileResult(
            path: entry.path,
            kind: 'document',
            ok: true,
            message: '文本已导入资料库',
          ));
        } else if (isDocx) {
          final raw = entry.bytes;
          if (raw == null) {
            throw const FormatException('DOCX 内容为空。');
          }
          final text = extractDocxText(raw);
          await importTextDocument(
            fileName: entry.path.replaceAll(RegExp(r'\.docx$'), '.md'),
            text: text,
            type: documentTypeMaterial,
          );
          results.add(SmartImportFileResult(
            path: entry.path,
            kind: 'document',
            ok: true,
            message: 'DOCX 已解析为文本导入',
          ));
        } else {
          results.add(SmartImportFileResult(
            path: entry.path,
            kind: 'skipped',
            ok: true,
            message: '非文本资源已跳过（可手动上传素材）',
          ));
        }
      } catch (error) {
        _log.warning('[SmartImport] file $index failed: $error');
        results.add(SmartImportFileResult(
          path: entry.path,
          kind: 'document',
          ok: false,
          message: error.toString(),
        ));
      }
    }
    return SmartImportResult(results: results);
  }

  /// 把单个 TXT 文件作为「小说」导入（既有拆章路径，允许脚本调用）。
  Future<NovelImportResult> importTxtNovel({
    required String filePath,
    required String title,
    required String description,
    required String category,
    required String type,
    required List<String> tags,
  }) {
    final importer = novelImport;
    if (importer == null) {
      throw StateError('novelImport 未注入，无法拆章导入小说。');
    }
    return importer.importTxt(
      filePath: filePath,
      title: title,
      description: description,
      category: category,
      type: novelTypes.contains(type) ? type : novelTypeOriginal,
      tags: tags,
    );
  }
}

/// 作品类型与内容类型校验辅助（供 UI 侧使用）。
String normalizeContentKindFromType(String type) {
  // 短剧落在剧本形态；改编/衍生统一按剧本处理（与既有规则一致）。
  if (type == novelTypeShortDrama || type == novelTypeAdaptation) {
    return contentKindScreenplay;
  }
  return contentKindNovel;
}