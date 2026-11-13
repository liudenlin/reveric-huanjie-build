// 职责: M6d Context Packet — 每次模型调用动态组装的结构化上下文包（专项设计 §7.5）
// 关联文件:
//   lib/shared/services/ai/context_packet_builder.dart (组装器)
//   lib/shared/services/ai/prompts/prompt_composer.dart (渲染约定)
//   lib/shared/services/ai/context_models.dart (既有 AiSessionContext)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（专项设计 §7.5）：每次模型调用动态组装，不将所有小说文件不加筛选地
//   丢给模型；12 个 section 各自携带 sourceRevision 用于后续审计；
//   检索结果二次通过「允许发送给模型」过滤器，不因语义索引存在就泄露。
//
// 本文件只承载纯数据模型，不依赖数据库类型（evidence 等以渲染文本表达），
// 便于单元测试与审计序列化。

/// Context Packet 的固定 section 顺序与标题（对齐 §7.5 的 12 个字段）。
const List<String> contextPacketSectionOrder = <String>[
  'task',
  'currentObject',
  'canon',
  'chronology',
  'characterKnowledge',
  'readerKnowledge',
  'outline',
  'evidence',
  'locks',
  'style',
  'conflicts',
  'policy',
];

const Map<String, String> contextPacketSectionTitles = <String, String>{
  'task': '任务目标与审批模式',
  'currentObject': '当前对象与版本',
  'canon': '相关正典、设定与人物状态',
  'chronology': '故事时间与阅读顺序',
  'characterKnowledge': '角色当前知晓信息',
  'readerKnowledge': '读者已知/未知/误解',
  'outline': '总纲/卷纲/章纲授权部分',
  'evidence': '原文与研究证据锚点',
  'locks': '硬锁/审批锁/例外规则',
  'style': '写作风格与 Skill',
  'conflicts': '未处理审计发现',
  'policy': '模型/权限/token 预算/禁止工具',
};

/// 单个上下文字段：内容 + 来源修订（§7.5 所有上下文携带 sourceRevision）。
class ContextPacketField {
  const ContextPacketField({
    required this.key,
    required this.content,
    this.sourceRevision = '',
  });

  /// section key（对齐 [contextPacketSectionOrder]）。
  final String key;

  /// 已渲染的文本内容（空串表示该 section 无数据，不进入 prompt）。
  final String content;

  /// 该字段的数据源修订（用于后续审计：数据来自哪个版本的哪个对象）。
  final String sourceRevision;

  bool get isEmpty => content.trim().isEmpty;
}

/// §7.5 动态上下文包。
///
/// 12 个字段按固定顺序渲染为模型提示词；空字段跳过。整个包携带
/// [packetRevision]（组合各字段 sourceRevision），供写入审计追踪。
class ContextPacket {
  ContextPacket({
    required List<ContextPacketField> fields,
    this.approvalMode = 'none',
    this.buildNote = '',
  }) : fields = List.unmodifiable(fields) {
    _revision = _composeRevision();
  }

  /// 按 [contextPacketSectionOrder] 顺序排列的字段集合（缺省字段自动补空）。
  final List<ContextPacketField> fields;

  /// 审批模式：none / user_confirm / author_only（§7.5 task 的一部分）。
  final String approvalMode;

  /// 构建备注（如检索 query、目标对象），仅供诊断，不进入 prompt。
  final String buildNote;

  late final String _revision;

  /// 包级版本指纹（组合各字段 sourceRevision + approvalMode，用于审计）。
  String get packetRevision => _revision;

  ContextPacketField _field(String key) {
    for (final f in fields) {
      if (f.key == key) {
        return f;
      }
    }
    return ContextPacketField(key: key, content: '');
  }

  String get task => _field('task').content;
  String get currentObject => _field('currentObject').content;
  String get canon => _field('canon').content;
  String get chronology => _field('chronology').content;
  String get characterKnowledge => _field('characterKnowledge').content;
  String get readerKnowledge => _field('readerKnowledge').content;
  String get outline => _field('outline').content;
  String get evidence => _field('evidence').content;
  String get locks => _field('locks').content;
  String get style => _field('style').content;
  String get conflicts => _field('conflicts').content;
  String get policy => _field('policy').content;

  /// 各字段的 sourceRevision 映射（key → revision），供审计。
  Map<String, String> get sourceRevisions => {
    for (final f in fields)
      if (f.sourceRevision.isNotEmpty) f.key: f.sourceRevision,
  };

  bool get isEmpty => fields.every((f) => f.isEmpty);

  int get totalChars => fields.fold<int>(0, (sum, f) => sum + f.content.length);

  /// 渲染为模型提示词文本（按固定顺序，空字段跳过，分隔符对齐 prompt 约定）。
  String toPromptText({String separator = '\n\n---\n\n'}) {
    final rendered = <String>[];
    for (final key in contextPacketSectionOrder) {
      final field = _field(key);
      if (field.isEmpty) {
        continue;
      }
      final title = contextPacketSectionTitles[key] ?? key;
      final buffer = StringBuffer();
      buffer.writeln('# $title');
      buffer.writeln();
      buffer.write(field.content.trim());
      rendered.add(buffer.toString().trim());
    }
    return rendered.join(separator).trim();
  }

  /// 审计序列化（不进入模型，仅持久化/追踪用）。
  Map<String, dynamic> toJson() => {
    'packetRevision': packetRevision,
    'approvalMode': approvalMode,
    'buildNote': buildNote,
    'fields': {
      for (final key in contextPacketSectionOrder)
        key: {
          'content': _field(key).content,
          if (_field(key).sourceRevision.isNotEmpty)
            'sourceRevision': _field(key).sourceRevision,
        },
    },
  };

  String _composeRevision() {
    final buffer = StringBuffer(approvalMode);
    for (final key in contextPacketSectionOrder) {
      final field = _field(key);
      if (field.sourceRevision.isNotEmpty) {
        buffer.write('|$key=${field.sourceRevision}');
      }
    }
    return buffer.toString();
  }
}

/// §7.5「允许发送给模型」可见性过滤器。
///
/// 默认允许全部；未来接入 AI Never / 隐藏段落规则时，实现具体过滤逻辑，
/// 在 [ContextPacketBuilder] 组装 evidence/canon 时应用，避免语义检索
/// 绕过作者隐藏规则（§8.4：不能因索引存在就泄露）。
abstract class ContextVisibilityFilter {
  bool isAllowed({
    required String sourceType,
    required String sourceId,
    required String anchor,
  });
}

/// 默认过滤器：放行一切（未接入隐藏规则前保持全可见）。
class AllowAllVisibilityFilter implements ContextVisibilityFilter {
  const AllowAllVisibilityFilter();

  @override
  bool isAllowed({
    required String sourceType,
    required String sourceId,
    required String anchor,
  }) =>
      true;
}
