// 职责: M6d Context Packet 测试 — §7.5 十二字段动态组装 + 模型渲染/审计。
// 关联文件:
//   lib/shared/services/ai/context_packet.dart (模型)
//   lib/shared/services/ai/context_packet_builder.dart (组装器)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（专项设计 §7.5）：任务/当前对象/正典/编年史/角色认知/读者认知/
//   大纲/证据/锁/风格/冲突/策略 动态组装；每字段带 sourceRevision；
//   空字段跳过；检索结果二次过可见性过滤器。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/outline_draft.dart'
    show outlineStatusPending;
import 'package:reveric/shared/services/ai/context_packet.dart';
import 'package:reveric/shared/services/ai/context_packet_builder.dart';
import 'package:reveric/shared/services/content_lock_service.dart';
import 'package:reveric/shared/services/embedding/embedding_search_service.dart';

/// 确定性向量化器（与 M6a 测试一致）。
class _FakeVectorizer implements EmbeddingVectorizer {
  _FakeVectorizer(this.modelId);
  @override
  final String modelId;
  @override
  Future<List<double>> embed(String text) async {
    final v = List<double>.filled(8, 0);
    for (final c in text.codeUnits) {
      v[c % 8] += 1;
    }
    return v;
  }
}

/// 只放行指定 sourceId 的过滤器（验证可见性过滤生效）。
class _SelectiveFilter implements ContextVisibilityFilter {
  const _SelectiveFilter(this.allowedIds);
  final Set<String> allowedIds;
  @override
  bool isAllowed({
    required String sourceType,
    required String sourceId,
    required String anchor,
  }) => allowedIds.contains(sourceId);
}

void main() {
  late NovelContentDatabase db;
  late ContextPacketBuilder builder;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    builder = ContextPacketBuilder(
      db,
      embedding: EmbeddingSearchService(
        dao: db.embeddingDocumentDao,
        vectorizer: _FakeVectorizer('fake-8d'),
      ),
    );
  });

  tearDown(() async => db.close());

  Future<void> insertChapter({
    String id = 'ch_1',
    int order = 1,
    String title = '夜袭',
    String content = '',
    String outline = '',
    String brief = '',
    String type = nodeTypeChapter,
    int chapterNum = 1,
  }) async {
    await db.chapterDao.upsert(
      ChapterData(
        id: id,
        type: type,
        parentId: null,
        siblingOrder: order,
        title: title,
        outline: outline,
        brief: brief,
        content: content,
        wordCount: content.length,
        stat: chapterStatDraft,
        embeddingSyncStatus: chapterEmbeddingSyncStatusPending,
        embeddingSyncedAt: null,
        embeddingSyncModelId: null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        deletedAt: notDeletedSentinel,
      ),
    );
  }

  Future<void> insertCharacter({
    String id = 'c_hero',
    String name = '林晚',
    String role = 'protagonist',
    String currentState = '已入内城',
  }) async {
    await db.characterProfileDao.upsert(
      CharacterProfile(
        id: id,
        name: name,
        role: role,
        gender: 'female',
        aliases: const [],
        tags: const [],
        biography: '自幼习剑，背负复仇。',
        appearance: '',
        description: '',
        currentState: currentState,
        identity: '',
        age: '18',
        motivation: '复仇',
        arc: '',
        personality: '坚韧',
        behaviorTags: const [],
        sortOrder: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        deletedAt: notDeletedSentinel,
      ),
    );
  }

  Future<void> insertCanon({
    String id = 'canon_1',
    String resourceId = 'star_core',
    String level = canonLevelCanon,
    String title = '星核设定',
    String fact = '星核藏于内城祭坛。',
  }) async {
    await db.canonEntryDao.upsert(
      CanonEntriesCompanion.insert(
        id: id,
        resourceType: 'world',
        resourceId: resourceId,
        level: level,
        title: Value(title),
        source: 'council',
        fact: Value(fact),
      ),
    );
  }

  group('ContextPacket 模型', () {
    test('空包 isEmpty 且 toPromptText 为空串', () {
      final packet = ContextPacket(fields: const []);
      expect(packet.isEmpty, isTrue);
      expect(packet.toPromptText(), isEmpty);
    });

    test('按固定顺序渲染 12 字段，空字段跳过', () {
      final packet = ContextPacket(
        fields: [
          const ContextPacketField(
            key: 'policy',
            content: '策略内容',
            sourceRevision: 'policy:default',
          ),
          const ContextPacketField(
            key: 'task',
            content: '写第 21 章',
            sourceRevision: 'request',
          ),
          // currentObject / canon … 缺省 → 自动补空
        ],
      );
      final text = packet.toPromptText();
      expect(text, contains('# 任务目标与审批模式'));
      expect(text, contains('写第 21 章'));
      expect(text, contains('# 模型/权限/token 预算/禁止工具'));
      // 空字段不渲染
      expect(text, isNot(contains('# 相关正典、设定与人物状态')));
      // 顺序：task 在 policy 前
      expect(text.indexOf('任务目标'), lessThan(text.indexOf('模型/权限')));
    });

    test('packetRevision 组合字段 sourceRevision 与 approvalMode', () {
      final packet = ContextPacket(
        fields: const [
          ContextPacketField(
            key: 'task',
            content: 'x',
            sourceRevision: 'request',
          ),
          ContextPacketField(
            key: 'canon',
            content: 'y',
            sourceRevision: 'canon:a,b@2',
          ),
        ],
        approvalMode: 'user_confirm',
      );
      expect(packet.packetRevision, contains('user_confirm'));
      expect(packet.packetRevision, contains('task=request'));
      expect(packet.packetRevision, contains('canon=canon:a,b@2'));
      expect(packet.sourceRevisions, hasLength(2));
    });

    test('toJson 审计序列化含字段与修订', () {
      final packet = ContextPacket(
        fields: const [
          ContextPacketField(
            key: 'task',
            content: '任务',
            sourceRevision: 'request',
          ),
        ],
      );
      final json = packet.toJson();
      expect(json['packetRevision'], isNotEmpty);
      expect(json['fields'], isA<Map<String, dynamic>>());
      expect((json['fields'] as Map)['task']['sourceRevision'], 'request');
    });
  });

  group('ContextPacketBuilder', () {
    test('空库构建：task 有值、其余空、isEmpty false', () async {
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '起草第 1 章'),
      );
      expect(packet.task, contains('起草第 1 章'));
      expect(packet.currentObject, isEmpty);
      expect(packet.canon, isEmpty);
      expect(packet.chronology, isEmpty);
      expect(packet.evidence, isEmpty);
      expect(packet.conflicts, isEmpty);
      expect(packet.isEmpty, isFalse); // task 恒有值
    });

    test('currentObject=chapter 读取正文、版本与来源修订', () async {
      await insertChapter(
        id: 'ch_21',
        title: '夜袭',
        content: '沈雁缓缓推开门，烛火晃动。他低声说：该动手了。',
        outline: '潜入内城，夺星核。',
        brief: '沈雁潜入内城，发现星核被封印。',
        chapterNum: 21,
      );
      final packet = await builder.build(
        const ContextPacketBuildRequest(
          task: '续写',
          currentObjectType: 'chapter',
          currentObjectId: 'ch_21',
        ),
      );
      expect(packet.currentObject, contains('章节'));
      expect(packet.currentObject, contains('夜袭'));
      expect(packet.currentObject, contains('21'));
      expect(packet.currentObject, contains('潜入内城'));
      expect(packet.currentObject, contains('正文预览'));
      expect(
        packet.sourceRevisions['currentObject'],
        startsWith('chapter:ch_21@'),
      );
    });

    test('currentObject=character 读取人物当前状态', () async {
      await insertCharacter(id: 'c_hero', name: '林晚', currentState: '已入内城');
      final packet = await builder.build(
        const ContextPacketBuildRequest(
          task: '人物对话',
          currentObjectType: 'character',
          currentObjectId: 'c_hero',
        ),
      );
      expect(packet.currentObject, contains('林晚'));
      expect(packet.currentObject, contains('已入内城'));
      expect(packet.sourceRevisions['currentObject'], 'character:c_hero');
    });

    test('canon 只取 canon/proposal 层级并带修订', () async {
      await insertCanon(
        id: 'c1',
        resourceId: 'star_core',
        level: canonLevelCanon,
        title: '星核设定',
        fact: '星核藏于祭坛。',
      );
      await insertCanon(
        id: 'c2',
        resourceId: 'council_note',
        level: canonLevelDiscussion,
        title: '讨论稿',
        fact: '未定。',
      );
      await insertCanon(
        id: 'c3',
        resourceId: 'proposal_note',
        level: canonLevelProposal,
        title: '提案稿',
        fact: '提案内容。',
      );
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '设定核对'),
      );
      expect(packet.canon, contains('星核设定'));
      expect(packet.canon, contains('提案稿'));
      expect(packet.canon, isNot(contains('讨论稿')));
      expect(packet.sourceRevisions['canon'], startsWith('canon:'));
    });

    test('chronology 列出正文章节并按阅读顺序，跳过卷节点', () async {
      await insertChapter(
        id: 'v1',
        title: '第一卷',
        order: 1,
        type: nodeTypeVolume,
        chapterNum: 0,
      );
      await insertChapter(id: 'ch_1', title: '初见', order: 2, chapterNum: 1);
      await insertChapter(id: 'ch_2', title: '别离', order: 3, chapterNum: 2);
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '写第 3 章'),
      );
      expect(packet.chronology, contains('初见'));
      expect(packet.chronology, contains('别离'));
      expect(packet.chronology, isNot(contains('第一卷')));
    });

    test('characterKnowledge / readerKnowledge 按主体组装', () async {
      await insertCharacter(id: 'c_hero', name: '林晚');
      await db.readerPerspectiveDao.upsert(
        ReaderPerspectivesCompanion.insert(
          id: 'rp1',
          factId: 'f_star',
          subject: 'character:c_hero',
          state: const Value(readerPerspectiveStateAware),
          storyTime: const Value('卷2第5章'),
          evidence: const Value('ch_5: 林晚得知星核位置'),
        ),
      );
      await db.readerPerspectiveDao.upsert(
        ReaderPerspectivesCompanion.insert(
          id: 'rp2',
          factId: 'f_star',
          subject: 'reader',
          state: const Value(readerPerspectiveStateMisled),
          disclosureAnchor: const Value('ch_12'),
          note: const Value('读者被误导'),
        ),
      );
      final packet = await builder.build(
        const ContextPacketBuildRequest(
          task: '续写',
          currentObjectType: 'character',
          currentObjectId: 'c_hero',
        ),
      );
      expect(packet.characterKnowledge, contains('知晓'));
      expect(packet.characterKnowledge, contains('卷2第5章'));
      expect(packet.readerKnowledge, contains('被误导'));
      expect(packet.readerKnowledge, contains('ch_12'));
    });

    test('outline 列出总纲/卷纲及 beat', () async {
      await db.outlineDao.insertOutline(
        Outline(
          documentId: 'out_1',
          title: '第一卷纲要',
          content: '夺星核篇',
          status: outlineStatusPending,
          startChapterNum: 1,
          sortOrder: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          deletedAt: notDeletedSentinel,
        ),
      );
      await db.outlineDao.insertBeat(
        OutlineBeat(
          id: 'beat_1',
          outlineDocumentId: 'out_1',
          title: '潜入内城',
          content: '沈雁潜入。',
          status: outlineStatusPending,
          chapterCount: 1,
          sortOrder: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          deletedAt: notDeletedSentinel,
        ),
      );
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '写作'),
      );
      expect(packet.outline, contains('第一卷纲要'));
      expect(packet.outline, contains('潜入内城'));
    });

    test('evidence 走语义检索并过可见性过滤器（只放行 ch_21）', () async {
      await insertChapter(
        id: 'ch_21',
        content: '沈雁缓缓推开门，烛火晃动。他低声说：该动手了。',
        title: '夜袭',
      );
      await insertChapter(id: 'ch_22', content: '另一章提到吊坠的来历。', title: '后续');
      // 建索引（builder 的 embedding 与测试共用同一 dao）
      final service = EmbeddingSearchService(
        dao: db.embeddingDocumentDao,
        vectorizer: _FakeVectorizer('fake-8d'),
      );
      await service.indexSource(
        EmbeddingIndexRequest(
          sourceType: 'chapter',
          sourceId: 'ch_21',
          path: 'chapters/ch_21',
          title: '夜袭',
          content: '沈雁缓缓推开门，烛火晃动。他低声说：该动手了。',
          projectId: 'proj_1',
          revisionHash: 'rev-21',
        ),
      );
      await service.indexSource(
        EmbeddingIndexRequest(
          sourceType: 'chapter',
          sourceId: 'ch_22',
          path: 'chapters/ch_22',
          title: '后续',
          content: '另一章提到吊坠的来历。',
          projectId: 'proj_1',
          revisionHash: 'rev-22',
        ),
      );

      // 全放行
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '查吊坠', evidenceQuery: '吊坠来历'),
      );
      expect(packet.evidence, isNotEmpty);
      expect(packet.evidence, contains('score'));

      // 选择性过滤：只放行 ch_21
      final selective = ContextPacketBuilder(
        db,
        embedding: EmbeddingSearchService(
          dao: db.embeddingDocumentDao,
          vectorizer: _FakeVectorizer('fake-8d'),
        ),
        visibilityFilter: const _SelectiveFilter({'ch_21'}),
      );
      final filtered = await selective.build(
        const ContextPacketBuildRequest(task: '查吊坠', evidenceQuery: '吊坠来历'),
      );
      // 过滤后 ch_22 被排除（若全部被过滤则 evidence 为空）
      expect(filtered.evidence, isNot(contains('chapters/ch_22')));
    });

    test('locks 列出生效锁', () async {
      final locks = ContentLockService(db);
      await locks.addLock(
        scope: lockScopeObject,
        resourceType: 'chapter',
        resourceId: 'ch_21',
        reason: '定稿冻结',
      );
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '改稿'),
      );
      expect(packet.locks, contains('ch_21'));
      expect(packet.locks, contains('定稿冻结'));
    });

    test('style 列出启用的写作规则', () async {
      await db.agentRuleDao.upsert(
        AgentRule(
          id: 'rule_1',
          name: '文风',
          content: '短句、留白，少用成语。',
          enabled: true,
          sortOrder: 0,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          deletedAt: notDeletedSentinel,
        ),
      );
      await db.agentRuleDao.upsert(
        AgentRule(
          id: 'rule_2',
          name: '禁用',
          content: '禁用视角切换。',
          enabled: false,
          sortOrder: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          deletedAt: notDeletedSentinel,
        ),
      );
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '写作'),
      );
      expect(packet.style, contains('文风'));
      expect(packet.style, contains('短句'));
      expect(packet.style, isNot(contains('禁用')));
    });

    test('conflicts 列出待复核审计发现', () async {
      await db.impactAuditDao.upsert(
        ImpactAuditsCompanion.insert(
          id: 'aud_1',
          changeId: 'wc_1',
          resourcePath: 'chapters/ch_20',
          resourceType: 'chapter',
          resourceId: 'ch_20',
          resultJson: '{"summary":"沈雁提及 2 处"}',
          status: const Value(impactAuditStatusRecorded),
          hitCount: const Value(2),
        ),
      );
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '改稿'),
      );
      expect(packet.conflicts, contains('chapters/ch_20'));
      expect(packet.conflicts, contains('2'));
    });

    test('policy 提供写入边界声明', () async {
      final packet = await builder.build(
        const ContextPacketBuildRequest(task: '写作'),
      );
      expect(packet.policy, contains('WorkingChange'));
      expect(packet.policy, contains('影响审计'));
    });

    test('approvalMode 进入 task 与 packetRevision', () async {
      final packet = await builder.build(
        const ContextPacketBuildRequest(
          task: '定稿',
          approvalMode: 'author_only',
        ),
      );
      expect(packet.task, contains('仅作者可写入'));
      expect(packet.packetRevision, contains('author_only'));
    });
  });
}
