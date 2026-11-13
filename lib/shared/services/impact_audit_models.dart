// 职责: M4 正文修改与影响分析 — 影响审计输入/输出模型。
// 关联文件:
//   lib/shared/services/impact_audit_service.dart (审计逻辑)
//   lib/shared/database/novel_content_database.dart (WorkingChanges 表)
//   lib/shared/services/working_overlay.dart (Change Ledger 入口)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（需求框架 M4）：手动改第 20 章与 AI 改正文都进 Ledger；
//   受影响章节自动列出附证据；下游标记待复核，不静默覆盖。

/// 影响审计的影响强度分档常量（三维分档）。
///
/// 赋值依据（只按可观测的命中来源 / 证据强度判定，无依据必须给 [UNKNOWN]）：
///   - [DIRECT]：命中词来自变更对象自身的档案名 / 别名（最直接的下游引用）
///   - [HIGH]  ：命中词来自变更前后文本提取的关键短语（改什么词下游就出现什么词）
///   - [MEDIUM]：命中词来自全库其他人物名 / 别名（间接引用，仅证明下游提及他人）
///   - [LOW]   ：弱匹配 / 低置信命中（保留档位，当前扫描策略暂不产出）
///   - [NONE]  ：无下游命中（结果级档位，见 [ImpactAuditResult.overallSeverity]）
///   - [UNKNOWN]：证据不足、无法判定强度（禁止无依据猜测）
abstract final class ImpactSeverity {
  static const String direct = 'DIRECT';
  static const String high = 'HIGH';
  static const String medium = 'MEDIUM';
  static const String low = 'LOW';
  static const String none = 'NONE';
  static const String unknown = 'UNKNOWN';
}

/// severity 档位排序表（用于 [ImpactAuditResult.overallSeverity] 取最高档）。
const List<String> _severityRank = [
  ImpactSeverity.unknown, // 未知最低，仅兜底
  ImpactSeverity.none,
  ImpactSeverity.low,
  ImpactSeverity.medium,
  ImpactSeverity.high,
  ImpactSeverity.direct,
];

/// 每个 severity 档位的默认建议文案（R-21）。
///
/// UI 展示「建议：…」。输入非法档位时回退为 [ImpactSeverity.unknown] 的建议。
String defaultActionForSeverity(String severity) {
  switch (severity) {
    case ImpactSeverity.direct:
      return '命中变更对象自身名称，优先复核该处引用是否符合新设定';
    case ImpactSeverity.high:
      return '命中变更文本关键词，建议核实改为是否成立';
    case ImpactSeverity.medium:
      return '命中全库其他人物名，建议确认变更未连带影响其关系';
    case ImpactSeverity.low:
      return '弱匹配命中，建议抽查原文后决定';
    case ImpactSeverity.none:
      return '未发现下游引用，可暂不处理';
    case ImpactSeverity.unknown:
    default:
      return '证据不足无法判定，建议重跑审计';
  }
}

/// 影响审计的输入：一次已发生的变更（取自 WorkingChange 或调用方构造）。
class ImpactAuditRequest {
  const ImpactAuditRequest({
    required this.resourcePath,
    required this.resourceType,
    required this.resourceId,
    this.field,
    required this.oldText,
    required this.newText,
    this.changeType = 'write',
    this.source = 'ai',
    this.triggerTurnId,
  });

  /// 变更资源路径（characters/cha_x、chapters/chp_y …）
  final String resourcePath;
  final String resourceType;

  /// 变更对象 id
  final String resourceId;
  final String? field;

  /// 变更前后文本（null 表示新建/无前值）
  final String? oldText;
  final String newText;

  /// write / create / remove
  final String changeType;

  /// ai / manual_edit
  final String source;

  /// 触发该变更的轮次（可回溯到对话）
  final String? triggerTurnId;

  ImpactAuditRequest copyWith({String? oldText, String? newText}) =>
      ImpactAuditRequest(
        resourcePath: resourcePath,
        resourceType: resourceType,
        resourceId: resourceId,
        field: field,
        oldText: oldText ?? this.oldText,
        newText: newText ?? this.newText,
        changeType: changeType,
        source: source,
        triggerTurnId: triggerTurnId,
      );
}

/// 下游受影响实体的基座：命中对象 + 证据片段 + 出处。
class ImpactHit {
  const ImpactHit({
    required this.resourceType,
    required this.resourceId,
    required this.title,
    required this.evidence,
    required this.context,
    required this.confidence,
    this.severity = ImpactSeverity.unknown,
    this.reviewPending = false,
  });

  /// 受影响的资源类型：chapter / foreshadowing / relation / character
  final String resourceType;
  final String resourceId;

  /// 展示名称（章节标题 / 伏笔标题 / 关系摘要 / 人物名）
  final String title;

  /// 命中证据原文片段（一句话，供人工复核）
  final String evidence;

  /// 证据出处说明（第 N 章 / 伏笔 setup / 关系证明 / 别名字段）
  final String context;

  /// 置信度 0~1（词面强匹配=1.0；别名/弱匹配=0.6）
  final double confidence;

  /// 影响强度分档（DIRECT/HIGH/MEDIUM/LOW/UNKNOWN），由匹配来源按依据判定。
  final String severity;

  /// 是否已标记「待复核」（下游需人工重验，不静默覆盖）
  final bool reviewPending;

  Map<String, dynamic> toJson() => {
    'resourceType': resourceType,
    'resourceId': resourceId,
    'title': title,
    'evidence': evidence,
    'context': context,
    'confidence': confidence,
    'severity': severity,
    'reviewPending': reviewPending,
  };

  /// UI 反序列化：resultJson → 命中条目（服务写出的 schema 固定，容错缺失字段）。
  factory ImpactHit.fromJson(Map<String, dynamic> json) => ImpactHit(
    resourceType: json['resourceType'] as String? ?? '',
    resourceId: json['resourceId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    evidence: json['evidence'] as String? ?? '',
    context: json['context'] as String? ?? '',
    confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
    severity: json['severity'] as String? ?? ImpactSeverity.unknown,
    reviewPending: json['reviewPending'] as bool? ?? false,
  );

  ImpactHit withReviewPending(bool value) => ImpactHit(
    resourceType: resourceType,
    resourceId: resourceId,
    title: title,
    evidence: evidence,
    context: context,
    confidence: confidence,
    severity: severity,
    reviewPending: value,
  );
}

/// 影响审计结果：一次变更的下游影响清单。
class ImpactAuditResult {
  const ImpactAuditResult({
    required this.request,
    required this.affectedChapters,
    required this.affectedForeshadowings,
    required this.affectedRelations,
    required this.affectedCharacters,
    this.summary = '',
    this.coverage = '',
    this.checkedCount = 0,
    this.totalRelevantCount = 0,
  });

  final ImpactAuditRequest request;

  /// 受影响章节（正文/大纲/简要含变更实体名）
  final List<ImpactHit> affectedChapters;

  /// 受影响伏笔（setup/payoff 提及变更实体）
  final List<ImpactHit> affectedForeshadowings;

  /// 受影响关系（proof 提及变更实体）
  final List<ImpactHit> affectedRelations;

  /// 受影响人物（传记/别名与变更实体重合）
  final List<ImpactHit> affectedCharacters;

  /// 汇总文案（供 AI 回复 / UI 展示）
  final String summary;

  /// 覆盖范围文案（如「已检查 380 / 420 个对象」）。
  final String coverage;

  /// 本次审计实际检查的下游对象数（章节+伏笔+关系+人物）。
  final int checkedCount;

  /// 全库相关对象总数（章节+伏笔+关系+人物）。
  final int totalRelevantCount;

  /// 尚未检查的对象数；<=0 表示已全覆盖。
  int get uncheckedCount =>
      (totalRelevantCount - checkedCount) > 0
          ? totalRelevantCount - checkedCount
          : 0;

  /// 未全覆盖时不能视为「已通过」。
  bool get hasUnchecked => uncheckedCount > 0;

  bool get isEmpty =>
      affectedChapters.isEmpty &&
      affectedForeshadowings.isEmpty &&
      affectedRelations.isEmpty &&
      affectedCharacters.isEmpty;

  int get totalHitCount =>
      affectedChapters.length +
      affectedForeshadowings.length +
      affectedRelations.length +
      affectedCharacters.length;

  List<ImpactHit> get allHits => [
    ...affectedChapters,
    ...affectedForeshadowings,
    ...affectedRelations,
    ...affectedCharacters,
  ];

  /// 结果级影响强度：无命中→[ImpactSeverity.none]；否则取全部命中里的最高档。
  ///
  /// 若命中全部为 [ImpactSeverity.unknown]，则如实返回 unknown（不臆测）。
  String get overallSeverity {
    if (isEmpty) return ImpactSeverity.none;
    var best = _severityRank.indexOf(ImpactSeverity.unknown);
    for (final hit in allHits) {
      final rank = _severityRank.indexOf(hit.severity);
      final safeRank = rank < 0 ? _severityRank.indexOf(ImpactSeverity.unknown) : rank;
      if (safeRank > best) best = safeRank;
    }
    return _severityRank[best];
  }

  /// 结果级默认建议文案（R-21）。
  String get recommendedAction => defaultActionForSeverity(overallSeverity);

  ImpactAuditResult withReviewPending(Iterable<ImpactHit> pending) {
    final pendingKeys = pending
        .map((hit) => '${hit.resourceType}:${hit.resourceId}')
        .toSet();
    List<ImpactHit> apply(List<ImpactHit> hits) => [
      for (final hit in hits)
        pendingKeys.contains('${hit.resourceType}:${hit.resourceId}')
            ? hit.withReviewPending(true)
            : hit,
    ];
    return ImpactAuditResult(
      request: request,
      affectedChapters: apply(affectedChapters),
      affectedForeshadowings: apply(affectedForeshadowings),
      affectedRelations: apply(affectedRelations),
      affectedCharacters: apply(affectedCharacters),
      summary: summary,
      coverage: coverage,
      checkedCount: checkedCount,
      totalRelevantCount: totalRelevantCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'request': {
      'resourcePath': request.resourcePath,
      'resourceType': request.resourceType,
      'resourceId': request.resourceId,
      'field': request.field,
    },
    'affectedChapters': affectedChapters.map((h) => h.toJson()).toList(),
    'affectedForeshadowings': affectedForeshadowings
        .map((h) => h.toJson())
        .toList(),
    'affectedRelations': affectedRelations.map((h) => h.toJson()).toList(),
    'affectedCharacters': affectedCharacters.map((h) => h.toJson()).toList(),
    'summary': summary,
    'coverage': coverage,
    'checkedCount': checkedCount,
    'totalRelevantCount': totalRelevantCount,
  };

  /// UI 反序列化：ImpactAudits.resultJson → 审计结果（容错缺失字段）。
  factory ImpactAuditResult.fromJson(Map<String, dynamic> json) {
    List<ImpactHit> hits(String key) => [
      for (final item in (json[key] as List?) ?? const <dynamic>[])
        if (item is Map<String, dynamic>)
          ImpactHit.fromJson(item)
        else if (item is Map)
          ImpactHit.fromJson(Map<String, dynamic>.from(item)),
    ];
    final requestJson = json['request'] as Map<String, dynamic>? ?? const {};
    return ImpactAuditResult(
      request: ImpactAuditRequest(
        resourcePath: requestJson['resourcePath'] as String? ?? '',
        resourceType: requestJson['resourceType'] as String? ?? '',
        resourceId: requestJson['resourceId'] as String? ?? '',
        field: requestJson['field'] as String?,
        oldText: null,
        newText: '',
      ),
      affectedChapters: hits('affectedChapters'),
      affectedForeshadowings: hits('affectedForeshadowings'),
      affectedRelations: hits('affectedRelations'),
      affectedCharacters: hits('affectedCharacters'),
      summary: json['summary'] as String? ?? '',
      coverage: json['coverage'] as String? ?? '',
      checkedCount: (json['checkedCount'] as num?)?.toInt() ?? 0,
      totalRelevantCount: (json['totalRelevantCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 8 步流程（需求框架 M4）：
///   识别 → diff → 提取事实 → 检查人物/世界观/伏笔/时间线
///   → 找受影响章节 → 影响原因+原文证据 → 用户决定 → 存版本+审计
/// 本枚举用于审计阶段日志与 UI 步骤指示。
enum ImpactAuditStep {
  identify('识别变更'),
  diff('生成 diff'),
  extractFacts('提取事实'),
  checkEntities('检查人物/世界观/伏笔/时间线'),
  findAffected('找受影响章节'),
  collectEvidence('影响原因+原文证据'),
  userDecision('用户决定'),
  audit('存版本+审计');

  const ImpactAuditStep(this.label);
  final String label;
}

/// 单次审计的执行记录（可持久化到 WorkingChanges.summary 或独立审计表）。
class ImpactAuditRecord {
  const ImpactAuditRecord({
    required this.changeId,
    required this.result,
    required this.completedAt,
  });

  /// 关联的 WorkingChange id
  final String changeId;
  final ImpactAuditResult result;
  final DateTime completedAt;

  Map<String, dynamic> toJson() => {
    'changeId': changeId,
    'result': result.toJson(),
    'completedAt': completedAt.toIso8601String(),
  };
}