// 职责: M4 正文修改与影响分析 — 影响审计器。
// 关联文件:
//   lib/shared/services/impact_audit_models.dart (输入/输出模型)
//   lib/shared/services/novel_content.dart (章节/人物/伏笔读取)
//   lib/shared/services/entity_relations_service.dart (关系 proof/evidence)
//   lib/shared/services/working_overlay.dart (Change Ledger 入口)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 核心思路（8 步流程的需求映射）：
//   1. 输入一次已提交的变更（WorkingChange / ImpactAuditRequest）
//   2. 从变更前后文本提取「变更实体」——人物名、别名、关键事实短语
//   3. 扫描下游章节正文/大纲/简要、伏笔 setup/payoff、关系 proof、
//      其他人物传记/别名，找出提及这些实体的下游引用
//   4. 每个命中给出证据片段 + 出处上下文 + 置信度
//   5. 命中项标记「待复核」（review_pending），提示人工重验，不静默覆盖
//
// 设计约束：
//   - 只做「读 + 标记」，不做任何内容写回——审计本身绝不改正文
//   - 匹配采用词面 + 别名两级：词面=1.0，别名/弱=0.6
//   - 对超大正文做长度上限与命中上限保护，避免卡 UI

import '../models/entity_relation_history.dart';
import 'impact_audit_models.dart';
import 'novel_content.dart';

/// 扫描结果：命中 + 已扫描对象数 + 相关对象总数（供覆盖统计）。
final class _ScanOutput {
  const _ScanOutput({required this.hits, required this.scanned, required this.total});
  final List<ImpactHit> hits;
  final int scanned;
  final int total;
}

/// 影响审计器 — 一次变更 → 下游影响清单（证据 + 置信度 + 待复核）。
class ImpactAuditService {
  ImpactAuditService(this.content);

  final NovelContentService content;

  /// 单次扫描最多处理的章节数（保护大工程性能）。
  static const int maxScanChapters = 400;

  /// 单章节正文最多匹配命中数（避免超长章节刷屏）。
  static const int maxHitsPerChapter = 3;

  /// 证据片段两侧保留字符数。
  static const int evidenceContextChars = 40;

  // ---------------------------------------------------------------------------
  // 1. 变更实体提取
  // ---------------------------------------------------------------------------

  /// 从变更前后文本提取用于下游匹配的「实体词」集合。
  ///
  /// 分词策略（无词典启发式）：
  ///   - 连续汉字串按常见虚词/标点分隔（「林晚是沈砚的青梅竹马」→ 林晚/沈砚/青梅竹马）
  ///   - 英文单词、引号短语原样保留
  /// 只做文本提取，不含 DB 名称；名称/别名由 [audit] 合并 [entityNamesForChange]。
  List<String> extractEntityTerms(ImpactAuditRequest request) {
    final terms = <String>{};
    final texts = <String>[
      if (request.oldText != null) request.oldText!,
      request.newText,
    ];
    for (final text in texts) {
      if (text.trim().isEmpty) continue;
      // 英文单词、引号短语、连续汉字串三类候选。
      final re = RegExp(
        r'"[^"]{2,30}"|「[^」]{2,30}」|[A-Za-z][A-Za-z0-9_\-]{1,30}|[\u4e00-\u9fff]+',
      );
      for (final match in re.allMatches(text)) {
        final raw = match.group(0)!;
        if (raw.startsWith('"') || raw.startsWith('「')) {
          final cleaned = _stripQuotes(raw);
          if (cleaned.length >= 2 && !_isNoiseTerm(cleaned)) {
            terms.add(cleaned);
          }
          continue;
        }
        if (RegExp(r'^[A-Za-z]').hasMatch(raw)) {
          if (raw.length >= 2 && !_isNoiseTerm(raw)) {
            terms.add(raw);
          }
          continue;
        }
        // 连续汉字串：按虚词/标点分隔为自然词。
        for (final segment in _splitChinese(raw)) {
          if (segment.length >= 2 && !_isNoiseTerm(segment)) {
            terms.add(segment);
          }
        }
      }
    }
    return terms.toList();
  }

  /// 连续汉字串按常见虚词/标点分隔，产出 ≥2 字自然词段。
  ///
  /// 影响分析宁可多报不可漏报（下游都只是「待复核」，多列无害）：
  /// 对 ≥3 字的长段再生成 2–4 字滑动窗口子串，把「沈砚登场」中的
  /// 「沈砚」「登场」这类独立词也暴露出来，避免内嵌人名/设定漏检。
  List<String> _splitChinese(String raw) {
    final re = RegExp(r'[的是了在和与及对为从向把被让使用于以而且或若则就都也很更最太又还如何其却便即竟]');
    final segments = raw
        .split(re)
        .map((segment) => segment.trim())
        .where((segment) => segment.length >= 2);
    final out = <String>[];
    final seen = <String>{};
    void add(String word) {
      if (word.length >= 2 && seen.add(word)) {
        out.add(word);
      }
    }

    for (final segment in segments) {
      add(segment);
      if (segment.length >= 3) {
        var candidates = 0;
        for (var len = 2; len <= 4 && len < segment.length; len++) {
          for (var i = 0; i + len <= segment.length; i++) {
            add(segment.substring(i, i + len));
            candidates++;
            // 每段最多贡献有限候选，避免超长段爆炸。
            if (candidates > 10) break;
          }
          if (candidates > 10) break;
        }
      }
    }
    return out;
  }

  /// 变更对象自身的名称/别名（最可靠的下游匹配词）。
  Future<List<String>> entityNamesForChange(ImpactAuditRequest request) async {
    final names = <String>{};
    final id = request.resourceId;
    switch (request.resourceType) {
      case 'characters':
        final profile = await content.getCharacterProfileById(id);
        if (profile != null) {
          if (profile.name.trim().isNotEmpty) names.add(profile.name.trim());
          for (final alias in profile.aliases) {
            if (alias.trim().isNotEmpty) names.add(alias.trim());
          }
        }
      case 'foreshadowing':
        final f = await content.getForeshadowingById(id);
        if (f != null && f.title.trim().isNotEmpty) names.add(f.title.trim());
      case 'items':
        final item = await content.getItemById(id);
        if (item != null && item.title.trim().isNotEmpty) {
          names.add(item.title.trim());
        }
      default:
        break;
    }
    return names.toList();
  }

  bool _isNoiseTerm(String term) {
    const noise = {
      '一个', '一种', '他们', '她们', '我们', '你们', '这个', '那个', '这里',
      '那里', '因为', '所以', '但是', '然后', '如果', '可以', '没有', '不是',
      '已经', '还是', '就是', '对于', '以及', '并且', '或者', '通过', '进行',
      '主要', '非常', '十分', '开始', '最后', '之后', '之前', '这样',
      '那样', '时候', '现在', '今天', '明天', '昨天', '什么', '怎么', '为何',
      '如何', '自己', '大家', '可能', '应该', '必须', '需要', '为了', '由于',
      '关于', '作为', '其中', '之间', '以上', '以下', '目前', '整个',
      '所有', '任何', '每', '这', '那', '他', '她', '它', '我', '你',
    };
    return noise.contains(term) || term.length < 2;
  }

  String _stripQuotes(String term) {
    var result = term;
    const quotes = ['"', '“', '”', '「', '」'];
    for (final q in quotes) {
      if (result.startsWith(q)) result = result.substring(1);
      if (result.endsWith(q)) result = result.substring(0, result.length - 1);
    }
    return result.trim();
  }

  // ---------------------------------------------------------------------------
  // 2. 下游扫描与匹配
  // ---------------------------------------------------------------------------

  /// 执行影响审计：返回下游影响清单。
  Future<ImpactAuditResult> audit(ImpactAuditRequest request) async {
    // 组装扫描词三来源并按来源给「影响强度分档」依据（无依据必须 UNKNOWN）：
    //   1. 变更前后文本提取的词（extractEntityTerms）→ HIGH
    //   2. 变更对象档案名称/别名（entityNamesForChange）→ DIRECT（覆盖同级）
    //   3. 全库人物名/别名 — 正文里出现的人物名即对该人物的引用，
    //      是最可靠的匹配源；仅对未被 1/2 命名的词标 MEDIUM（不降级已有高档）。
    final termSeverity = <String, String>{};
    for (final t in extractEntityTerms(request)) {
      if (t.length >= 2) termSeverity[t] = ImpactSeverity.high;
    }
    for (final t in await entityNamesForChange(request)) {
      if (t.length >= 2) termSeverity[t] = ImpactSeverity.direct;
    }
    for (final t in await _allCharacterNames()) {
      if (t.length >= 2 && !termSeverity.containsKey(t)) {
        termSeverity[t] = ImpactSeverity.medium;
      }
    }
    final terms = termSeverity.keys.toList();
    if (terms.isEmpty) {
      return ImpactAuditResult(
        request: request,
        affectedChapters: const [],
        affectedForeshadowings: const [],
        affectedRelations: const [],
        affectedCharacters: const [],
        summary: '未提取到可用于下游匹配的实体词，跳过影响分析。',
      );
    }

    final chapters = await _scanChapters(termSeverity, request);
    final foreshadowings = await _scanForeshadowings(termSeverity, request);
    final relations = await _scanRelations(termSeverity, request);
    final characters = await _scanCharacters(termSeverity, request);

    // 覆盖统计：已扫描对象数 vs 全库相关对象总数。
    final checkedCount = chapters.scanned +
        foreshadowings.scanned +
        relations.scanned +
        characters.scanned;
    final totalRelevantCount = chapters.total +
        foreshadowings.total +
        relations.total +
        characters.total;
    final coverage = totalRelevantCount > 0
        ? '已检查 $checkedCount / $totalRelevantCount 个对象'
        : '无可扫描对象';

    final summary = _buildSummary(
      terms: terms,
      chapters: chapters.hits,
      foreshadowings: foreshadowings.hits,
      relations: relations.hits,
      characters: characters.hits,
    );

    return ImpactAuditResult(
      request: request,
      affectedChapters: chapters.hits,
      affectedForeshadowings: foreshadowings.hits,
      affectedRelations: relations.hits,
      affectedCharacters: characters.hits,
      summary: summary,
      coverage: coverage,
      checkedCount: checkedCount,
      totalRelevantCount: totalRelevantCount,
    );
  }

  /// 全库人物名 + 别名（下游提及的最可靠匹配词）。
  Future<List<String>> _allCharacterNames() async {
    final profiles = await content.getCharacterProfiles();
    final names = <String>{};
    for (final profile in profiles) {
      final name = profile.name.trim();
      if (name.length >= 2) names.add(name);
      for (final alias in profile.aliases) {
        final trimmed = alias.trim();
        if (trimmed.length >= 2) names.add(trimmed);
      }
    }
    return names.toList();
  }

  /// 扫描下游章节正文/大纲/简要，找提及变更实体的章节。
  Future<_ScanOutput> _scanChapters(
    Map<String, String> termSeverity,
    ImpactAuditRequest request,
  ) async {
    final all = await content.getChapters();
    // 只扫正文类章节（跳过卷/卷首节点，其 title 结构不含正文）；
    // 变更对象自身不算下游，不占扫描预算。
    final targets = all
        .where(
          (chapter) =>
              chapter.type == 'chapter' &&
              chapter.content.isNotEmpty &&
              chapter.id != request.resourceId,
        )
        .take(maxScanChapters)
        .toList();
    // 按卷内序号排序，输出稳定。
    targets.sort((a, b) => a.siblingOrder.compareTo(b.siblingOrder));

    final hits = <ImpactHit>[];
    for (final chapter in targets) {
      final matched = _matchTermsInText(
        termSeverity: termSeverity,
        text: chapter.content,
        title: chapter.title ?? '第${chapter.siblingOrder}章',
        resourceType: 'chapter',
        resourceId: chapter.id,
        context: '正文提及变更实体',
        maxHits: maxHitsPerChapter,
      );
      if (matched.isNotEmpty) {
        hits.addAll(matched);
        if (hits.length >= maxScanChapters) break;
      }
    }
    final eligibleCount = all
        .where(
          (chapter) =>
              chapter.type == 'chapter' &&
              chapter.content.isNotEmpty &&
              chapter.id != request.resourceId,
        )
        .length;
    return _ScanOutput(
      hits: hits,
      scanned: targets.length,
      total: eligibleCount,
    );
  }

  /// 扫描伏笔 setup/payoff 提及。
  Future<_ScanOutput> _scanForeshadowings(
    Map<String, String> termSeverity,
    ImpactAuditRequest request,
  ) async {
    final all = await content.getForeshadowings();
    final hits = <ImpactHit>[];
    for (final f in all) {
      if (f.id == request.resourceId) continue;
      final haystack = '${f.title}\n${f.setup}\n${f.payoff}';
      final matched = _matchTermsInText(
        termSeverity: termSeverity,
        text: haystack,
        title: f.title,
        resourceType: 'foreshadowing',
        resourceId: f.id,
        context: '伏笔提及变更实体',
        maxHits: 2,
      );
      hits.addAll(matched);
    }
    final total = all.where((f) => f.id != request.resourceId).length;
    return _ScanOutput(hits: hits, scanned: total, total: total);
  }

  /// 扫描关系 proof 提及（关系是证据驱动的，proof 即关系原文）。
  Future<_ScanOutput> _scanRelations(
    Map<String, String> termSeverity,
    ImpactAuditRequest request,
  ) async {
    final all = await content.entityRelationsService.getAllRelations();
    final hits = <ImpactHit>[];
    for (final relation in all) {
      if (relation.id == request.resourceId) continue;
      final haystack =
          '${relation.proof}\n${relation.relationType}\n'
          '${relation.sourceId}\n${relation.targetId}';
      final matched = _matchTermsInText(
        termSeverity: termSeverity,
        text: haystack,
        title: _relationTitle(relation),
        resourceType: 'relation',
        resourceId: relation.id,
        context: '关系证明提及变更实体',
        maxHits: 1,
      );
      hits.addAll(matched);
    }
    final total = all.where((r) => r.id != request.resourceId).length;
    return _ScanOutput(hits: hits, scanned: total, total: total);
  }

  /// 扫描其他人物传记/别名提及（改 A 影响到提及 A 的 B）。
  Future<_ScanOutput> _scanCharacters(
    Map<String, String> termSeverity,
    ImpactAuditRequest request,
  ) async {
    final all = await content.getCharacterProfiles();
    final hits = <ImpactHit>[];
    for (final profile in all) {
      if (profile.id == request.resourceId) continue;
      final haystack =
          '${profile.name}\n${profile.aliases.join('\n')}\n'
          '${profile.biography}\n${profile.appearance}\n'
          '${profile.description}\n${profile.identity}';
      final matched = _matchTermsInText(
        termSeverity: termSeverity,
        text: haystack,
        title: profile.name,
        resourceType: 'character',
        resourceId: profile.id,
        context: '人物资料提及变更实体',
        maxHits: 2,
      );
      hits.addAll(matched);
    }
    final total = all.where((p) => p.id != request.resourceId).length;
    return _ScanOutput(hits: hits, scanned: total, total: total);
  }

  String _relationTitle(RelationSummary relation) =>
      '${relation.sourceId}·${relation.relationType}·${relation.targetId}';

  /// 在 [text] 中找 [termSeverity] 词表的词面命中；返回去重后的命中列表。
  ///
  /// 每个命中的 [ImpactHit.severity] 取自该词的匹配来源分档（无依据=UNKNOWN）；
  /// 置信度按档位映射：DIRECT/HIGH=1.0，MEDIUM/LOW/UNKNOWN=0.6。
  List<ImpactHit> _matchTermsInText({
    required Map<String, String> termSeverity,
    required String text,
    required String title,
    required String resourceType,
    required String resourceId,
    required String context,
    required int maxHits,
  }) {
    if (text.trim().isEmpty) return const [];
    final hits = <ImpactHit>[];
    final seen = <String>{};
    var count = 0;
    for (final entry in termSeverity.entries) {
      final term = entry.key;
      if (term.length < 2) continue;
      final index = text.indexOf(term);
      if (index < 0) continue;
      final key = '$term@$index';
      if (!seen.add(key)) continue;
      final severity = entry.value;
      final confidence =
          (severity == ImpactSeverity.direct ||
                  severity == ImpactSeverity.high)
              ? 1.0
              : 0.6;
      hits.add(
        ImpactHit(
          resourceType: resourceType,
          resourceId: resourceId,
          title: title,
          evidence: _snippet(text, index, term.length),
          context: '$context「$term」',
          confidence: confidence,
          severity: severity,
        ),
      );
      count++;
      if (count >= maxHits) break;
    }
    return hits;
  }

  /// 提取命中位置两侧的原文片段。
  String _snippet(String text, int index, int length) {
    final start = (index - evidenceContextChars).clamp(0, text.length);
    final end = (index + length + evidenceContextChars).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return '$prefix${text.substring(start, end).trim()}$suffix';
  }

  String _buildSummary({
    required List<String> terms,
    required List<ImpactHit> chapters,
    required List<ImpactHit> foreshadowings,
    required List<ImpactHit> relations,
    required List<ImpactHit> characters,
  }) {
    final parts = <String>[];
    if (chapters.isNotEmpty) {
      parts.add('${chapters.length} 个下游章节提及');
    }
    if (foreshadowings.isNotEmpty) {
      parts.add('${foreshadowings.length} 个伏笔提及');
    }
    if (relations.isNotEmpty) {
      parts.add('${relations.length} 条关系提及');
    }
    if (characters.isNotEmpty) {
      parts.add('${characters.length} 个人物提及');
    }
    if (parts.isEmpty) {
      return '未发现下游引用（词面匹配：${terms.join('、')}）。';
    }
    return '下游影响：${parts.join('；')}。请复核后决定是否落位。';
  }
}