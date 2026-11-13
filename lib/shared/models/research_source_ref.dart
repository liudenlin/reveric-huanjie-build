// 职责: R-37 研究来源引用模型 — 记录 URL/检索时间/标题/摘要/引用位置/许可与时效性。
// 关联文件:
//   lib/shared/services/research_task_service.dart (addSourceRef/listSourceRefs)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（来源存 ResearchTasks.metadataJson['sources']，不动表结构）
//
// 验收（R-37）：来源记录 URL/检索时间/标题/摘要/引用位置/许可版权；
//   记录获取时间标记时效性；未经核验的信息不得当成确定事实（verified=false 展示为"待核验"）。

/// 一条研究来源记录。
class ResearchSourceRef {
  const ResearchSourceRef({
    this.url,
    required this.retrievedAt,
    required this.title,
    this.summary = '',
    this.quotePosition,
    this.licenseStatus,
    this.accessType,
    this.verified = false,
  });

  /// 来源 URL（可为空：本地文档/书目条目没有 URL）。
  final String? url;

  /// 检索/获取时间（标记时效性）。
  final DateTime retrievedAt;

  /// 来源标题。
  final String title;

  /// 摘要（一句话概括）。
  final String summary;

  /// 引用位置（如 "第 2 章 设定「星核」段落"）。
  final String? quotePosition;

  /// 许可/版权：'public_domain' / 'authorized_copy' / 'unknown'（默认）。
  final String? licenseStatus;

  /// 访问类型：'public' / 'paywalled' / 'login_required' —— 记录是否绕过付费墙的行为边界。
  final String? accessType;

  /// 是否经作者核验。false 的来源**不得**展示为确定事实（R-37 语义）。
  final bool verified;

  /// 深度拷贝并更新任一字段（author 核验后标记 verified=true）。
  ResearchSourceRef copyWith({
    String? url,
    DateTime? retrievedAt,
    String? title,
    String? summary,
    String? quotePosition,
    String? licenseStatus,
    String? accessType,
    bool? verified,
  }) {
    return ResearchSourceRef(
      url: url ?? this.url,
      retrievedAt: retrievedAt ?? this.retrievedAt,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      quotePosition: quotePosition ?? this.quotePosition,
      licenseStatus: licenseStatus ?? this.licenseStatus,
      accessType: accessType ?? this.accessType,
      verified: verified ?? this.verified,
    );
  }

  Map<String, dynamic> toJson() => {
    if (url != null) 'url': url,
    'retrieved_at': retrievedAt.millisecondsSinceEpoch ~/ 1000,
    'title': title,
    'summary': summary,
    if (quotePosition != null) 'quote_position': quotePosition,
    if (licenseStatus != null) 'license_status': licenseStatus,
    if (accessType != null) 'access_type': accessType,
    'verified': verified,
  };

  factory ResearchSourceRef.fromJson(Map<String, dynamic> json) {
    return ResearchSourceRef(
      url: json['url'] is String ? json['url'] as String : null,
      retrievedAt: _readDateTime(json['retrieved_at']) ?? DateTime.now(),
      title: json['title'] is String ? json['title'] as String : '',
      summary: json['summary'] is String ? json['summary'] as String : '',
      quotePosition: json['quote_position'] is String
          ? json['quote_position'] as String
          : null,
      licenseStatus: json['license_status'] is String
          ? json['license_status'] as String
          : null,
      accessType:
          json['access_type'] is String ? json['access_type'] as String : null,
      verified: json['verified'] == true,
    );
  }
}

DateTime? _readDateTime(Object? value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value * 1000);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000);
  }
  return null;
}