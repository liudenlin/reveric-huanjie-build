// 职责: R-10 段落锚点重绑定 — 三层匹配（hash→相似度→拆合窗口）+ ORPHANED 判定的纯函数。
// 关联文件:
//   lib/shared/utils/chapter_paragraph.dart
//   lib/shared/services/novel_content.dart (正文保存时调用)
//   lib/shared/utils/chapter_comment_anchor.dart (S3 批注按 remap 跟随段落)
// 遵循的 Rules:
//   .agents/rules/code-style.md
//
// 方案 §3：输入旧段落集 O（含 hash）+ 新正文切出的段落文本 N，输出旧→新 remap、
// 各段状态与 ORPHANED 标记。段落数每章几十，O(n·m) 可接受，不引第三方 diff 库。
// 全部为无副作用纯函数，θ 边界由单测锁死（方案标记的最大风险）。

import '../utils/chapter_paragraph.dart';

/// 相似度阈值（方案 §3.2）：低于此值不映射，宁可 ORPHANED 不挂错段。
const double kChapterParagraphRebindTheta = 0.80;

/// 拆分/合并判定窗口上限（方案 §3.2：相邻 1~3 段）。
const int kChapterParagraphRebindWindow = 3;

/// 前缀 + 公共后缀相似度：`(2 × (公共前缀长 + 公共后缀长)) / (lenA + lenB)`。
///
/// 小说编辑最高频情形是"段首段尾没变、中间改了几个字"，首尾比足够区分且 O(len)；
/// 前缀与后缀不得重叠（suffix < minLen - prefix），否则重复计算中间字符会虚高。
/// 完全相等返回 1.0；一空一非空返回 0.0。
double chapterParagraphSimilarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) {
    return 1.0;
  }
  if (a.isEmpty || b.isEmpty) {
    return 0.0;
  }
  final maxCommon = a.length < b.length ? a.length : b.length;
  var prefix = 0;
  while (prefix < maxCommon && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < maxCommon - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  return (prefix + suffix) * 2 / (a.length + b.length);
}

/// 重绑定结果：既指导 service 写库，也供批注跟随查映射。
class ParagraphRebind {
  const ParagraphRebind({
    required this.newParagraphs,
    required this.retiredParagraphs,
    required this.idRemap,
    required this.splitRemap,
    required this.mergedFromRemap,
    required this.orphanedIds,
  });

  /// 新正文每段的最终快照：paragraphId 已定（继承或新分配），order 为新序号，
  /// status 恒 active，hash 为新文本指纹。merge 段在 [mergedFromRemap] 溯源。
  final List<ParagraphSnapshot> newParagraphs;

  /// 旧段中不再 active 的段落（merged/split/orphaned），保留 remap 溯源。
  final List<ParagraphSnapshot> retiredParagraphs;

  /// 1:1 映射（精确/相似层）：旧 paragraphId → 新 paragraphId。
  /// 查不到说明该旧段被拆分或已消失，批注应标 ORPHANED。
  final Map<String, String> idRemap;

  /// 拆分 1→N：旧 paragraphId → 新段 paragraphId 列表。
  final Map<String, List<String>> splitRemap;

  /// 合并 N→1：新 paragraphId → 源旧段 paragraphId 列表。
  final Map<String, List<String>> mergedFromRemap;

  /// 无法可靠映射、需人工重新定位的旧 paragraphId 集合。
  final Set<String> orphanedIds;
}

/// 把一条批注绑定的旧 paragraphId 映射到新段落。
///
/// 只返回能 1:1 可靠跟随的目标；[splitRemap]（一对多）与 [orphanedIds] 都返回
/// null —— 段内偏移无法可靠落到某个新段，调用方据此标 ORPHANED（方案 §3.5）。
String? rebindParagraphId({
  required String oldParagraphId,
  required ParagraphRebind rebind,
}) {
  return rebind.idRemap[oldParagraphId];
}

int _maxSeq(Iterable<ParagraphSnapshot> olds, String chapterId) {
  var max = 0;
  for (final old in olds) {
    final seq = chapterParagraphSeqFromId(old.paragraphId, chapterId) ?? 0;
    if (seq > max) {
      max = seq;
    }
  }
  return max;
}

/// 执行三层重绑定。
///
/// [oldParagraphs] 为该章现存的旧段落（含 hash/paragraphId），[newTexts] 为
/// [splitChapterParagraphs] 切出的新正文段落（已归一），[chapterId] 用于分配新 ID。
String _concat(Iterable<String> parts) => parts.join();

ParagraphRebind rebindChapterParagraphs({
  required List<ParagraphSnapshot> oldParagraphs,
  required List<String> newTexts,
  required String chapterId,
  double theta = kChapterParagraphRebindTheta,
}) {
  final newHashes = newTexts.map(chapterParagraphTextHash).toList();
  final usedOld = <bool>[];
  final usedNew = <bool>[];
  for (var i = 0; i < oldParagraphs.length; i++) {
    usedOld.add(false);
  }
  for (var i = 0; i < newTexts.length; i++) {
    usedNew.add(false);
  }

  // 每个新段最终归属：继承的旧 id（可空）+ mergedFrom 溯源。
  final inheritedId = <String?>[];
  final newMergedFrom = <List<String>>[];
  for (var i = 0; i < newTexts.length; i++) {
    inheritedId.add(null);
    newMergedFrom.add(const []);
  }

  final idRemap = <String, String>{};
  final splitRemap = <String, List<String>>{};
  final mergedFromRemap = <String, List<String>>{};
  final retired = <ParagraphSnapshot>[];
  final orphanedIds = <String>{};

  // ── 第 1 层：hash 精确匹配，1:1 继承 ID（零成本，覆盖绝大多数"没动"的段） ──
  for (var oi = 0; oi < oldParagraphs.length; oi++) {
    for (var ni = 0; ni < newTexts.length; ni++) {
      if (usedOld[oi] || usedNew[ni]) {
        continue;
      }
      if (oldParagraphs[oi].textHash == newHashes[ni]) {
        usedOld[oi] = true;
        usedNew[ni] = true;
        inheritedId[ni] = oldParagraphs[oi].paragraphId;
        idRemap[oldParagraphs[oi].paragraphId] = oldParagraphs[oi].paragraphId;
        break;
      }
    }
  }

  // ── 第 2 层：相似度匹配剩余未配段，argmax 且 ≥ θ 才继承 ──
  for (var ni = 0; ni < newTexts.length; ni++) {
    if (usedNew[ni]) {
      continue;
    }
    var bestOi = -1;
    var bestSim = theta;
    for (var oi = 0; oi < oldParagraphs.length; oi++) {
      if (usedOld[oi]) {
        continue;
      }
      final sim = chapterParagraphSimilarity(
        oldParagraphs[oi].text,
        newTexts[ni],
      );
      if (sim >= bestSim) {
        bestSim = sim;
        bestOi = oi;
      }
    }
    if (bestOi >= 0) {
      usedOld[bestOi] = true;
      usedNew[ni] = true;
      inheritedId[ni] = oldParagraphs[bestOi].paragraphId;
      idRemap[oldParagraphs[bestOi].paragraphId] =
          oldParagraphs[bestOi].paragraphId;
    }
  }

  // 新 ID 分配器：从现存最大 seq + 1 起，避开历史 remap 残留。
  var nextSeq = _maxSeq(oldParagraphs, chapterId) + 1;
  String allocateId() => chapterParagraphId(chapterId, nextSeq++);

  // ── 第 3 层：拆分 / 合并（相邻 1~3 段窗口，处理拓扑变化） ──
  // 用"剩余段"的相对顺序做相邻拼接；已被前两层配走的段通常不夹在中间。
  final freeOld = <int>[];
  for (var oi = 0; oi < oldParagraphs.length; oi++) {
    if (!usedOld[oi]) {
      freeOld.add(oi);
    }
  }
  final freeNew = <int>[];
  for (var ni = 0; ni < newTexts.length; ni++) {
    if (!usedNew[ni]) {
      freeNew.add(ni);
    }
  }

  // 3a. 拆分 1→N：一个旧段被拆成相邻 k 个新段（k=2..window）。
  for (final oi in List<int>.of(freeOld)) {
    if (usedOld[oi]) {
      continue;
    }
    var matched = false;
    for (var width = 2; width <= kChapterParagraphRebindWindow; width++) {
      // 在剩余新序列里找一段起点，使连续 width 段拼接后与原段相似。
      for (var s = 0; s + width <= freeNew.length; s++) {
        if (freeNew.skip(s).take(width).any((ni) => usedNew[ni])) {
          continue;
        }
        final parts = freeNew.skip(s).take(width).map((ni) => newTexts[ni]);
        final sim = chapterParagraphSimilarity(
          oldParagraphs[oi].text,
          _concat(parts),
        );
        if (sim >= theta) {
          final newIds = <String>[];
          for (final ni in freeNew.skip(s).take(width)) {
            usedNew[ni] = true;
            final id = allocateId();
            inheritedId[ni] = id;
            newIds.add(id);
          }
          usedOld[oi] = true;
          splitRemap[oldParagraphs[oi].paragraphId] = List.unmodifiable(newIds);
          retired.add(
            ParagraphSnapshot(
              paragraphId: oldParagraphs[oi].paragraphId,
              order: oldParagraphs[oi].order,
              textHash: oldParagraphs[oi].textHash,
              text: oldParagraphs[oi].text,
              status: chapterParagraphStatusSplit,
              revisionId: oldParagraphs[oi].revisionId,
              splitInto: newIds,
            ),
          );
          matched = true;
          break;
        }
      }
      if (matched) {
        break;
      }
    }
  }

  // 3b. 合并 N→1：相邻 k 个旧段拼成一个新段（k=2..window）。
  for (var ni = 0; ni < newTexts.length; ni++) {
    if (usedNew[ni]) {
      continue;
    }
    var matched = false;
    for (var width = 2; width <= kChapterParagraphRebindWindow; width++) {
      // 在剩余旧序列里找连续 width 段拼接后与新段相似。
      for (var s = 0; s + width <= freeOld.length; s++) {
        final window = freeOld.skip(s).take(width).toList();
        if (window.any((oi) => usedOld[oi])) {
          continue;
        }
        final parts = window.map((oi) => oldParagraphs[oi].text);
        final sim = chapterParagraphSimilarity(_concat(parts), newTexts[ni]);
        if (sim >= theta) {
          final sourceIds = <String>[];
          for (final oi in window) {
            usedOld[oi] = true;
            sourceIds.add(oldParagraphs[oi].paragraphId);
          }
          // 每条 retired 段都记完整的合并源集合，便于单测与 UI 溯源。
          for (final oi in window) {
            retired.add(
              ParagraphSnapshot(
                paragraphId: oldParagraphs[oi].paragraphId,
                order: oldParagraphs[oi].order,
                textHash: oldParagraphs[oi].textHash,
                text: oldParagraphs[oi].text,
                status: chapterParagraphStatusMerged,
                revisionId: oldParagraphs[oi].revisionId,
                mergedFrom: sourceIds,
              ),
            );
          }
          usedNew[ni] = true;
          final newId = allocateId();
          inheritedId[ni] = newId;
          newMergedFrom[ni] = List.unmodifiable(sourceIds);
          mergedFromRemap[newId] = List.unmodifiable(sourceIds);
          for (final sourceId in sourceIds) {
            idRemap[sourceId] = newId;
          }
          matched = true;
          break;
        }
      }
      if (matched) {
        break;
      }
    }
  }

  // 剩余旧段：无映射 → ORPHANED（保留内容，不回写正文，进人工重定位队列）。
  for (var oi = 0; oi < oldParagraphs.length; oi++) {
    if (usedOld[oi]) {
      continue;
    }
    orphanedIds.add(oldParagraphs[oi].paragraphId);
    retired.add(
      ParagraphSnapshot(
        paragraphId: oldParagraphs[oi].paragraphId,
        order: oldParagraphs[oi].order,
        textHash: oldParagraphs[oi].textHash,
        text: oldParagraphs[oi].text,
        status: chapterParagraphStatusOrphaned,
        revisionId: oldParagraphs[oi].revisionId,
      ),
    );
  }

  // 剩余新段：纯新增，分配新 ID。
  for (var ni = 0; ni < newTexts.length; ni++) {
    if (!usedNew[ni]) {
      inheritedId[ni] = allocateId();
    }
  }

  // 汇总新段落集（按新正文顺序）。
  final newParagraphs = <ParagraphSnapshot>[];
  for (var ni = 0; ni < newTexts.length; ni++) {
    final id = inheritedId[ni]!;
    newParagraphs.add(
      ParagraphSnapshot(
        paragraphId: id,
        order: ni,
        textHash: newHashes[ni],
        text: newTexts[ni],
        status: chapterParagraphStatusActive,
        mergedFrom: newMergedFrom[ni],
      ),
    );
  }

  return ParagraphRebind(
    newParagraphs: List.unmodifiable(newParagraphs),
    retiredParagraphs: List.unmodifiable(retired),
    idRemap: Map.unmodifiable(idRemap),
    splitRemap: Map.unmodifiable(splitRemap),
    mergedFromRemap: Map.unmodifiable(mergedFromRemap),
    orphanedIds: Set.unmodifiable(orphanedIds),
  );
}
