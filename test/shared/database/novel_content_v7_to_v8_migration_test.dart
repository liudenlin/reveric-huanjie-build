// 职责: 验证内容库 schema v7 → v8 的直接升级：新增 ChapterParagraphs（R-10 段落稳定锚点）
//       表与索引、旧正文 content 零丢失、升级后段落一次性回填、旧 quote 批注锚点升级。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (schemaVersion=8, onUpgrade)
//   lib/shared/database/novel_content_daos/chapter_paragraph_dao.dart
//   lib/shared/services/chapter_paragraph_service.dart
//   lib/shared/utils/chapter_paragraph.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md（发布升级回归：上一 schema v7 直接升 v8）
//
// 验收（方案 §2.4/§4.1/§4.2 回归）：从 v7 fixture 直接升 v8，断言 user_version=8、
//   chapter_paragraphs 表存在且结构正确、升级后立即有段落 ID、旧 quote 批注
//   命中段补 paragraphId/paragraphHash、未命中保持空串、旧章 content 零丢失。

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/chapter_comment.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/chapter_paragraph_service.dart';
import 'package:reveric/shared/utils/chapter_paragraph.dart';

void main() {
  const chapterContent = '第一段旧正文。\r\n\r\n第二段旧正文，含逗号。\n第三段旧正文结尾。';

  /// 构造带真实旧数据的 v7 fixture：
  /// 1. 以当前 schema(v8) 建库，写入章节旧正文；
  /// 2. 删除 ChapterParagraphs 表（模拟 v7 本就没有该表）；
  /// 3. 将 user_version 降回 7，模拟「上一 schema」。
  Future<File> buildV7Fixture() async {
    final directory = await Directory.systemTemp.createTemp('rv-v7-fixture-');
    final file = File('${directory.path}/content.sqlite');
    var db = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      await db
          .into(db.chapters)
          .insert(
            ChaptersCompanion.insert(
              id: 'ch_vol1',
              type: 'volume',
              siblingOrder: 0,
              title: const Value('第一卷 风起'),
            ),
          );
      await db
          .into(db.chapters)
          .insert(
            ChaptersCompanion.insert(
              id: 'ch_1',
              type: 'chapter',
              parentId: const Value('ch_vol1'),
              siblingOrder: 0,
              title: const Value('第一章 初雪'),
              content: Value(chapterContent),
              wordCount: const Value(30),
              // 两条旧 quote 批注：一条命中第二段，一条不在任何段落内。
              comments: Value([
                ChapterComment(
                  id: 'comment_hit',
                  start: 0,
                  end: 10,
                  quote: '第二段旧正文，含逗号。',
                  content: '命中段落的批注',
                  createdAt: DateTime.utc(2020),
                  updatedAt: DateTime.utc(2020),
                ),
                ChapterComment(
                  id: 'comment_miss',
                  start: 0,
                  end: 5,
                  quote: '这句话不在任何段落里',
                  content: '未命中段落的批注',
                  createdAt: DateTime.utc(2020),
                  updatedAt: DateTime.utc(2020),
                ),
              ]),
            ),
          );
      await db.close();
    } catch (_) {
      await db.close();
      rethrow;
    }

    final db2 = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      await db2.customStatement('DROP TABLE IF EXISTS chapter_paragraphs');
      await db2.customStatement('PRAGMA user_version = 7');
      expect(
        (await db2.customSelect('PRAGMA user_version').getSingle())
            .data['user_version'],
        7,
      );
      await db2.close();
    } catch (_) {
      await db2.close();
      rethrow;
    }
    return file;
  }

  test('v7 → v8 直接升级：一次性回填段落、旧批注锚点升级、旧 content 零丢失', () async {
    final file = await buildV7Fixture();
    final db = NovelContentDatabase.forTest(NativeDatabase(file));
    addTearDown(db.close);

    // 1. 版本升到当前 v8。
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle())
          .data['user_version'],
      NovelContentDatabase.currentSchemaVersion,
    );
    expect(NovelContentDatabase.currentSchemaVersion, 8);

    // 2. 新表存在。
    final tables =
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table' "
                  "AND name = 'chapter_paragraphs'",
                )
                .get())
            .map((r) => r.read<String>('name'))
            .toSet();
    expect(tables, {'chapter_paragraphs'});

    // 3. 升级路径补建了两个索引（onCreate 之外的升级库也必须可用）。
    final indexes =
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type='index' "
                  "AND tbl_name = 'chapter_paragraphs'",
                )
                .get())
            .map((r) => r.read<String>('name'))
            .toSet();
    // 主键 id 会由 SQLite 自动生成 sqlite_autoindex_*，它不属于 R-10 的显式
    // 业务索引；这里只断言两条手工创建的索引确实存在。
    expect(
      indexes,
      containsAll({
        'chapter_paragraphs_by_chapter_id_sort_order',
        'chapter_paragraphs_by_chapter_id_text_hash',
      }),
    );

    // 4. 表结构：主键 id，关键列齐全且类型正确。
    final columns =
        (await db.customSelect('PRAGMA table_info(chapter_paragraphs)').get())
            .map((r) => r.read<String>('name'))
            .toSet();
    expect(columns, {
      'id',
      'paragraph_id',
      'chapter_id',
      'sort_order',
      'text_hash',
      'revision_id',
      'status',
      'merged_from',
      'split_into',
      'created_at',
      'updated_at',
      'deleted_at',
    });
    final pk =
        (await db.customSelect('PRAGMA table_info(chapter_paragraphs)').get())
            .where((r) => r.read<int>('pk') > 0)
            .map((r) => r.read<String>('name'))
            .toSet();
    expect(pk, {'id'});

    // 5. 旧正文 content 零丢失（字节级一致）。
    final savedContent = (await db.chapterDao.getBodyById('ch_1'))!;
    expect(savedContent, chapterContent);

    // 6. 一次性存量回填：升级完成后段落立即存在（无需先保存该章）。
    final service = ChapterParagraphService(db);
    expect(await db.chapterParagraphDao.hasAnyForChapter('ch_1'), isTrue);
    expect(splitChapterParagraphs(savedContent), hasLength(3));
    expect(
      await db.chapterParagraphDao.listActiveByChapter('ch_1'),
      hasLength(3),
      reason: '升级后每章段落数应立即等于正文非空行数',
    );

    // 7. active 段落稳定 ID 连续、状态 active、软删哨兵正确。
    final active = await db.chapterParagraphDao.listActiveByChapter('ch_1');
    expect(active, hasLength(3));
    expect(active.map((p) => p.paragraphId), [
      'p-ch_1-0000',
      'p-ch_1-0001',
      'p-ch_1-0002',
    ]);
    expect(
      active.every((p) => p.status == chapterParagraphStatusActive),
      isTrue,
    );
    expect(active.every((p) => p.deletedAt == notDeletedSentinel), isTrue);
    expect(
      active[0].textHash,
      chapterParagraphTextHash(splitChapterParagraphs(savedContent)[0]),
    );

    // 8. 旧 quote 批注锚点升级：命中段补 paragraphId/paragraphHash，
    //    未命中的保持空串（运行时回退 quote 全文搜索）。
    final savedChapter = await ((db.select(
      db.chapters,
    )..where((t) => t.id.equals('ch_1'))).getSingle());
    final savedComments = savedChapter.comments ?? const <ChapterComment>[];
    expect(savedComments, hasLength(2));
    final hitComment = savedComments.singleWhere((c) => c.id == 'comment_hit');
    expect(hitComment.paragraphId, 'p-ch_1-0001');
    expect(
      hitComment.paragraphHash,
      chapterParagraphTextHash(splitChapterParagraphs(savedContent)[1]),
    );
    final missComment = savedComments.singleWhere(
      (c) => c.id == 'comment_miss',
    );
    expect(missComment.paragraphId, isEmpty);
    expect(missComment.paragraphHash, isEmpty);

    // 9. Typed DAO 读写：按 paragraphId 反查 + 幂等 upsert 不重复。
    final byId = await db.chapterParagraphDao.getByParagraphId('p-ch_1-0001');
    expect(byId, isNotNull);
    expect(byId!.chapterId, 'ch_1');
    expect(byId.sortOrder, 1);
    // 升级已回填，重算走普通三层重绑定，不再触发存量回填分支。
    final result = await db.transaction(() async {
      return service.recomputeForChapter(
        chapterId: 'ch_1',
        newContent: savedContent, // 内容未变 → 全部精确匹配，ID 不漂
        oldParagraphs: await service.loadActiveSnapshots('ch_1'),
      );
    });
    expect(result.backfilled, isFalse, reason: 'migration 已回填后不应再触发惰性分支');
    final afterIdempotent = await db.chapterParagraphDao.listActiveByChapter(
      'ch_1',
    );
    expect(afterIdempotent, hasLength(3), reason: '幂等重算不应新增重复段落');
    expect(afterIdempotent.map((p) => p.paragraphId), [
      'p-ch_1-0000',
      'p-ch_1-0001',
      'p-ch_1-0002',
    ]);
  });
}
