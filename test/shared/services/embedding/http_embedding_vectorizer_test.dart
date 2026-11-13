// 职责: OpenAiCompatibleEmbeddingVectorizer 测试 — MockClient 验证 /embeddings
//       请求、已知向量解析、失败降级异常，以及接入 EmbeddingSearchService 后的
//       混合打分（keyword*0.4 + vNorm*0.4 + entity*0.15 + time*0.05）。
// 关联文件:
//   lib/shared/services/embedding/http_embedding_vectorizer.dart
//   lib/shared/services/embedding/embedding_search_service.dart
//   lib/shared/database/novel_content_database.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/embedding/embedding_search_service.dart';
import 'package:reveric/shared/services/embedding/http_embedding_vectorizer.dart';

const _model = 'text-embedding-3-small';

/// 按输入文本生成确定性 8 维向量（与 M6a fake 一致），经 HTTP 响应返回。
MockClient _vectorClient({int? forcedStatus}) {
  return MockClient((request) async {
    final status = forcedStatus ?? 200;
    if (status != 200) {
      return http.Response('{"error":"bad request"}', status);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final input = (body['input'] as List).first as String;
    final v = List<double>.filled(8, 0);
    for (final c in input.codeUnits) {
      v[c % 8] += 1;
    }
    return http.Response(
      jsonEncode({
        'data': [
          {'embedding': v},
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// 所有输入都返回同一固定向量，保证 query 与文档向量余弦=1。
MockClient _fixedVectorClient() {
  return MockClient((_) async {
    return http.Response(
      jsonEncode({
        'data': [
          {
            'embedding': [1.0, 0, 0, 0, 0, 0, 0, 0],
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  group('OpenAiCompatibleEmbeddingVectorizer.embed', () {
    test('POST /embeddings 并解析返回向量', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': [0.1, 0.2, 0.3],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final vectorizer = OpenAiCompatibleEmbeddingVectorizer(
        baseUrl: 'https://example.com/v1',
        apiKey: 'sk-test',
        modelId: _model,
        client: client,
      );

      final vector = await vectorizer.embed('林晚走进客栈');

      expect(vector, [0.1, 0.2, 0.3]);
      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://example.com/v1/embeddings');
      expect(captured.headers['Authorization'], 'Bearer sk-test');
      expect(captured.headers['Content-Type'], contains('application/json'));
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['model'], _model);
      expect((body['input'] as List).first, '林晚走进客栈');
      expect(vectorizer.modelId, _model);
    });

    test('非 2xx 抛 EmbeddingUnavailableException', () async {
      final vectorizer = OpenAiCompatibleEmbeddingVectorizer(
        baseUrl: 'https://example.com/v1',
        apiKey: 'sk-test',
        modelId: _model,
        client: _vectorClient(forcedStatus: 500),
      );

      await expectLater(
        vectorizer.embed('测试'),
        throwsA(isA<EmbeddingUnavailableException>()),
      );
    });

    test('响应缺向量抛 EmbeddingUnavailableException', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {'other': 1},
            ],
          }),
          200,
        ),
      );
      final vectorizer = OpenAiCompatibleEmbeddingVectorizer(
        baseUrl: 'https://example.com/v1',
        apiKey: 'sk-test',
        modelId: _model,
        client: client,
      );

      await expectLater(
        vectorizer.embed('测试'),
        throwsA(isA<EmbeddingUnavailableException>()),
      );
    });

    test('baseUrl 或 apiKey 缺失直接抛异常，不发请求', () async {
      final client = _vectorClient();
      final vectorizer = OpenAiCompatibleEmbeddingVectorizer(
        baseUrl: '',
        apiKey: '',
        modelId: _model,
        client: client,
      );

      await expectLater(
        vectorizer.embed('测试'),
        throwsA(isA<EmbeddingUnavailableException>()),
      );
    });
  });

  group('EmbeddingSearchService 混合打分', () {
    late NovelContentDatabase db;
    late EmbeddingSearchService service;

    setUp(() {
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      service = EmbeddingSearchService(
        dao: db.embeddingDocumentDao,
        vectorizer: OpenAiCompatibleEmbeddingVectorizer(
          baseUrl: 'https://example.com/v1',
          apiKey: 'sk-test',
          modelId: _model,
          client: _fixedVectorClient(),
        ),
      );
    });

    tearDown(() async => db.close());

    Future<void> indexChapter({
      required String id,
      required String content,
      String title = '',
    }) {
      return service.indexSource(
        EmbeddingIndexRequest(
          sourceType: 'chapter',
          sourceId: id,
          path: 'chapters/$id',
          title: title,
          content: content,
          projectId: 'proj_1',
          revisionHash: 'rev-1',
        ),
      );
    }

    test('向量命中参与 keyword*0.4 + vNorm*0.4 + entity*0.15 + time*0.05 混合得分', () async {
      await indexChapter(id: 'ch_1', content: '烛火照亮了客栈的门槛。', title: '夜袭');
      await indexChapter(id: 'ch_2', content: '完全无关的集市内容，没有灯笼。', title: '集市');

      final hits = await service.search(query: '烛火', limit: 5);

      expect(hits, isNotEmpty);
      final keywordHit = hits.firstWhere((h) => h.sourceId == 'ch_1');
      final vectorOnly = hits.firstWhere((h) => h.sourceId == 'ch_2');

      // ch_2 无关键词命中，向量与 query 同构（余弦=1），且新写入行时间近期，
      // 因此 score = vector*0.4 + time*0.05（实体 0）。
      expect(vectorOnly.vectorScore, closeTo(1.0, 1e-9));
      expect(vectorOnly.score, closeTo(0.45, 1e-9));

      // ch_1 关键词命中 + 向量命中 + 时间近期：score = keyword*0.4 + vector*0.4 + time*0.05。
      expect(keywordHit.vectorScore, closeTo(1.0, 1e-9));
      expect(keywordHit.score, closeTo(0.85, 1e-9));
    });
  });
}
