// 职责: R-10 段落锚点重绑定算法测试 — 六类映射 + θ 边界 + ORPHANED + remap 溯源。
// 关联文件:
//   lib/shared/services/chapter_paragraph_rebind.dart
//   lib/shared/utils/chapter_paragraph.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（方案 §6 S2）：覆盖 精确/小改/拆分(1→2)/合并(2→1)/删除/新增 六类，
//   remap 结果与手工预期一致；θ 边界（0.79 不映射、0.80 映射）通过。
//   S2 是方案标记的最大风险，本文件用单测把阈值行为锁死。

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/chapter_paragraph_rebind.dart';
import 'package:reveric/shared/utils/chapter_paragraph.dart';

/// 用正文片段构造旧段落快照：ID/序号按入参顺序生成，hash 由文本算。
List<ParagraphSnapshot> oldParagraphs(List<String> texts, {String ch = 'ch1'}) {
  return [
    for (var i = 0; i < texts.length; i++)
      ParagraphSnapshot(
        paragraphId: chapterParagraphId(ch, i),
        order: i,
        text: texts[i],
        textHash: chapterParagraphTextHash(texts[i]),
      ),
  ];
}

void main() {
  group('chapterParagraphSimilarity 前缀+后缀比', () {
    test('完全相等 = 1.0；一空 = 0.0；双空 = 1.0', () {
      expect(chapterParagraphSimilarity('甲乙丙', '甲乙丙'), 1.0);
      expect(chapterParagraphSimilarity('甲乙丙', ''), 0.0);
      expect(chapterParagraphSimilarity('', ''), 1.0);
    });

    test('段首段尾不变、中间改字仍高相似', () {
      // '甲乙丙丁戊己' vs '甲乙X丁戊己'：前缀 2 + 后缀 3 = 5，2*5/12 ≈ 0.833
      expect(
        chapterParagraphSimilarity('甲乙丙丁戊己', '甲乙X丁戊己'),
        greaterThanOrEqualTo(0.8),
      );
    });

    test('首尾都变则相似骤降', () {
      expect(chapterParagraphSimilarity('甲乙丙丁', 'X乙丙Y'), lessThan(0.8));
    });
  });

  group('rebindChapterParagraphs 六类映射', () {
    test('① 精确层：文本未变 → 1:1 继承旧 ID，零 remap 抖动', () {
      final old = oldParagraphs(['第一段。', '第二段。']);
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: ['第一段。', '第二段。'],
        chapterId: 'ch1',
      );
      expect(result.newParagraphs.map((p) => p.paragraphId), [
        'p-ch1-0000',
        'p-ch1-0001',
      ]);
      expect(result.retiredParagraphs, isEmpty);
      expect(result.orphanedIds, isEmpty);
      expect(result.idRemap['p-ch1-0000'], 'p-ch1-0000');
    });

    test('② 相似层：段中改几字 → 继承旧 ID、hash 更新', () {
      final old = oldParagraphs([
        '甲乙丙丁戊己', // 6 字
        '独立第二段',
      ]);
      // 新段 '甲乙X丁戊己'：前缀2+后缀3=5 → 2*5/(6+6)=0.833 ≥ 0.8
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: ['甲乙X丁戊己', '独立第二段'],
        chapterId: 'ch1',
      );
      expect(result.newParagraphs[0].paragraphId, 'p-ch1-0000');
      expect(
        result.newParagraphs[0].textHash,
        chapterParagraphTextHash('甲乙X丁戊己'),
        reason: 'hash 必须更新为新文本',
      );
      expect(result.newParagraphs[1].paragraphId, 'p-ch1-0001');
      expect(result.orphanedIds, isEmpty);
    });

    test('③ 拆分层：1 段拆 2 段 → 旧段 status=split，newIds 记录', () {
      final old = oldParagraphs(['甲乙丙丁戊己']);
      // 拼接回去等于原段 → 相似 1.0 ≥ 0.8，命中拆分
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: ['甲乙丙', '丁戊己'],
        chapterId: 'ch1',
      );
      expect(result.splitRemap['p-ch1-0000'], hasLength(2));
      expect(
        result.retiredParagraphs.single.status,
        chapterParagraphStatusSplit,
      );
      expect(result.retiredParagraphs.single.splitInto, hasLength(2));
      expect(
        result.newParagraphs.map((p) => p.paragraphId).toSet(),
        isNot(contains('p-ch1-0000')),
        reason: '拆分后旧 ID 应退役，新段拿新 ID',
      );
      // 拆出的新段挂了旧批注也无法 1:1 跟随 → rebindParagraphId 为 null
      expect(
        rebindParagraphId(oldParagraphId: 'p-ch1-0000', rebind: result),
        isNull,
      );
    });

    test('④ 合并层：2 段并 1 段 → 旧段 status=merged，mergedFrom 溯源完整', () {
      final old = oldParagraphs(['甲乙丙', '丁戊己']);
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: ['甲乙丙丁戊己'],
        chapterId: 'ch1',
      );
      expect(result.retiredParagraphs, hasLength(2));
      expect(
        result.retiredParagraphs.every(
          (p) => p.status == chapterParagraphStatusMerged,
        ),
        isTrue,
      );
      // 每条 retired 段都带完整合并源集合（含自身），便于 UI 溯源。
      for (final retired in result.retiredParagraphs) {
        expect(
          retired.mergedFrom,
          unorderedEquals(['p-ch1-0000', 'p-ch1-0001']),
        );
      }
      final newId = result.newParagraphs.single.paragraphId;
      expect(
        result.mergedFromRemap[newId],
        unorderedEquals(['p-ch1-0000', 'p-ch1-0001']),
      );
      // 合并可 1:1 跟随到新段。
      expect(
        rebindParagraphId(oldParagraphId: 'p-ch1-0000', rebind: result),
        newId,
      );
      expect(
        rebindParagraphId(oldParagraphId: 'p-ch1-0001', rebind: result),
        newId,
      );
    });

    test('⑤ 删除：段被删且无映射 → status=orphaned，进 ORPHANED 队列', () {
      final old = oldParagraphs(['保留段', '将被删除的长段落XYZ']);
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: ['保留段'],
        chapterId: 'ch1',
      );
      expect(result.newParagraphs.single.paragraphId, 'p-ch1-0000');
      expect(result.orphanedIds, {'p-ch1-0001'});
      final orphan = result.retiredParagraphs.single;
      expect(orphan.status, chapterParagraphStatusOrphaned);
      expect(orphan.paragraphId, 'p-ch1-0001');
    });

    test('⑥ 新增：全新段分配新 ID，不占用历史 seq', () {
      final old = oldParagraphs(['原段']);
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: ['原段', '全新插入段'],
        chapterId: 'ch1',
      );
      expect(result.newParagraphs[0].paragraphId, 'p-ch1-0000');
      expect(result.newParagraphs[1].paragraphId, 'p-ch1-0001');
      expect(result.orphanedIds, isEmpty);
      expect(result.retiredParagraphs, isEmpty);
    });

    test('混合：精确 + 小改 + 删除 + 新增 同时发生', () {
      final old = oldParagraphs(['不动段', '甲乙丙丁戊己', '被删段']);
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: ['不动段', '甲乙X丁戊己', '新段'],
        chapterId: 'ch1',
      );
      expect(result.newParagraphs.map((p) => p.paragraphId), [
        'p-ch1-0000',
        'p-ch1-0001',
        'p-ch1-0003', // 新 ID 从 maxSeq(2)+1=3 起，避开被删段
      ]);
      expect(result.orphanedIds, {'p-ch1-0002'});
    });
  });

  group('θ 阈值边界（方案最大风险，锁死 0.79 / 0.80）', () {
    // 相似度 = (prefix + suffix) × 2 / (lenA + lenB)。
    // 取两段各 100 字、仅后 N 字不同、前缀后缀都不重叠：
    //   prefix=80, suffix=0 → 160/200 = 0.80（命中）
    //   prefix=79, suffix=0 → 158/200 = 0.79（不命中）
    // 用 'a'*80 + 'b'*20 形式精确控制，避免中文字符计数歧义。
    final prefix80A = 'a' * 100;
    final prefix80B = '${'a' * 80}${'b' * 20}'; // 前 80 同 → 0.80
    final prefix79B = '${'a' * 79}${'b' * 21}'; // 前 79 同 → 0.79

    test('相似度公式：0.80 与 0.79 精确可辨', () {
      expect(
        chapterParagraphSimilarity(prefix80A, prefix80B),
        closeTo(0.80, 1e-9),
      );
      expect(
        chapterParagraphSimilarity(prefix80A, prefix79B),
        closeTo(0.79, 1e-9),
      );
    });

    test('sim = 0.80（= θ）→ 命中相似层、继承旧 ID', () {
      final old = oldParagraphs([prefix80A]);
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: [prefix80B],
        chapterId: 'ch1',
        theta: 0.80,
      );
      expect(result.newParagraphs.single.paragraphId, 'p-ch1-0000');
      expect(result.orphanedIds, isEmpty);
      expect(result.retiredParagraphs, isEmpty);
    });

    test('sim = 0.79（< θ）→ 不映射，落 ORPHANED', () {
      final old = oldParagraphs([prefix80A]);
      final result = rebindChapterParagraphs(
        oldParagraphs: old,
        newTexts: [prefix79B],
        chapterId: 'ch1',
        theta: 0.80,
      );
      expect(result.orphanedIds, {'p-ch1-0000'});
      expect(
        result.retiredParagraphs.single.status,
        chapterParagraphStatusOrphaned,
      );
      expect(
        rebindParagraphId(oldParagraphId: 'p-ch1-0000', rebind: result),
        isNull,
      );
    });
  });
}
