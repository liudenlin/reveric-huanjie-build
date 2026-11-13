// 职责: M4 手动编辑 → Change Ledger → 影响审计 集成测试。
// 验收（需求框架 M4）：手动改第 20 章与 AI 改正文都进 Ledger；
//   受影响章节自动列出附证据；下游标记待复核，不静默覆盖。
// 关联文件:
//   lib/shared/services/working_overlay.dart (commitManualSave → 审计钩子)
//   lib/shared/services/impact_audit_service.dart
//   lib/shared/database/novel_content_daos/impact_audit_dao.dart

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late NovelContentDatabase db;
  late AppDatabase appDb;
  late NovelContentService contentService;
  late WorkingOverlayService service;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    contentService = NovelContentService(db);
    final actionsService = NovelActionsService(appDb);
    service = WorkingOverlayService(
      db,
      contentService,
      novelActionsService: actionsService,
    );
  });

  tearDown(() async {
    await db.close();
    await appDb.close();
  });

  Future<void> insertChapter({
    required String id,
    required String title,
    required String content,
  }) async {
    await db.into(db.chapters).insert(
      ChaptersCompanion.insert(
        id: id,
        type: 'chapter',
        parentId: const Value(null),
        siblingOrder: 0,
        title: Value(title),
        content: Value(content),
      ),
    );
  }

  test('手动改第 20 章 → 保存 → 影响审计落库（下游章节待复核）', () async {
    // 上游：第 19 章改动提及人物「沈砚」（改前含，改后去掉）。
    await insertChapter(
      id: 'ch_19',
      title: '第十九章',
      content: '沈砚登场。',
    );
    // 下游：第 20 章仍提及沈砚（受影响）。
    await insertChapter(
      id: 'ch_20',
      title: '第二十章',
      content: '沈砚与林晚的对峙一触即发。',
    );

    // 手动改 ch_19 正文：改前含沈砚，改后不含。
    final change = await service.stageTextChange(
      resourcePath: '/chapters/ch_19/content',
      resourceType: 'chapters',
      resourceId: 'ch_19',
      field: 'content',
      oldText: '沈砚登场。',
      newText: '主角登场。',
      source: workingChangeSourceManual,
      summary: '手动删掉沈砚的出场',
    );

    await service.commitManualSave(
      manualChangeIds: [change.id],
      resourceScopes: const ['/chapters/ch_19'],
      manualMessage: '测试手动保存第19章',
    );

    // 影响审计已落库：changeId 对应，状态 recorded（有下游命中）。
    final auditRow = await db.impactAuditDao.getByChangeId(change.id);
    expect(auditRow, isNotNull, reason: '手动保存应触发影响审计落库');
    expect(auditRow!.status, impactAuditStatusRecorded);
    expect(auditRow.hitCount, greaterThan(0));

    // 命中对象包含下游 ch_20（提及沈砚）。
    expect(auditRow.resultJson, contains('ch_20'));

    // 待复核聚合：ch_19 资源有待复核审计。
    expect(
      await db.impactAuditDao.hasPendingReview('/chapters/ch_19/content'),
      isTrue,
    );
  });

  test('手动改无下游引用的内容 → 审计 status=none', () async {
    await insertChapter(id: 'ch_1', title: '第一章', content: '一只猫走过。');

    final change = await service.stageTextChange(
      resourcePath: '/chapters/ch_1/content',
      resourceType: 'chapters',
      resourceId: 'ch_1',
      field: 'content',
      oldText: '一只猫走过。',
      newText: '一只狗走过。',
      source: workingChangeSourceManual,
      summary: '无关改动',
    );

    await service.commitManualSave(
      manualChangeIds: [change.id],
      resourceScopes: const ['/chapters/ch_1'],
      manualMessage: '测试无影响保存',
    );

    final auditRow = await db.impactAuditDao.getByChangeId(change.id);
    expect(auditRow, isNotNull);
    expect(auditRow!.status, impactAuditStatusNone);
  });
}