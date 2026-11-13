// 职责: OpenAI 兼容 /embeddings HTTP 向量化器 — 调用 BYOK 配置的嵌入端点，
//       把文本 POST 成向量，失败时抛 EmbeddingUnavailableException 供上层降级。
// 关联文件:
//   lib/shared/services/embedding/embedding_search_service.dart (接口与降级)
//   lib/shared/models/ai_provider.dart (AiProvider.effectiveBaseUrl/effectiveApiKey/embeddingModels)
//   lib/shared/providers/novel_providers.dart (组合 provider)
// 遵循的 Rules:
//   .agents/rules/service-naming.md

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../logger/app_logger.dart';
import 'embedding_search_service.dart';

final _log = AppLogger.forModule('HttpEmbeddingVectorizer');

/// OpenAI 兼容嵌入端点的具体向量化实现。
///
/// 请求格式遵循 OpenAI `/embeddings`：
/// POST `{baseUrl}/embeddings`，Authorization: `Bearer {apiKey}`，
/// body `{"model": {model}, "input": [{text}]}`；响应取 `data[0].embedding`。
/// 非 2xx、JSON 结构不符或向量为空时抛 [EmbeddingUnavailableException]，
/// 由 [EmbeddingSearchService] 捕获后降级为纯关键词检索。
class OpenAiCompatibleEmbeddingVectorizer implements EmbeddingVectorizer {
  OpenAiCompatibleEmbeddingVectorizer({
    required String baseUrl,
    required String apiKey,
    required this.modelId,
    http.Client? client,
  }) : _baseUrl = baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
       _apiKey = apiKey.trim(),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String _baseUrl;
  final String _apiKey;
  final http.Client _client;
  final bool _ownsClient;

  @override
  final String modelId;

  @override
  Future<List<double>> embed(String text) async {
    if (text.trim().isEmpty) {
      return const [];
    }
    if (_baseUrl.isEmpty || _apiKey.isEmpty) {
      throw const EmbeddingUnavailableException(
        'embedding endpoint requires baseUrl and apiKey',
      );
    }

    final uri = Uri.parse('$_baseUrl/embeddings');
    final response = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': modelId,
        'input': [text],
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      _log.warning(
        'embedding request failed status=${response.statusCode} '
        'body=${_safeBody(response.body)}',
      );
      throw EmbeddingUnavailableException(
        'embedding request failed with status ${response.statusCode}',
      );
    }

    final vector = _parseVector(response.body);
    if (vector.isEmpty) {
      throw const EmbeddingUnavailableException(
        'embedding response contained no vector',
      );
    }
    return vector;
  }

  List<double> _parseVector(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const EmbeddingUnavailableException(
        'embedding response is not a JSON object',
      );
    }
    final data = decoded['data'];
    if (data is! List || data.isEmpty) {
      throw const EmbeddingUnavailableException(
        'embedding response data is empty',
      );
    }
    final first = data.first;
    if (first is! Map<String, dynamic>) {
      throw const EmbeddingUnavailableException(
        'embedding response item is not an object',
      );
    }
    final embedding = first['embedding'];
    if (embedding is! List) {
      throw const EmbeddingUnavailableException(
        'embedding response item has no embedding array',
      );
    }
    return [
      for (final value in embedding)
        if (value is num)
          value.toDouble()
        else
          throw const EmbeddingUnavailableException(
            'embedding contains a non-numeric value',
          ),
    ];
  }

  String _safeBody(String body) {
    if (body.length <= 512) return body;
    return '${body.substring(0, 512)}...';
  }

  /// 释放内部持有的 http.Client（注入外部 client 时不负责关闭）。
  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
