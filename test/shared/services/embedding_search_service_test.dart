// 职责: M6a 语义检索服务测试 — 分块索引、幂等覆盖、关键词/向量混合检索、
//       降级路径、stale/失效/清空。
// 关联文件:
//   lib/shared/services/embedding/embedding_search_service.dart
//   lib/shared/database/novel_content_daos/embedding_document_dao.dart
//   lib/shared/database/novel_content_database.dart (AiEmbeddingDocuments 表)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（专项设计 §8）：正文/设定分块入索引 → 混合检索可定位原文证据与跳转锚点；
//   内容未变化不重算向量；对象删除级联失效；模型版本变更标 stale；
//   支持「清空—重建—一致性测试」。

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/embedding/embedding_search_service.dart';

class _FakeVectorizer implements EmbeddingVectorizer {
  _FakeVectorizer(this.modelId);
  @override
  final String modelId;
  @override
  Future<List<double>> embed(String text) async {
    // 简单确定性向量：以字符哈希生成 8 维向量，维度一致可比较。
    final v = List<double>.filled(8, 0);
    for (final c in text.codeUnits) {
      v[c % 8] += 1;
    }
    return v;
  }
}

void main() {
  late NovelContentDatabase db;
  late EmbeddingSearchService service;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = EmbeddingSearchService(
      dao: db.embeddingDocumentDao,
      vectorizer: _FakeVectorizer('fake-8d'),
    );
  });

  tearDown(() async => db.close());

  Future<void> indexChapter({
    String id = 'ch_1',
    String content = '',
    String title = '',
    String path = 'chapters/ch_1',
    String revisionHash = 'rev-1',
  }) async {
    await service.indexSource(
      EmbeddingIndexRequest(
        sourceType: 'chapter',
        sourceId: id,
        path: path,
        title: title,
        content: content,
        projectId: 'proj_1',
        revisionHash: revisionHash,
      ),
    );
  }

  test('indexSource: 长文本按大小+重叠切块，写入多条', () async {
    final longText = List.generate(20, (i) => '第$i段 林晚走进客栈，要了一壶酒。').join('\n');
    final changed = await service.indexSource(
      EmbeddingIndexRequest(
        sourceType: 'chapter',
        sourceId: 'ch_1',
        path: 'chapters/ch_1',
        title: '第一章',
        content: longText,
        projectId: 'proj_1',
        revisionHash: 'rev-1',
        chunkSizeChars: 100,
        chunkOverlapChars: 10,
      ),
    );
    expect(changed, greaterThan(1));
    final chunks = await db.embeddingDocumentDao.listBySource(
      sourceType: 'chapter',
      sourceId: 'ch_1',
    );
    expect(chunks.length, changed);
    // 每块都带索引不变量（§8.4）。
    for (final c in chunks) {
      expect(c.metadata, isNotNull);
      expect(c.metadata!['projectId'], 'proj_1');
      expect(c.metadata!['objectId'], 'ch_1');
      expect(c.metadata!['revisionHash'], 'rev-1');
      expect(c.metadata!['indexSchemaVersion'], embeddingIndexSchemaVersion);
      expect(c.metadata!['sourceAnchor'], contains('#chunk-'));
    }
  });

  test('upsertChunk 幂等: 相同内容不重算（返回 0），修改内容才重算', () async {
    await indexChapter(content: '林晚捡起地上的吊坠，上面刻着奇怪的符文。', revisionHash: 'rev-1');
    final again = await service.indexSource(
      EmbeddingIndexRequest(
        sourceType: 'chapter',
        sourceId: 'ch_1',
        path: 'chapters/ch_1',
        title: '第一章',
        content: '林晚捡起地上的吊坠，上面刻着奇怪的符文。',
        projectId: 'proj_1',
        revisionHash: 'rev-1',
      ),
    );
    expect(again, 0); // 内容未变化，不重算向量。

    final changed = await service.indexSource(
      EmbeddingIndexRequest(
        sourceType: 'chapter',
        sourceId: 'ch_1',
        path: 'chapters/ch_1',
        title: '第一章',
        content: '林晚捡起吊坠，发现上面有血迹。',
        projectId: 'proj_1',
        revisionHash: 'rev-2',
      ),
    );
    expect(changed, 1); // 内容变化，重算。
  });

  test('search 混合检索: 命中含证据 + 跳转锚点，向量与关键词双路径', () async {
    await indexChapter(
      id: 'ch_21',
      content: '沈雁缓缓推开门，屋里的烛火晃动了一下。他低声说：该动手了。',
      title: '第 21 章 夜袭',
      path: 'chapters/ch_21',
    );
    await indexChapter(
      id: 'ch_30',
      content: '林晚在集市上买了一把匕首，摊主是个独眼老人。',
      title: '第 30 章 集市',
      path: 'chapters/ch_30',
    );

    final hits = await service.search(query: '烛火', limit: 5);
    expect(hits, isNotEmpty);
    final top = hits.first;
    expect(top.sourceId, 'ch_21');
    expect(top.content, contains('烛火'));
    expect(top.revisionHash, 'rev-1');
    expect(top.sourceAnchor, contains('#chunk-'));
    expect(top.path, 'chapters/ch_21');

    // 无向量降级（未配置 vectorizer 时）也能命中关键词。
    final kwOnly = EmbeddingSearchService(dao: db.embeddingDocumentDao);
    final kwHits = await kwOnly.search(query: '匕首', limit: 5);
    expect(kwHits, isNotEmpty);
    expect(kwHits.first.sourceId, 'ch_30');
  });

  test('检索结果按混合得分降序，limit 生效', () async {
    for (var i = 0; i < 8; i++) {
      await indexChapter(
        id: 'ch_$i',
        content: '第$i段 林晚$i次路过那条街。',
        title: '第$i章',
        path: 'chapters/ch_$i',
      );
    }
    await indexChapter(
      id: 'ch_9',
      content: '林晚第九次路过那条街，街角站着个黑衣人。',
      title: '第9章',
      path: 'chapters/ch_9',
    );
    final hits = await service.search(query: '林晚 街角', limit: 3);
    expect(hits.length, lessThanOrEqualTo(3));
    for (var i = 0; i < hits.length - 1; i++) {
      expect(hits[i].score, greaterThanOrEqualTo(hits[i + 1].score));
    }
    expect(hits.first.sourceId, 'ch_9');
  });

  test('invalidateSource: 对象删除后索引项级联清理', () async {
    await indexChapter(content: '林晚走进客栈。');
    expect(await service.countAll(), greaterThan(0));
    await service.invalidateSource(sourceType: 'chapter', sourceId: 'ch_1');
    expect(await service.countAll(), 0);
  });

  test('markStale + 重新索引: stale 标记后重算清除', () async {
    await indexChapter(content: '林晚的旧内容。');
    await service.markStale(sourceType: 'chapter', sourceId: 'ch_1');
    final stale = await db.embeddingDocumentDao.listBySource(
      sourceType: 'chapter',
      sourceId: 'ch_1',
    );
    expect(stale.first.metadata!['stale'], isTrue);

    // 重新索引（内容变化）后 stale 被覆盖为新 metadata。
    await service.indexSource(
      EmbeddingIndexRequest(
        sourceType: 'chapter',
        sourceId: 'ch_1',
        path: 'chapters/ch_1',
        title: '第一章',
        content: '林晚的新内容，完全更新了。',
        projectId: 'proj_1',
        revisionHash: 'rev-2',
      ),
    );
    final refreshed = await db.embeddingDocumentDao.listBySource(
      sourceType: 'chapter',
      sourceId: 'ch_1',
    );
    expect(refreshed.first.metadata!['stale'], isNull);
    expect(refreshed.first.content, contains('新内容'));
  });

  test('clearAll: 清空—重建—一致性测试', () async {
    await indexChapter(content: '清空前的正文内容。');
    expect(await service.countAll(), greaterThan(0));
    await service.clearAll();
    expect(await service.countAll(), 0);
    await indexChapter(content: '重建后的内容。');
    expect(await service.countAll(), greaterThan(0));
  });

  test('EmbeddingUnavailableException: 向量化不可用时降级纯关键词索引', () async {
    final degraded = EmbeddingSearchService(
      dao: db.embeddingDocumentDao,
      vectorizer: _ThrowingVectorizer(),
    );
    await degraded.indexSource(
      EmbeddingIndexRequest(
        sourceType: 'chapter',
        sourceId: 'ch_1',
        path: 'chapters/ch_1',
        title: '第一章',
        content: '沈雁从阴影里走出来。',
        projectId: 'proj_1',
        revisionHash: 'rev-1',
      ),
    );
    // 虽无向量，关键词索引已落库。
    final hits = await degraded.search(query: '沈雁', limit: 5);
    expect(hits, isNotEmpty);
    expect(hits.first.sourceId, 'ch_1');
  });

  test('实体命中: 标题/sourceId 命中排序高于正文纯关键词', () async {
    // 两块内容都含「青鸾」且向量确定，唯一差异是实体字段（标题/sourceId）
    // 是否命中：实体加成应把 ch_ent 稳定排在 ch_kw 之前。
    await indexChapter(
      id: 'ch_ent',
      title: '青鸾',
      content: '青鸾立在檐角。',
      path: 'chapters/ch_ent',
    );
    await indexChapter(
      id: 'ch_kw',
      title: '第一章',
      content: '她想起那只名叫青鸾的鸟，青鸾曾落在窗前。',
      path: 'chapters/ch_kw',
    );

    final hits = await service.search(query: '青鸾', limit: 5);
    expect(hits, isNotEmpty);
    expect(hits.first.sourceId, 'ch_ent');
    expect(hits.first.score, greaterThan(hits.last.score));
  });

  test('时间加权: 近期更新略高于陈旧（其他信号对齐）', () async {
    // 两块标题/内容/实体字段完全一致，只回填 changedAt/updatedAt 拉开时间。
    await indexChapter(
      id: 'ch_new',
      title: '第一章',
      content: '林晚推开柴门，院里落满了桂花。',
      path: 'chapters/ch_new',
    );
    await indexChapter(
      id: 'ch_old',
      title: '第一章',
      content: '林晚推开柴门，院里落满了桂花。',
      path: 'chapters/ch_old',
    );

    // 把 ch_old 的时间回填到 200 天前（行时间 + metadata.changedAt 同步）。
    final oldRows = await db.embeddingDocumentDao.listBySource(
      sourceType: 'chapter',
      sourceId: 'ch_old',
    );
    final staleTime = DateTime.now().subtract(const Duration(days: 200));
    for (final row in oldRows) {
      await (db.update(db.aiEmbeddingDocuments)
            ..where((t) => t.id.equals(row.id)))
          .write(
        AiEmbeddingDocumentsCompanion(
          updatedAt: drift.Value(staleTime),
          metadata: drift.Value(<String, dynamic>{
            ...?row.metadata,
            'changedAt': staleTime.toIso8601String(),
          }),
        ),
      );
    }

    final hits = await service.search(query: '柴门', limit: 5);
    expect(hits.length, 2);
    expect(hits.first.sourceId, 'ch_new');
    expect(hits.first.score, greaterThan(hits.last.score));
  });

  test('向量缺失: 仍按实体 + 关键词检索排序', () async {
    final kwOnly = EmbeddingSearchService(dao: db.embeddingDocumentDao);
    await kwOnly.indexSource(
      EmbeddingIndexRequest(
        sourceType: 'chapter',
        sourceId: 'ch_t',
        path: 'chapters/ch_t',
        title: '沈雁',
        content: '沈雁在城门口停下了脚步。',
        projectId: 'proj_1',
        revisionHash: 'rev-1',
      ),
    );
    await kwOnly.indexSource(
      EmbeddingIndexRequest(
        sourceType: 'chapter',
        sourceId: 'ch_b',
        path: 'chapters/ch_b',
        title: '第二章',
        content: '人群里有人低声念叨沈雁的名字，沈雁没有回头。',
        projectId: 'proj_1',
        revisionHash: 'rev-1',
      ),
    );

    final hits = await kwOnly.search(query: '沈雁', limit: 5);
    expect(hits, isNotEmpty);
    // 标题/sourceId 命中的 ch_t 实体分满分，排在正文命中的 ch_b 之前。
    expect(hits.first.sourceId, 'ch_t');
  });
}

class _ThrowingVectorizer implements EmbeddingVectorizer {
  @override
  Future<List<double>> embed(String text) async =>
      throw const EmbeddingUnavailableException('model not configured');
  @override
  String get modelId => 'none';
}
