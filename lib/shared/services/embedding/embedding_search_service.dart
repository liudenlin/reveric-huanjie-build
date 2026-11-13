// 职责: M6a 语义检索服务 — 正文/设定/研究素材分块索引与混合检索。
// 关联文件:
//   lib/shared/database/novel_content_daos/embedding_document_dao.dart (数据访问)
//   lib/shared/database/novel_content_database.dart (AiEmbeddingDocuments 表)
// 遵循的 Rules:
//   .agents/rules/db-migration.md
//   .agents/rules/service-naming.md
//
// 对齐专项设计 §8：
// - §8.3 数据流：Stable ID → 分块 + fingerprint → 索引（向量可选）→ Hybrid
//   检索 → 原文证据 + 对象版本 + 跳转定位。
// - §8.4 索引不变量：每条记录 metadata 携带 projectId/objectId/revisionHash/
//   chunkId/sourceAnchor/embeddingModelId/indexSchemaVersion；内容未变化不重算
//   向量（DAO.upsertChunk 返回 false）；对象删除级联失效；模型版本变更标 stale
//   后台重算；支持「清空—重建—一致性测试」。
// - §8.5 首个版本可不附带 embedding 权重：向量缺失时检索自动降级为
//   关键词全文匹配（本项目先以本地全文索引上线，不打 AI 猜测）。
//
// 本服务不直接调用 embedding API —— 向量化能力通过可插拔的
// EmbeddingVectorizer 注入；未注入时所有 chunk 的 vector 为空，检索走关键词。

import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;

import '../../database/novel_content_database.dart';
import '../../database/novel_content_daos/embedding_document_dao.dart';
import '../../logger/app_logger.dart';

final _log = AppLogger.forModule('EmbeddingSearch');

/// 索引 schema 版本（§8.4：indexSchemaVersion 不变量）。
const int embeddingIndexSchemaVersion = 1;

/// 混合检索融合权重（实体/时间加权检索，P0-2）。
///
/// 设计原则：语义与实体为主，时间为辅。时间权重上限 0.10，即使一篇文档
/// 时间分满分，也无法压过实体命中或语义相似的一篇旧文档。
///
/// - 向量可用：keyword*0.4 + vector*0.4 + entity*0.15 + time*0.05
/// - 向量缺失（关键词降级兜底）：keyword*0.6 + entity*0.3 + time*0.1
const double _wKeywordWithVector = 0.4;
const double _wVector = 0.4;
const double _wEntityWithVector = 0.15;
const double _wTimeWithVector = 0.05;
const double _wKeywordNoVector = 0.6;
const double _wEntityNoVector = 0.3;
const double _wTimeNoVector = 0.1;

/// 时间近期性：近 7 天内视为「新鲜」（满分），之后按半衰期 30 天指数衰减。
const int _freshDays = 7;
const double _timeHalfLifeDays = 30;

/// 检索命中（原文证据 + 定位信息）。
class SemanticHit {
  const SemanticHit({
    required this.chunkId,
    required this.sourceType,
    required this.sourceId,
    required this.path,
    required this.title,
    required this.chunkIndex,
    required this.content,
    required this.revisionHash,
    required this.sourceAnchor,
    required this.score,
    this.vectorScore,
  });

  /// 命中块 ID（跳转定位用）。
  final String chunkId;
  final String sourceType;
  final String sourceId;

  /// 可跳转路径（§8.3「跳转定位」）。
  final String path;
  final String title;
  final int chunkIndex;
  final String content;

  /// 对象版本 hash（§8.4）。
  final String revisionHash;

  /// 原文锚点（章节/段落定位）。
  final String sourceAnchor;

  /// 混合得分（0..1，关键词 + 向量融合）。
  final double score;

  /// 向量余弦相似度（可选；无向量时为 null）。
  final double? vectorScore;

  Map<String, dynamic> toJson() => {
    'chunkId': chunkId,
    'sourceType': sourceType,
    'sourceId': sourceId,
    'path': path,
    'title': title,
    'chunkIndex': chunkIndex,
    'content': content,
    'revisionHash': revisionHash,
    'sourceAnchor': sourceAnchor,
    'score': score,
    'vectorScore': vectorScore,
  };
}

/// 索引请求 — 一个源对象的一次完整入索引。
class EmbeddingIndexRequest {
  const EmbeddingIndexRequest({
    required this.sourceType,
    required this.sourceId,
    required this.path,
    required this.content,
    this.title = '',
    this.projectId = '',
    this.revisionHash = '',
    this.chunkSizeChars = 800,
    this.chunkOverlapChars = 80,
    this.embeddingModelId = 'none',
    this.providerId,
  });

  final String sourceType;
  final String sourceId;
  final String path;
  final String title;
  final String content;

  /// 项目/作品 ID（§8.4 必需）。
  final String projectId;

  /// 对象内容 hash（版本指纹；内容未变不重算向量，§8.4）。
  final String revisionHash;

  /// 切分粒度（字符数）。
  final int chunkSizeChars;

  /// 相邻块重叠（字符数），保留跨块语境。
  final int chunkOverlapChars;

  /// 向量模型 ID；未接入向量化时为 'none'。
  final String embeddingModelId;

  final String? providerId;
}

/// 向量化能力（可插拔；§8.5 首个版本可不接入）。
abstract interface class EmbeddingVectorizer {
  /// 计算一段文本的向量；模型不可用时抛 EmbeddingUnavailableException。
  ///
  /// 返回 Future 以支持真实 HTTP embedding 端点；调用方负责等待并在失败时
  /// 降级为关键词检索。
  Future<List<double>> embed(String text);

  String get modelId;
}

class EmbeddingUnavailableException implements Exception {
  const EmbeddingUnavailableException(this.message);
  final String message;

  @override
  String toString() => 'EmbeddingUnavailableException: $message';
}

/// M6a 语义检索服务。
class EmbeddingSearchService {
  EmbeddingSearchService({required this.dao, this._vectorizer});

  final EmbeddingDocumentDao dao;

  /// 可插拔向量化器；null 时检索为纯关键词模式。
  final EmbeddingVectorizer? _vectorizer;

  /// 将源对象分块写入索引。
  ///
  /// 返回本次实际写入/更新的块数（内容未变化返回 0，可用于跳过向量重算）。
  /// 向量化失败（模型未配置）时仍写入关键词索引（§8.5 降级）。
  Future<int> indexSource(EmbeddingIndexRequest request) async {
    final chunks = _chunkText(
      request.content,
      size: request.chunkSizeChars,
      overlap: request.chunkOverlapChars,
    );
    if (chunks.isEmpty) return 0;

    var changed = 0;
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      List<double>? vector;
      var embeddingModel = request.embeddingModelId;
      if (_vectorizer != null) {
        try {
          vector = await _vectorizer.embed(chunk);
          embeddingModel = _vectorizer.modelId;
        } on EmbeddingUnavailableException catch (e) {
          // 模型不可用：降级为纯关键词索引，不阻断索引流程。
          _log.warning('embedding unavailable, keyword-only fallback: $e');
          embeddingModel = 'none';
        }
      }

      final metadata = _invariantMetadata(
        request: request,
        chunkIndex: i,
        sourceAnchor: '${request.path}#chunk-$i',
        changed: true,
      );

      final didChange = await dao.upsertChunk(
        AiEmbeddingDocumentsCompanion(
          id: Value('${request.sourceType}:${request.sourceId}:chunk-$i'),
          sourceType: Value(request.sourceType),
          sourceId: Value(request.sourceId),
          path: Value(request.path),
          title: Value(request.title),
          chunkIndex: Value(i),
          content: Value(chunk),
          embeddingModel: Value(embeddingModel),
          providerId: Value(request.providerId),
          vector: Value(vector ?? const []),
          metadata: Value(metadata),
          updatedAt: Value(DateTime.now()),
        ),
      );
      if (didChange) changed++;
    }
    _log.info(
      'indexed ${request.sourceType}:${request.sourceId} '
      '($changed changed / ${chunks.length} chunks)',
    );
    return changed;
  }

  /// 混合检索：关键词（必选）+ 向量余弦（可选，需向量非空且维度一致）。
  Future<List<SemanticHit>> search({
    required String query,
    List<String>? sourceTypes,
    int limit = 10,
    double minScore = 0.05,
  }) async {
    final terms = _tokenize(query);
    if (terms.isEmpty) return const [];

    final rows = await dao.listAllForSearch(
      sourceTypes: sourceTypes,
      limit: 4096, // 召回上限：混合打分在内存做，避免 LIKE 全表在 SQLite 层发散。
    );

    final queryVector = _vectorizer != null ? await _safeEmbed(query) : null;

    final hits = <SemanticHit>[];
    for (final row in rows) {
      final keywordScore = _keywordScore(row, terms);
      if (keywordScore <= 0 && (queryVector == null || row.vector.isEmpty)) {
        continue;
      }
      var vectorScore = queryVector == null || row.vector.isEmpty
          ? null
          : _cosine(queryVector, row.vector);
      // 维度不一致视为无向量（降级关键词）。
      if (vectorScore != null && !vectorScore.isFinite) vectorScore = null;

      // 实体信号：查询词命中标题/sourceId/metadata.objectId/sourceAnchor。
      final entityScore = _entityScore(
        terms: terms,
        title: row.title,
        sourceId: row.sourceId,
        objectId: row.metadata?['objectId'] as String? ?? '',
        sourceAnchor: row.metadata?['sourceAnchor'] as String? ?? '',
      );
      // 时间信号：metadata.narrativeTime > changedAt > updatedAt 近期性。
      final timeScore = _timeScore(
        narrativeTime: row.metadata?['narrativeTime'] as String?,
        changedAt: row.metadata?['changedAt'] as String?,
        updatedAt: row.updatedAt,
      );

      final merged = _mergeScore(
        keyword: keywordScore,
        vector: vectorScore,
        hasVector: vectorScore != null,
        entity: entityScore,
        time: timeScore,
      );
      if (merged < minScore) continue;

      hits.add(
        SemanticHit(
          chunkId: row.id,
          sourceType: row.sourceType,
          sourceId: row.sourceId,
          path: row.path,
          title: row.title,
          chunkIndex: row.chunkIndex,
          content: row.content,
          revisionHash: row.metadata?['revisionHash'] as String? ?? '',
          sourceAnchor: row.metadata?['sourceAnchor'] as String? ?? row.path,
          score: merged,
          vectorScore: vectorScore,
        ),
      );
    }

    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList(growable: false);
  }

  /// 使某源对象失效（对象删除时的级联清理，§8.4）。
  Future<void> invalidateSource({
    required String sourceType,
    required String sourceId,
  }) {
    return dao.invalidateSource(sourceType: sourceType, sourceId: sourceId);
  }

  /// 模型/对象版本变更后标记 stale（后台重算，§8.4）。
  Future<void> markStale({
    required String sourceType,
    required String sourceId,
  }) {
    return dao.markStale(sourceType: sourceType, sourceId: sourceId);
  }

  /// 清空索引（「清空—重建—一致性测试」，§8.4）。
  Future<void> clearAll() => dao.clearAll();

  Future<int> countAll() => dao.countAll();

  // -------------------------------------------------------------------------
  // 内部实现
  // -------------------------------------------------------------------------

  /// §8.4 索引不变量：每条记录必须携带的元数据。
  Map<String, dynamic> _invariantMetadata({
    required EmbeddingIndexRequest request,
    required int chunkIndex,
    required String sourceAnchor,
    required bool changed,
  }) {
    return {
      'projectId': request.projectId,
      'objectId': request.sourceId,
      'revisionHash': request.revisionHash,
      'chunkId': '${request.sourceType}:${request.sourceId}:chunk-$chunkIndex',
      'sourceAnchor': sourceAnchor,
      'embeddingModelId': request.embeddingModelId,
      'indexSchemaVersion': embeddingIndexSchemaVersion,
      if (changed) 'changedAt': DateTime.now().toIso8601String(),
    };
  }

  /// 按字符数切块（含重叠）。
  List<String> _chunkText(
    String text, {
    required int size,
    required int overlap,
  }) {
    final normalized = text.trim();
    if (normalized.isEmpty) return const [];
    if (normalized.length <= size) return [normalized];

    final chunks = <String>[];
    var start = 0;
    while (start < normalized.length) {
      var end = math.min(start + size, normalized.length);
      // 避免在词中切：就近回退到换行/句号。
      if (end < normalized.length) {
        final cut = _bestCut(normalized, end);
        chunks.add(normalized.substring(start, cut));
        start = cut > start ? cut - overlap : cut;
      } else {
        chunks.add(normalized.substring(start));
        start = normalized.length;
      }
    }
    return chunks;
  }

  int _bestCut(String text, int end) {
    for (var i = end; i > math.max(0, end - 120); i--) {
      final c = text[i - 1];
      if (c == '\n' || c == '。' || c == '！' || c == '？' || c == '.') {
        return i;
      }
    }
    return end;
  }

  /// 中文 + 英文分词：中文按单字/二元组，英文按空格词。
  List<String> _tokenize(String text) {
    final result = <String>{};
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];

    // 英文词。
    for (final m in RegExp(r'[A-Za-z0-9]+').allMatches(trimmed)) {
      result.add(m.group(0)!.toLowerCase());
    }
    // 中文单字 + 二元组（简单不分词，避免依赖第三方分词器）。
    final han = RegExp(r'[\u4e00-\u9fff]');
    final chars = <String>[];
    for (final c in trimmed.split('')) {
      if (han.hasMatch(c)) chars.add(c);
    }
    if (chars.length <= 1) {
      if (chars.isNotEmpty) result.add(chars.first);
    } else {
      // 单字（去重）+ 二元组。
      result.addAll(chars);
      for (var i = 0; i < chars.length - 1; i++) {
        result.add('${chars[i]}${chars[i + 1]}');
      }
    }
    return result.toList(growable: false);
  }

  double _keywordScore(AiEmbeddingDocument row, List<String> terms) {
    final haystack = '${row.title} ${row.content}'.toLowerCase();
    if (haystack.isEmpty) return 0;
    var matched = 0;
    for (final term in terms) {
      if (haystack.contains(term)) matched++;
    }
    if (matched == 0) return 0;
    // 简单 TF 主题覆盖：命中率 * 长度归一（短文本更可能是精准命中）。
    final coverage = matched / terms.length;
    final lenNorm = math.min(1.0, 500 / math.max(50, row.content.length));
    return coverage * (0.5 + 0.5 * lenNorm);
  }

  /// 实体得分（0..1）：查询词在实体字段（标题/sourceId/objectId/sourceAnchor）
  /// 中的命中率；查询整体精确等于某个实体字段时给满分（精确匹配高于模糊包含）。
  ///
  /// CJK 查询词天然含单字+二元组，用「词包含于字段」的子串判定即可对齐
  /// _keywordScore 的匹配语义；英文/数字词要求整词相等，避免 ID 前缀误命中。
  double _entityScore({
    required List<String> terms,
    required String title,
    required String sourceId,
    required String objectId,
    required String sourceAnchor,
  }) {
    final fields = <String>[
      title.toLowerCase(),
      sourceId.toLowerCase(),
      objectId.toLowerCase(),
      sourceAnchor.toLowerCase(),
    ];
    // 整体精确命中某个实体字段：满分（精确匹配 > 模糊包含）。terms 已由
    // _tokenize 统一小写，可直接与字段小写值比较。
    for (final f in fields) {
      if (f.isNotEmpty && terms.contains(f)) return 1.0;
    }
    var matched = 0;
    for (final term in terms) {
      final isCjk = RegExp(r'^[\u4e00-\u9fff]+$').hasMatch(term);
      final hit = fields.any(
        (f) => isCjk ? f.contains(term) : f.split(RegExp(r'[^a-z0-9]+')).contains(term),
      );
      if (hit) matched++;
    }
    if (matched == 0) return 0;
    return math.min(1.0, matched / math.max(1, terms.length));
  }

  /// 时间得分（0..1）：按可解析时间做近期性归一化。
  ///
  /// 优先级：metadata.narrativeTime（叙事时间，作者显式标注）>
  /// metadata.changedAt（本次内容变更时间）> row.updatedAt（行更新时间）。
  /// narrativeTime/changedAt 均不可解析时退化为 updatedAt 近期性（非空兜底）。
  double _timeScore({
    required String? narrativeTime,
    required String? changedAt,
    required DateTime updatedAt,
  }) {
    final ref = _parseTime(narrativeTime) ??
        _parseTime(changedAt) ??
        updatedAt;
    final days = DateTime.now().difference(ref).inMilliseconds /
        (24 * 60 * 60 * 1000);
    if (days <= 0) return 1.0; // 未来/时钟偏移：视为最新。
    if (days <= _freshDays) return 1.0;
    // 指数衰减：每过 _timeHalfLifeDays 天分数减半，越旧越低但永不为 0。
    return math.pow(0.5, (days - _freshDays) / _timeHalfLifeDays).toDouble();
  }

  /// 宽松解析 ISO8601 / yyyy-MM-dd 时间字符串；失败返回 null。
  DateTime? _parseTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim());
  }

  Future<List<double>> _safeEmbed(String text) async {
    try {
      return await _vectorizer!.embed(text);
    } on EmbeddingUnavailableException {
      return const [];
    }
  }

  double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length) return double.nan;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  /// 关键词 + 向量 + 实体 + 时间四路融合（§8.3 简单分数融合的加权扩展）。
  ///
  /// 向量可用时四路各按 [P0-2 权重] 叠加；向量缺失时把向量权重归还给
  /// 关键词/实体/时间，保证无向量也能稳定排序。向量余弦先归一化到 [0,1]。
  double _mergeScore({
    required double keyword,
    required double? vector,
    required bool hasVector,
    required double entity,
    required double time,
  }) {
    if (hasVector && vector != null) {
      final vNorm = math.max(0.0, (vector + 1) / 2); // [-1,1] 归一化到 [0,1]
      return keyword * _wKeywordWithVector +
          vNorm * _wVector +
          entity * _wEntityWithVector +
          time * _wTimeWithVector;
    }
    // 无向量：keyword*0.6 + entity*0.3 + time*0.1（向量项权重归还其余三路）。
    return keyword * _wKeywordNoVector +
        entity * _wEntityNoVector +
        time * _wTimeNoVector;
  }
}
