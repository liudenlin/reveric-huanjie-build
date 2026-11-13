// 职责: R-10 段落地基纯函数测试 — 切段约定、FNV-1a 指纹、稳定 ID、四态容错。
// 关联文件:
//   lib/shared/utils/chapter_paragraph.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（方案 §2）：段落切分与 chapter_text_formatter 一致（非空行=一段）、
//   同文本同 hash、ID 与位置解耦、旧数据状态回退 active。

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/utils/chapter_paragraph.dart';

void main() {
  group('splitChapterParagraphs 切段约定', () {
    test('统一 \\r\\n/\\r 为换行，非空行成段、空行不计', () {
      expect(splitChapterParagraphs('第一段\r\n\r\n第二段\r第三段'), [
        '第一段',
        '第二段',
        '第三段',
      ]);
    });

    test('去首尾半角/全角空格与 tab，行内原样保留', () {
      expect(splitChapterParagraphs('  甲　乙\t\n\u3000丙\u3000'), ['甲　乙', '丙']);
    });

    test('空正文返回空段集', () {
      expect(splitChapterParagraphs(''), isEmpty);
      expect(splitChapterParagraphs('\n\n  \n'), isEmpty);
    });

    test('与 read 视图 _splitParagraphs 规则一致：连续非空行各自成段', () {
      expect(splitChapterParagraphs('一\n二\n三'), ['一', '二', '三']);
    });
  });

  group('chapterParagraphTextHash 指纹', () {
    test('同文本同指纹、异文本异指纹', () {
      expect(
        chapterParagraphTextHash('林晚执剑而立。'),
        chapterParagraphTextHash('林晚执剑而立。'),
      );
      expect(
        chapterParagraphTextHash('林晚执剑而立。'),
        isNot(chapterParagraphTextHash('林晚收剑而立。')),
      );
    });

    test('指纹恒为 16 位十六进制', () {
      for (final text in ['', 'a', '中文段落', 'A' * 200]) {
        expect(
          chapterParagraphTextHash(text),
          matches(RegExp(r'^[0-9a-f]{16}$')),
        );
      }
    });

    test('空文本也有确定指纹（不抛异常）', () {
      expect(chapterParagraphTextHash(''), chapterParagraphTextHash(''));
    });
  });

  group('稳定 ID 与状态容错', () {
    test('ID 格式为 p-{chapterId}-{seq:04d} 且 seq 补零', () {
      expect(chapterParagraphId('ch1', 0), 'p-ch1-0000');
      expect(chapterParagraphId('ch1', 42), 'p-ch1-0042');
      expect(chapterParagraphId('ch1', 12345), 'p-ch1-12345');
    });

    test('seq 反解：合法 ID 取回序号，前缀不符/非法返回 null', () {
      expect(chapterParagraphSeqFromId('p-ch1-0007', 'ch1'), 7);
      expect(chapterParagraphSeqFromId('p-ch1-0007', 'ch2'), isNull);
      expect(chapterParagraphSeqFromId('garbage', 'ch1'), isNull);
    });

    test('四态常量齐全，非法状态回退 active', () {
      expect(chapterParagraphStatuses, hasLength(4));
      expect(
        normalizeChapterParagraphStatus(null),
        chapterParagraphStatusActive,
      );
      expect(
        normalizeChapterParagraphStatus('weird'),
        chapterParagraphStatusActive,
      );
      expect(
        normalizeChapterParagraphStatus(chapterParagraphStatusOrphaned),
        chapterParagraphStatusOrphaned,
      );
    });
  });
}
