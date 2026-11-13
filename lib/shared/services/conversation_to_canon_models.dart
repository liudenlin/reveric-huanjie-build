// 职责: M3 Conversation-to-Canon 数据模型 — 对话产出的设定提案与落位结果。
// 关联文件:
//   lib/shared/services/conversation_to_canon_service.dart (编排服务)
//   lib/shared/database/novel_content_database.dart (CanonEntries 表)
// 设计要点:
//   提案 = 对话中识别出的一条「建议落位的设定事实」。
//   每个提案在落位前先进入 CanonEntries 的 proposal/discussion 层（可回溯），
//   用户裁决后：accept → 写领域模块 + 升 canon + 加锁；reject → deprecated。
// 类别映射到领域模块:
//   character   → CharacterProfiles（人物档案）
//   world       → Items（世界观/设定项，type='world'）
//   plot        → Outlines 或 Chapters（剧情大纲落位）
//   foreshadow  → Foreshadowings（伏笔）
//   relation    → EntityRelations（人物/势力关系）

/// 对话产出提案的类别（决定落位目标模块）。
enum CanonSuggestionKind {
  character,
  world,
  plot,
  foreshadow,
  relation;

  /// 领域资源类型（用于 CanonEntries.resourceType 与落位路径）。
  String get resourceType => switch (this) {
    CanonSuggestionKind.character => 'character',
    CanonSuggestionKind.world => 'item',
    CanonSuggestionKind.plot => 'outline',
    CanonSuggestionKind.foreshadow => 'foreshadowing',
    CanonSuggestionKind.relation => 'relation',
  };
}

/// 落位动作：新建 / 更新已有实体。
enum CanonSettlementAction { create, update }

/// 一次对话产出的设定提案（已分类，待匹配与裁决）。
class CanonSuggestion {
  const CanonSuggestion({
    required this.kind,
    required this.action,
    required this.title,
    this.existingId,
    this.field,
    this.value,
    this.priority = 0,
    this.explanation = '',
  });

  final CanonSuggestionKind kind;

  /// 落位动作
  final CanonSettlementAction action;

  /// 实体名称/标题（如「林晚」「断水剑」）
  final String title;

  /// 匹配到的既有实体 ID（update 时非空）
  final String? existingId;

  /// 落位字段名（如 biography/appearance/relationType）
  final String? field;

  /// 落位字段值（新值文本）
  final String? value;

  /// 提案优先级（高值先处理）
  final int priority;

  /// 识别依据（模型从对话摘录的证据句）
  final String explanation;

  CanonSuggestion copyWith({
    CanonSettlementAction? action,
    String? existingId,
    String? field,
    String? value,
  }) => CanonSuggestion(
    kind: kind,
    action: action ?? this.action,
    title: title,
    existingId: existingId ?? this.existingId,
    field: field ?? this.field,
    value: value ?? this.value,
    priority: priority,
    explanation: explanation,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'action': action.name,
    'title': title,
    'existingId': existingId,
    'field': field,
    'value': value,
    'priority': priority,
    'explanation': explanation,
  };
}

/// 提案与既有实体的匹配/冲突检查结果。
class CanonSuggestionMatch {
  const CanonSuggestionMatch({
    required this.suggestion,
    this.matchedId,
    this.matchedName,
    this.conflict = false,
    this.conflictNote = '',
  });

  final CanonSuggestion suggestion;

  /// 匹配到的既有实体 ID（无匹配为 null，表示新建）
  final String? matchedId;

  /// 匹配到的实体名称
  final String? matchedName;

  /// 是否检测到冲突（同名不同实 / 与 canon 正典冲突）
  final bool conflict;

  /// 冲突说明
  final String conflictNote;

  CanonSuggestionMatch copyWith({
    String? matchedId,
    String? matchedName,
    bool? conflict,
    String? conflictNote,
  }) => CanonSuggestionMatch(
    suggestion: suggestion,
    matchedId: matchedId ?? this.matchedId,
    matchedName: matchedName ?? this.matchedName,
    conflict: conflict ?? this.conflict,
    conflictNote: conflictNote ?? this.conflictNote,
  );
}

/// 单个提案的裁决结果。
class CanonSettlementOutcome {
  const CanonSettlementOutcome({
    required this.suggestion,
    required this.accepted,
    required this.entryId,
    this.resourceId,
    this.note = '',
  });

  final CanonSuggestion suggestion;
  final bool accepted;
  final String entryId;
  final String? resourceId;
  final String note;

  Map<String, dynamic> toJson() => {
    'accepted': accepted,
    'entryId': entryId,
    'resourceId': resourceId,
    'note': note,
    'suggestion': suggestion.toJson(),
  };
}
