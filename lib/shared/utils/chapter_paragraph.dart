// 职责: 段落稳定 ID 的纯函数地基 — 切段、文本归一、FNV-1a 指纹、ID 生成与四态常量。
// 关联文件:
//   lib/shared/services/chapter_paragraph_rebind.dart
//   lib/shared/database/novel_content_database.dart (chapter_paragraphs 表)
//   lib/shared/services/novel_content.dart (正文写入单点挂钩)
//   lib/shared/utils/chapter_text_formatter.dart (切段约定与其保持一致)
// 遵循的 Rules:
//   .agents/rules/code-style.md
//
// R-10：正文 content 仍是唯一真源，段落是"保存时切一次"的派生索引。
// 本文件只做无副作用的纯计算，不碰数据库、不依赖 drift，便于单测锁死边界。

/// 段落生命周期四态（对齐方案 §1）：
/// - [active]  当前正文中存在；
/// - [orphaned] 被删除/大改且无可靠映射，标记需人工重新定位；
/// - [merged]  被并入其它段，保留 remap 溯源；
/// - [split]   被拆成多段，保留 remap 溯源。
const String chapterParagraphStatusActive = 'active';
const String chapterParagraphStatusOrphaned = 'orphaned';
const String chapterParagraphStatusMerged = 'merged';
const String chapterParagraphStatusSplit = 'split';

const List<String> chapterParagraphStatuses = [
  chapterParagraphStatusActive,
  chapterParagraphStatusOrphaned,
  chapterParagraphStatusMerged,
  chapterParagraphStatusSplit,
];

/// 非法/缺失状态回退到 active（读旧数据或手写 JSON 时容错）。
String normalizeChapterParagraphStatus(String? value) {
  if (value == null) {
    return chapterParagraphStatusActive;
  }
  return chapterParagraphStatuses.contains(value)
      ? value
      : chapterParagraphStatusActive;
}

/// 段落算法输入/输出的轻量快照，刻意不含 drift 行字段（createdAt 等）。
///
/// [text] 只参与相似度计算，不落库；落库只需 [paragraphId]/[order]/
/// [textHash]/[status]/[mergedFrom]/[splitInto]。
class ParagraphSnapshot {
  const ParagraphSnapshot({
    required this.paragraphId,
    required this.order,
    required this.textHash,
    this.text = '',
    this.status = chapterParagraphStatusActive,
    this.revisionId = '',
    this.mergedFrom = const [],
    this.splitInto = const [],
  });

  final String paragraphId;
  final int order;
  final String textHash;
  final String text;
  final String status;
  final String revisionId;
  final List<String> mergedFrom;
  final List<String> splitInto;

  @override
  String toString() =>
      'ParagraphSnapshot($paragraphId, order=$order, status=$status, '
      'hash=$textHash)';
}

/// 统一换行符并按"非空行 = 一段"切分正文（方案 §2.1）。
///
/// 与 `chapter_text_formatter.formatText` 及 `_splitParagraphs` 的切分约定一致：
/// `\r\n`/`\r` → `\n`，逐行去首尾空白（含全角空格 \u3000 / tab），
/// 空行是段间分隔、不计段落。段落文本 = 归一后的非空行。
List<String> splitChapterParagraphs(String content) {
  if (content.isEmpty) {
    return const [];
  }
  final unified = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final paragraphs = <String>[];
  for (final raw in unified.split('\n')) {
    final normalized = normalizeChapterParagraphText(raw);
    if (normalized.isNotEmpty) {
      paragraphs.add(normalized);
    }
  }
  return List.unmodifiable(paragraphs);
}

/// 段落文本归一：去首尾的半角空白、全角空格 \u3000 与 tab；行内原样保留。
String normalizeChapterParagraphText(String raw) {
  return raw.replaceAll(RegExp(r'^[\s\u3000]+|[\s\u3000]+$'), '');
}

/// FNV-1a 64bit 段落指纹，转 16 位十六进制（方案 §3.1）。
///
/// 用 UTF-16 codeUnit 逐字节异或/相乘，原生 Dart int 为 64bit，
/// 每步掩码防止越界。相同文本必相同指纹，作为三层匹配的第一道精确筛。
String chapterParagraphTextHash(String normalizedText) {
  // Dart 的 int 在目标 SDK 上是有符号 64 位，无法表示 0xFFFFFFFFFFFFFFFF
  // 作为正数（该字面量会被解释成 -1），因此改用 BigInt 做真正的 64 位
  // 无符号 FNV-1a，避免负号污染指纹。
  var hash = BigInt.parse('CBF29CE484222325', radix: 16);
  final prime = BigInt.parse('100000001B3', radix: 16);
  final mask64 = (BigInt.one << 64) - BigInt.one;
  for (final unit in normalizedText.codeUnits) {
    hash ^= BigInt.from(unit);
    hash = (hash * prime) & mask64;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// 段落稳定 ID：'p-{chapterId}-{seq:04d}'（方案 §2.2）。
///
/// seq 是段落**首次进入正文**时的章内序号，与当前位置解耦：前后增删段落
/// 不改变既有 ID。调用方负责用"该章未占用的最大 seq + 1"分配，避免与
/// 历史 remap 残留撞号。
String chapterParagraphId(String chapterId, int seq) {
  return 'p-$chapterId-${seq.toString().padLeft(4, '0')}';
}

/// 从 'p-{chapterId}-{seq:04d}' 反解 seq；格式不符返回 null。
int? chapterParagraphSeqFromId(String paragraphId, String chapterId) {
  final prefix = 'p-$chapterId-';
  if (!paragraphId.startsWith(prefix)) {
    return null;
  }
  return int.tryParse(paragraphId.substring(prefix.length));
}
