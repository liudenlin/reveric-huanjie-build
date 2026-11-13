// 职责: M4 ImpactAuditService 影响审计测试 — 变更 → 下游影响清单 + 证据 + 待复核。
// 关联文件:
//   lib/shared/services/impact_audit_service.dart
//   lib/shared/services/impact_audit_models.dart
//   lib/shared/services/novel_content.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（需求框架 M4）：改第 20 章与 AI 改正文都进 Ledger；
//   受影响章节自动列出附证据；下游标记待复核，不静默覆盖。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/impact_audit_models.dart';
import 'package:reveric/shared/services/impact_audit_service.dart';
import 'package:reveric/shared/services/novel_content.dart';

void main() {
  late NovelContentDatabase db;
  late NovelContentService content;
  late ImpactAuditService audit;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(db);
    audit = ImpactAuditService(content);
  });

  tearDown(() async => db.close());

  Future<void> insertCharacter({
    required String id,
    required String name,
    List<String> aliases = const [],
    String biography = '',
  }) async {
    await db.characterProfileDao.upsert(
      CharacterProfile(
        id: id,
        name: name,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        deletedAt: notDeletedSentinel,
        role: characterRoleSupporting,
        gender: characterGenderUnknown,
        aliases: aliases,
        tags: const [],
        biography: biography,
        appearance: '',
        description: '',
        currentState: '',
        identity: '',
        age: '未知',
        motivation: '',
        arc: '',
        personality: '',
        behaviorTags: const [],
        sortOrder: 0,
      ),
    );
  }

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

  Future<void> insertForeshadowing({
    required String id,
    required String title,
    required String setup,
  }) async {
    await db.foreshadowingDao.upsert(
      Foreshadowing(
        id: id,
        title: title,
        setup: setup,
        payoff: '',
        status: foreshadowingStatusPending,
        sortOrder: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        deletedAt: notDeletedSentinel,
      ),
    );
  }

  test('改人物名 → 下游章节/伏笔/关系全部命中并带证据', () async {
    // 变更对象：林晚（老名）→ 林晚晴（新名）。
    await insertCharacter(id: 'c_hero', name: '林晚', aliases: ['晚晚']);

    // 下游第 5/20 章正文提及旧名。
    await insertChapter(id: 'ch_5', title: '第五章 初见', content: '林晚在雨中站了很久。');
    await insertChapter(id: 'ch_20', title: '第二十章 决战', content: '晚晚的剑断了。');
    // 无关章节不应命中。
    await insertChapter(id: 'ch_3', title: '第三章 山村', content: '老人抽着旱烟。');

    // 伏笔 setup 提及。
    await insertForeshadowing(id: 'fsh_1', title: '泪痣伏笔', setup: '林晚左眼的泪痣预示……');

    final result = await audit.audit(
      const ImpactAuditRequest(
        resourcePath: 'characters/c_hero',
        resourceType: 'characters',
        resourceId: 'c_hero',
        field: 'name',
        oldText: '林晚',
        newText: '林晚晴',
        source: 'ai',
      ),
    );

    // 章节命中：ch_5 词面 + ch_20 别名，无 ch_3。
    final chapterIds = result.affectedChapters.map((h) => h.resourceId).toSet();
    expect(chapterIds, {'ch_5', 'ch_20'});

    // 证据包含原文片段。
    final ch5 = result.affectedChapters.firstWhere((h) => h.resourceId == 'ch_5');
    expect(ch5.evidence, contains('林晚'));
    expect(ch5.confidence, 1.0);
    expect(ch5.context, contains('林晚'));
    // 命中变更对象自身名 → DIRECT，不臆测分档。
    expect(ch5.severity, ImpactSeverity.direct);

    // 伏笔命中。
    expect(result.affectedForeshadowings.length, 1);
    expect(result.affectedForeshadowings.first.resourceId, 'fsh_1');

    // 覆盖统计：已扫对象数 <= 相关对象总数，coverage 有文案。
    expect(result.checkedCount, greaterThan(0));
    expect(result.totalRelevantCount, greaterThanOrEqualTo(result.checkedCount));
    expect(result.coverage, contains('已检查'));
    // 未全覆盖时不能视为已通过。
    expect(result.hasUnchecked, isFalse);

    // 汇总非空。
    expect(result.summary, contains('下游影响'));
  });

  test('改动无下游引用 → 空清单', () async {
    await insertChapter(id: 'ch_1', title: '第一章', content: '一只猫走过屋檐。');

    final result = await audit.audit(
      const ImpactAuditRequest(
        resourcePath: 'characters/c_x',
        resourceType: 'characters',
        resourceId: 'c_x',
        oldText: '张三丰',
        newText: '张君宝',
        source: 'manual_edit',
      ),
    );

    expect(result.isEmpty, isTrue);
    expect(result.summary, contains('未发现下游引用'));
    // 结果级档位：无命中 → NONE，默认建议为「暂缓/不处理」。
    expect(result.overallSeverity, ImpactSeverity.none);
    expect(result.recommendedAction, defaultActionForSeverity(ImpactSeverity.none));
  });

  test('改正文 → 提到相同人物的下游章节命中（不留自己）', () async {
    await insertCharacter(id: 'c_b', name: '沈砚');
    await insertChapter(id: 'ch_1', title: '第一章', content: '沈砚推门而入。');
    await insertChapter(id: 'ch_2', title: '第二章', content: '沈砚拔剑，剑光如雪。');

    // 改 ch_1 正文：沈砚 → 沈砚之（名字变更不影响 ch_2 引用沈砚）。
    final result = await audit.audit(
      ImpactAuditRequest(
        resourcePath: 'chapters/ch_1',
        resourceType: 'chapters',
        resourceId: 'ch_1',
        field: 'content',
        oldText: '沈砚推门而入。',
        newText: '沈砚之推门而入。',
        source: 'ai',
      ),
    );

    // ch_1 自身不算下游；ch_2 提及沈砚（变更词的一部分）命中。
    final all = result.affectedChapters;
    expect(all.any((h) => h.resourceId == 'ch_1'), isFalse,
        reason: '不应把变更对象本身算作下游');
    expect(all.any((h) => h.resourceId == 'ch_2'), isTrue);
  });

  test('extractEntityTerms：提取中文名/英文词/引号短语，过滤噪声词', () {
    final terms = audit.extractEntityTerms(
      const ImpactAuditRequest(
        resourcePath: 'characters/c_x',
        resourceType: 'characters',
        resourceId: 'c_x',
        field: 'biography',
        oldText: '',
        newText: '林晚是沈砚的青梅竹马，外号"晚晚"，人称 Nightfall。',
        source: 'ai',
      ),
    );

    expect(terms, contains('林晚'));
    expect(terms, contains('沈砚'));
    expect(terms, contains('青梅竹马'));
    expect(terms, contains('晚晚'));
    expect(terms, contains('Nightfall'));
    // 噪声词被过滤。
    expect(terms.any((t) => t == '是' || t == '一个' || t == '因为'), isFalse);
  });

  test('entityNamesForChange：从变更对象档案补充名称/别名', () async {
    await insertCharacter(id: 'c_hero', name: '林晚', aliases: ['晚晚', '暮色']);

    final names = await audit.entityNamesForChange(
      const ImpactAuditRequest(
        resourcePath: 'characters/c_hero',
        resourceType: 'characters',
        resourceId: 'c_hero',
        field: 'biography',
        oldText: '',
        newText: '她来自临安。',
        source: 'ai',
      ),
    );

    expect(names, containsAll(['林晚', '晚晚', '暮色']));
  });

  test('改伏笔 → 提及其标题的下游章节命中', () async {
    await insertForeshadowing(id: 'fsh_old', title: '断剑重铸', setup: '旧设定');
    await insertChapter(id: 'ch_9', title: '第九章', content: '断剑重铸之日，骑士归来之时。');

    final result = await audit.audit(
      ImpactAuditRequest(
        resourcePath: 'foreshadowing/fsh_old',
        resourceType: 'foreshadowing',
        resourceId: 'fsh_old',
        field: 'setup',
        oldText: '旧设定',
        newText: '新设定：断剑失而复得。',
        source: 'ai',
      ),
    );

    expect(result.affectedChapters.any((h) => h.resourceId == 'ch_9'), isTrue);
  });

  test('ImpactAuditResult JSON roundtrip：服务输出 → 反序列化还原', () {
    final original = ImpactAuditResult(
      request: ImpactAuditRequest(
        resourcePath: 'chapters/ch_20',
        resourceType: 'chapter',
        resourceId: 'ch_20',
        field: 'content',
        oldText: '旧正文',
        newText: '新正文',
      ),
      affectedChapters: const [
        ImpactHit(
          resourceType: 'chapter',
          resourceId: 'ch_21',
          title: '第二十一章',
          evidence: '沈砚登场',
          context: '第 21 章正文',
          confidence: 1.0,
          severity: ImpactSeverity.direct,
          reviewPending: true,
        ),
      ],
      affectedForeshadowings: const [],
      affectedRelations: const [],
      affectedCharacters: const [],
      summary: '1 处下游命中',
      coverage: '已检查 10 / 10 个对象',
      checkedCount: 10,
      totalRelevantCount: 10,
    );

    final restored = ImpactAuditResult.fromJson(original.toJson());

    expect(restored.request.resourcePath, 'chapters/ch_20');
    expect(restored.request.resourceId, 'ch_20');
    expect(restored.affectedChapters, hasLength(1));
    final hit = restored.affectedChapters.first;
    expect(hit.resourceId, 'ch_21');
    expect(hit.evidence, '沈砚登场');
    expect(hit.confidence, 1.0);
    expect(hit.severity, ImpactSeverity.direct);
    expect(hit.reviewPending, isTrue);
    expect(restored.totalHitCount, 1);
    expect(restored.summary, '1 处下游命中');
    // 覆盖字段 roundtrip。
    expect(restored.coverage, '已检查 10 / 10 个对象');
    expect(restored.checkedCount, 10);
    expect(restored.totalRelevantCount, 10);
    expect(restored.hasUnchecked, isFalse);
  });

  test('ImpactAuditResult.fromJson 容错：缺失字段 / 坏 JSON 不抛异常', () {
    final empty = ImpactAuditResult.fromJson(const {});
    expect(empty.request.resourcePath, '');
    expect(empty.totalHitCount, 0);
    // 旧审计记录无覆盖字段 → 安全默认 0，不崩。
    expect(empty.checkedCount, 0);
    expect(empty.totalRelevantCount, 0);
    expect(empty.coverage, '');
    expect(empty.hasUnchecked, isFalse);

    final partial = ImpactAuditResult.fromJson({
      'request': {'resourcePath': 'characters/cha_1', 'resourceType': 'character'},
      'affectedForeshadowings': [
        {'resourceType': 'foreshadowing', 'resourceId': 'fsh_1', 'title': '断剑'},
      ],
    });
    expect(partial.request.resourcePath, 'characters/cha_1');
    expect(partial.affectedForeshadowings, hasLength(1));
    expect(partial.affectedForeshadowings.first.confidence, 0.0);
    // 命中缺 severity → 安全默认 UNKNOWN（禁止无依据猜测）。
    expect(partial.affectedForeshadowings.first.severity, ImpactSeverity.unknown);
    expect(partial.overallSeverity, ImpactSeverity.unknown);
  });

  test('三维分档：变更对象名 DIRECT / 变更文本词 HIGH / 全库他人名 MEDIUM', () async {
    // 变更对象：林晚（改传记文本「剑客 → 刀客」）。
    await insertCharacter(id: 'c_hero', name: '林晚');
    // 全库其他人物：沈砚（仅出现在下游章节中，即间接引用）。
    await insertCharacter(id: 'c_other', name: '沈砚');

    // DIRECT：正文直接出现变更对象名。
    await insertChapter(id: 'ch_direct', title: '第 D 章', content: '林晚登场。');
    // HIGH：正文出现变更文本中的新关键词。
    await insertChapter(id: 'ch_high', title: '第 H 章', content: '刀客登场。');
    // MEDIUM：正文出现全库其他人物名。
    await insertChapter(id: 'ch_medium', title: '第 M 章', content: '沈砚登场。');

    final result = await audit.audit(
      const ImpactAuditRequest(
        resourcePath: 'characters/c_hero',
        resourceType: 'characters',
        resourceId: 'c_hero',
        field: 'biography',
        oldText: '剑客',
        newText: '刀客',
        source: 'ai',
      ),
    );

    ImpactHit hitOf(String id) =>
        result.affectedChapters.firstWhere((h) => h.resourceId == id);
    expect(hitOf('ch_direct').severity, ImpactSeverity.direct);
    expect(hitOf('ch_direct').confidence, 1.0);
    expect(hitOf('ch_high').severity, ImpactSeverity.high);
    expect(hitOf('ch_high').confidence, 1.0);
    expect(hitOf('ch_medium').severity, ImpactSeverity.medium);
    expect(hitOf('ch_medium').confidence, 0.6);
    // 结果级取最高档。
    expect(result.overallSeverity, ImpactSeverity.direct);
  });

  test('defaultActionForSeverity：每档文案非空，未知档回退重跑审计', () {
    for (final severity in const [
      ImpactSeverity.direct,
      ImpactSeverity.high,
      ImpactSeverity.medium,
      ImpactSeverity.low,
      ImpactSeverity.none,
      ImpactSeverity.unknown,
    ]) {
      expect(defaultActionForSeverity(severity), isNotEmpty,
          reason: '$severity 应有默认建议');
    }
    expect(defaultActionForSeverity('GARBAGE'), contains('重跑审计'));
  });
}