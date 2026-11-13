// 职责: R-44 批注分类与任务联动模型测试 — 9 类分类常量、旧数据兼容、JSON roundtrip。
// 关联文件:
//   lib/shared/models/chapter_comment.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（R-44）：批注可携带分类标签（9 类）与任务/提案联动引用；
//   旧批注（无 category 字段）读取回退 general 且不崩；category 始终写入 JSON。

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/chapter_comment.dart';

void main() {
  ChapterComment makeComment({
    String? category = chapterCommentCategoryGeneral,
    String? linkedTaskType,
    String? linkedTaskId,
  }) {
    final now = DateTime(2026, 11, 10);
    return ChapterComment(
      id: 'c_1',
      start: 10,
      end: 20,
      quote: '林晚执剑而立。',
      content: '待确认',
      createdAt: now,
      updatedAt: now,
      category: category ?? chapterCommentCategoryGeneral,
      linkedTaskType: linkedTaskType,
      linkedTaskId: linkedTaskId,
    );
  }

  group('R-44 ChapterComment 分类', () {
    test('9 类分类常量齐全且互不相同', () {
      expect(chapterCommentCategories, hasLength(9));
      expect(chapterCommentCategories.toSet(), hasLength(9));
      expect(
        chapterCommentCategories,
        containsAll([
          chapterCommentCategoryGeneral,
          chapterCommentCategoryToFix,
          chapterCommentCategoryToVerify,
          chapterCommentCategoryIncoherent,
          chapterCommentCategoryConflict,
          chapterCommentCategoryNeedAsset,
          chapterCommentCategoryNeedDiscussion,
          chapterCommentCategoryConfirmed,
          chapterCommentCategoryLocked,
        ]),
      );
    });

    test('normalizeChapterCommentCategory：null/非法值回退 general', () {
      expect(normalizeChapterCommentCategory(null), chapterCommentCategoryGeneral);
      expect(
        normalizeChapterCommentCategory('not_a_category'),
        chapterCommentCategoryGeneral,
      );
      expect(
        normalizeChapterCommentCategory(chapterCommentCategoryToFix),
        chapterCommentCategoryToFix,
      );
      expect(
        normalizeChapterCommentCategory(chapterCommentCategoryLocked),
        chapterCommentCategoryLocked,
      );
    });

    test('旧批注 JSON（无 category/linked 字段）读取回退默认且不崩', () {
      final legacy = ChapterComment.fromJson({
        'id': 'legacy_1',
        'start': 0,
        'end': 5,
        'quote': '旧文',
        'content': '旧批注',
        'status': 'open',
        'created_at': 1734739200,
        'updated_at': 1734739200,
      });
      expect(legacy.category, chapterCommentCategoryGeneral);
      expect(legacy.linkedTaskType, isNull);
      expect(legacy.linkedTaskId, isNull);
    });

    test('分类与联动引用 JSON roundtrip 完整保留', () {
      final comment = makeComment(
        category: chapterCommentCategoryNeedAsset,
        linkedTaskType: 'asset_generate',
        linkedTaskId: 'task_gen_9',
      );
      final restored = ChapterComment.fromJson(comment.toJson());
      expect(restored.category, chapterCommentCategoryNeedAsset);
      expect(restored.linkedTaskType, 'asset_generate');
      expect(restored.linkedTaskId, 'task_gen_9');
    });

    test('category 恒定写入 JSON；linked 为 null 时不写键', () {
      final comment = makeComment(); // general + 无 linked
      final json = comment.toJson();
      expect(json['category'], chapterCommentCategoryGeneral);
      expect(json.containsKey('linked_task_type'), isFalse);
      expect(json.containsKey('linked_task_id'), isFalse);
    });

    test('copyWith 改分类/联动引用保持锚点字段不变', () {
      final original = makeComment();
      final edited = original.copyWith(
        category: chapterCommentCategoryToVerify,
        linkedTaskType: 'revision_proposal',
        linkedTaskId: 'proposal_7',
      );
      // 锚点与内容不变。
      expect(edited.quote, original.quote);
      expect(edited.start, original.start);
      expect(edited.end, original.end);
      expect(edited.content, original.content);
      expect(edited.id, original.id);
      // 分类与联动更新。
      expect(edited.category, chapterCommentCategoryToVerify);
      expect(edited.linkedTaskType, 'revision_proposal');
      expect(edited.linkedTaskId, 'proposal_7');
    });

    test('非法 category 从 JSON 读取时回退 general', () {
      final bad = ChapterComment.fromJson({
        'id': 'bad_1',
        'start': 0,
        'end': 1,
        'quote': 'x',
        'content': 'y',
        'status': 'open',
        'category': 'evil_category',
        'created_at': 1734739200,
        'updated_at': 1734739200,
      });
      expect(bad.category, chapterCommentCategoryGeneral);
    });
  });
}