// 职责: M3 Conversation-to-Canon 编排服务 — 对话产出设定提案的匹配/冲突检查/裁决/落位。
// 关联文件:
//   lib/shared/services/conversation_to_canon_models.dart (提案模型)
//   lib/shared/services/canon_service.dart (四态正典)
//   lib/shared/services/content_lock_service.dart (canon 自动加锁)
//   lib/shared/services/novel_content.dart (落位目标 DAO)
//   lib/shared/database/novel_content_daos/content_lock_dao.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md（不新增表，复用 CanonEntries）
//
// 流程（对齐需求框架 M3）：
//   1. 输入一段对话产出（结构化提案或识别器产出）→ [analyze]
//   2. 分类（人物/世界观/剧情/伏笔/关系）→ 实体匹配 + 冲突检查 → [matchSuggestion]
//   3. 生成提案，写入 CanonEntries proposal 层（可回溯 source/session/turn）→ [propose]
//   4. 用户裁决：accept → 落位领域模块 + 升 canon + 加锁 + WorkingChange；reject → deprecated
//
// 验收：对话修改人物 → 确认后档案/关系/剧情正确落位，决策可回溯到原始会话/回合。

import 'package:drift/drift.dart' hide Column;

import '../database/novel_content_database.dart';
import '../models/content_status.dart';
import '../models/outline_draft.dart';
import '../utils/resource_path.dart';
import '../utils/short_entity_id.dart';
import 'canon_service.dart';
import 'conversation_to_canon_models.dart';
import 'novel_content.dart';

/// 提案落位失败（含原因与来源条目 id，供 UI 呈现）。
class CanonSettlementException implements Exception {
  const CanonSettlementException(this.message, {this.entryId});
  final String message;
  final String? entryId;
  @override
  String toString() => 'CanonSettlementException: $message';
}

class ConversationToCanonService {
  ConversationToCanonService({
    required this.content,
    CanonService? canonService,
    this.shortId = buildShortEntityId,
  }) : _canon = canonService ?? CanonService(content.database);

  final NovelContentService content;
  final CanonService _canon;
  final ShortEntityIdBuilder shortId;

  NovelContentDatabase get _db => content.database;

  // ---------------------------------------------------------------------------
  // 1. 实体匹配与冲突检查
  // ---------------------------------------------------------------------------

  /// 按名称/别名匹配既有实体（人物 / 设定项 / 伏笔 / 关系端点）。
  /// 返回 null 表示无匹配（可安全新建）。
  Future<CanonSuggestionMatch?> matchSuggestion(
    CanonSuggestion suggestion,
  ) async {
    final name = suggestion.title.trim();
    if (name.isEmpty) return null;

    switch (suggestion.kind) {
      case CanonSuggestionKind.character:
        final match = await _matchCharacter(name);
        return _wrap(suggestion, match?.$1, match?.$2);
      case CanonSuggestionKind.world:
        final match = await _matchItem(name);
        return _wrap(suggestion, match?.$1, match?.$2);
      case CanonSuggestionKind.foreshadow:
        final match = await _matchForeshadowing(name);
        return _wrap(suggestion, match?.$1, match?.$2);
      case CanonSuggestionKind.plot:
      case CanonSuggestionKind.relation:
        // 剧情/关系无简单名称匹配（依赖端点已存在）；交给调用方裁决。
        return _wrap(suggestion, null, null);
    }
  }

  Future<(String?, String?)?> _matchCharacter(String name) async {
    final all = await _db.characterProfileDao.getAll();
    for (final c in all) {
      if (_nameEquals(c.name, name)) return (c.id, c.name);
      // 别名匹配（曾用名/称号/昵称）
      for (final alias in c.aliases) {
        if (_nameEquals(alias, name)) return (c.id, c.name);
      }
    }
    return null;
  }

  Future<(String?, String?)?> _matchItem(String name) async {
    final all = await (_db.select(_db.items)
          ..where((t) => t.deletedAt.equals(notDeletedSentinel)))
        .get();
    for (final item in all) {
      if (_nameEquals(item.title, name)) return (item.id, item.title);
    }
    return null;
  }

  Future<(String?, String?)?> _matchForeshadowing(String name) async {
    final all = await _db.foreshadowingDao.getAll();
    for (final f in all) {
      if (_nameEquals(f.title, name)) return (f.id, f.title);
    }
    return null;
  }

  bool _nameEquals(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  CanonSuggestionMatch _wrap(
    CanonSuggestion suggestion,
    String? id,
    String? name,
  ) {
    if (id == null) return CanonSuggestionMatch(suggestion: suggestion);
    // 已存在：若提案为 create 且命中同名，标记冲突（需用户确认是复用还是改名）。
    final conflict = suggestion.action == CanonSettlementAction.create;
    return CanonSuggestionMatch(
      suggestion: suggestion,
      matchedId: id,
      matchedName: name,
      conflict: conflict,
      conflictNote: conflict
          ? '已存在同名「$name」，确认后将在既有实体上落位（不新建）。'
          : '',
    );
  }

  // ---------------------------------------------------------------------------
  // 2. 提案生成（写入 CanonEntries proposal 层）
  // ---------------------------------------------------------------------------

  /// 生成提案并写入正典 proposal 层（可回溯 source/session/turn）。
  /// 返回正典条目 id（供 UI 展示与后续裁决）。
  Future<({String entryId, CanonSuggestionMatch match})> propose({
    required CanonSuggestion suggestion,
    required String source,
    String? sourceSessionId,
    String? sourceTurnId,
  }) async {
    final match = await matchSuggestion(suggestion);
    final entry = await _canon.record(
      resourceType: suggestion.kind.resourceType,
      resourceId: match?.matchedId ?? _pendingId(suggestion.kind),
      level: canonLevelProposal,
      title: suggestion.title,
      fact: _factFromSuggestion(suggestion),
      source: source,
      sourceSessionId: sourceSessionId,
      sourceTurnId: sourceTurnId,
    );
    return (entryId: entry.id, match: match ?? CanonSuggestionMatch(suggestion: suggestion));
  }

  String _factFromSuggestion(CanonSuggestion s) {
    final buffer = StringBuffer();
    buffer.write('${s.kind.name}·${s.action.name}');
    if (s.field != null && s.field!.isNotEmpty) buffer.write('·${s.field}');
    if (s.value != null && s.value!.isNotEmpty) buffer.write('：${s.value}');
    return buffer.toString();
  }

  /// 待匹配实体的占位 id（落位时替换为真实 id）。
  String _pendingId(CanonSuggestionKind kind) => switch (kind) {
    CanonSuggestionKind.character => 'pending:${shortId(ShortEntityIdType.character)}',
    CanonSuggestionKind.world => 'pending:${shortId(ShortEntityIdType.item)}',
    CanonSuggestionKind.foreshadow =>
      'pending:${shortId(ShortEntityIdType.foreshadowing)}',
    CanonSuggestionKind.plot => 'pending:${shortId(ShortEntityIdType.outline)}',
    CanonSuggestionKind.relation =>
      'pending:${shortId(ShortEntityIdType.relation)}',
  };

  // ---------------------------------------------------------------------------
  // 3. 裁决与落位
  // ---------------------------------------------------------------------------

  /// 用户裁决单条提案。
  /// [accept] true → 落位到领域模块 + 升 canon + 加锁 + WorkingChange；
  ///          false → 废弃（deprecated，历史保留）。
  /// [targetResourceId] 落位时替换占位 id（调用方已确认新建/复用的实体 id）。
  Future<CanonSettlementOutcome> decide({
    required String entryId,
    required CanonSuggestion suggestion,
    required bool accept,
    String? targetResourceId,
    String? decisionNote,
    String? decidedBy,
    String source = 'conversation_canon',
    String? sourceSessionId,
    String? sourceTurnId,
  }) async {
    if (!accept) {
      await _canon.deprecate(
        entryId,
        decisionNote: decisionNote ?? '用户否决，不落位。',
      );
      return CanonSettlementOutcome(
        suggestion: suggestion,
        accepted: false,
        entryId: entryId,
        resourceId: targetResourceId,
        note: '已废弃',
      );
    }

    // 落位到领域模块（创建或更新），返回真实实体 id。
    final resourceId = await _settle(
      suggestion,
      targetResourceId: targetResourceId,
      source: source,
      sourceSessionId: sourceSessionId,
      sourceTurnId: sourceTurnId,
    );

    // 先把正典条目的 resourceId 指向真实实体（落位前是 pending:* 占位），
    // 再 canonize —— 其自动加锁与幂等检查会读到真实 id，而非占位 id。
    await (_db.update(_db.canonEntries)..where((t) => t.id.equals(entryId)))
        .write(CanonEntriesCompanion(resourceId: Value(resourceId)));

    // 升 canon + 自动加锁（此时 findById 已读到真实 resourceId）。
    await _canon.canonize(
      entryId: entryId,
      decisionNote: decisionNote,
      decidedBy: decidedBy ?? 'user',
    );

    return CanonSettlementOutcome(
      suggestion: suggestion,
      accepted: true,
      entryId: entryId,
      resourceId: resourceId,
      note: '已落位 $resourceId',
    );
  }

  // ---------------------------------------------------------------------------
  // 4. 落位执行
  // ---------------------------------------------------------------------------

  Future<String> _settle(
    CanonSuggestion suggestion, {
    String? targetResourceId,
    required String source,
    String? sourceSessionId,
    String? sourceTurnId,
  }) async {
    switch (suggestion.kind) {
      case CanonSuggestionKind.character:
        return _settleCharacter(suggestion, targetResourceId, source,
            sourceSessionId, sourceTurnId);
      case CanonSuggestionKind.world:
        return _settleItem(suggestion, targetResourceId, source,
            sourceSessionId, sourceTurnId);
      case CanonSuggestionKind.foreshadow:
        return _settleForeshadowing(suggestion, targetResourceId, source,
            sourceSessionId, sourceTurnId);
      case CanonSuggestionKind.plot:
        return _settleOutline(suggestion, targetResourceId, source,
            sourceSessionId, sourceTurnId);
      case CanonSuggestionKind.relation:
        return _settleRelation(suggestion, targetResourceId, source,
            sourceSessionId, sourceTurnId);
    }
  }

  Future<String> _settleCharacter(
    CanonSuggestion s,
    String? targetId,
    String source,
    String? sessionId,
    String? turnId,
  ) async {
    final id = targetId ?? shortId(ShortEntityIdType.character);
    final existing = await _db.characterProfileDao.getById(id);
    final field = s.field ?? 'biography';
    final newValue = s.value ?? '';
    final oldValue = _characterField(existing, field);

    await _db.characterProfileDao.upsert(
      _applyCharacterField(
        existing ??
            CharacterProfile(
              id: id,
              name: s.title,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              deletedAt: notDeletedSentinel,
              role: characterRoleSupporting,
              gender: characterGenderUnknown,
              aliases: const [],
              tags: const [],
              biography: '',
              appearance: '',
              description: '',
              currentState: '',
              identity: '',
              age: '未知',
              motivation: '',
              arc: '',
              personality: '',
              behaviorTags: const [],
              sortOrder: 0,
            ),
        field,
        newValue,
      ),
    );

    await _recordWorkingChange(
      resourcePath: 'characters/$id',
      resourceType: 'character',
      resourceId: id,
      field: field,
      oldText: oldValue,
      newText: newValue,
      source: source,
      sourceSessionId: sessionId,
      sourceTurnId: turnId,
      summary: '对话落位：${s.title}·$field',
    );
    return id;
  }

  String _characterField(CharacterProfile? c, String field) {
    if (c == null) return '';
    return switch (field) {
      'name' => c.name,
      'biography' => c.biography,
      'appearance' => c.appearance,
      'description' => c.description,
      'identity' => c.identity,
      'age' => c.age,
      'motivation' => c.motivation,
      'arc' => c.arc,
      'personality' => c.personality,
      _ => '',
    };
  }

  /// 对角色档案应用字段更新（不支持的字段降级为 biography）。
  CharacterProfile _applyCharacterField(
    CharacterProfile profile,
    String field,
    String value,
  ) => switch (field) {
    'name' => profile.copyWith(name: value, updatedAt: DateTime.now()),
    'biography' => profile.copyWith(biography: value, updatedAt: DateTime.now()),
    'appearance' =>
      profile.copyWith(appearance: value, updatedAt: DateTime.now()),
    'description' =>
      profile.copyWith(description: value, updatedAt: DateTime.now()),
    'identity' => profile.copyWith(identity: value, updatedAt: DateTime.now()),
    'age' => profile.copyWith(age: value, updatedAt: DateTime.now()),
    'motivation' =>
      profile.copyWith(motivation: value, updatedAt: DateTime.now()),
    'arc' => profile.copyWith(arc: value, updatedAt: DateTime.now()),
    'personality' =>
      profile.copyWith(personality: value, updatedAt: DateTime.now()),
    _ => profile.copyWith(biography: value, updatedAt: DateTime.now()),
  };

  Future<String> _settleItem(
    CanonSuggestion s,
    String? targetId,
    String source,
    String? sessionId,
    String? turnId,
  ) async {
    final id = targetId ?? shortId(ShortEntityIdType.item);
    final type = s.field ?? 'world';
    final existing = await _db.itemDao.getById(id);
    final newValue = s.value ?? '';
    final oldValue = existing?.content ?? '';
    await _db.itemDao.upsert(
      (existing ??
              Item(
                id: id,
                type: type,
                title: s.title,
                content: '',
                status: itemEntryStatusActive,
                category: '',
                sortOrder: 0,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                deletedAt: notDeletedSentinel,
              ))
          .copyWith(content: newValue, updatedAt: DateTime.now()),
    );
    await _recordWorkingChange(
      resourcePath: 'items/$id',
      resourceType: 'item',
      resourceId: id,
      field: 'content',
      oldText: oldValue,
      newText: newValue,
      source: source,
      sourceSessionId: sessionId,
      sourceTurnId: turnId,
      summary: '对话落位：${s.title}',
    );
    return id;
  }

  Future<String> _settleForeshadowing(
    CanonSuggestion s,
    String? targetId,
    String source,
    String? sessionId,
    String? turnId,
  ) async {
    final id = targetId ?? shortId(ShortEntityIdType.foreshadowing);
    final existing = await _db.foreshadowingDao.getById(id);
    final newValue = s.value ?? '';
    final oldValue = existing?.setup ?? '';
    await _db.foreshadowingDao.upsert(
      (existing ??
              Foreshadowing(
                id: id,
                title: s.title,
                setup: '',
                payoff: '',
                status: foreshadowingStatusPending,
                sortOrder: 0,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                deletedAt: notDeletedSentinel,
              ))
          .copyWith(setup: newValue, updatedAt: DateTime.now()),
    );
    await _recordWorkingChange(
      resourcePath: 'foreshadowings/$id',
      resourceType: 'foreshadowing',
      resourceId: id,
      field: 'setup',
      oldText: oldValue,
      newText: newValue,
      source: source,
      sourceSessionId: sessionId,
      sourceTurnId: turnId,
      summary: '对话落位伏笔：${s.title}',
    );
    return id;
  }

  Future<String> _settleOutline(
    CanonSuggestion s,
    String? targetId,
    String source,
    String? sessionId,
    String? turnId,
  ) async {
    final id = targetId ?? shortId(ShortEntityIdType.outline);
    final newValue = s.value ?? '';
    await _db.into(_db.outlines).insert(
          OutlinesCompanion.insert(
            documentId: id,
            title: Value(s.title),
            content: Value(newValue),
            status: const Value(outlineStatusPending),
          ),
        );
    await _recordWorkingChange(
      resourcePath: 'outlines/$id',
      resourceType: 'outline',
      resourceId: id,
      field: 'content',
      oldText: null,
      newText: newValue,
      source: source,
      sourceSessionId: sessionId,
      sourceTurnId: turnId,
      summary: '对话落位大纲：${s.title}',
    );
    return id;
  }

  Future<String> _settleRelation(
    CanonSuggestion s,
    String? targetId,
    String source,
    String? sessionId,
    String? turnId,
  ) async {
    // 关系落位需源/目标端点均已存在；否则由调用方在 targetResourceId 中
    // 以 "sourceId|relationType|targetId" 形式传入。
    if (targetId == null || !targetId.contains('|')) {
      throw const CanonSettlementException(
        '关系落位需要 targetResourceId = "sourceId|relationType|targetId"。',
      );
    }
    final parts = targetId.split('|');
    if (parts.length != 3) {
      throw const CanonSettlementException(
        '关系落位 targetResourceId 格式错误（期望 sourceId|relationType|targetId）。',
      );
    }
    final relationId = await content.entityRelationsService.createRelation(
      sourceType: entityTypeCharacter,
      sourceId: parts[0],
      targetType: entityTypeCharacter,
      targetId: parts[2],
      relationType: parts[1],
      proof: s.value ?? '对话落位',
    );
    await _recordWorkingChange(
      resourcePath: 'relations/$relationId',
      resourceType: 'relation',
      resourceId: relationId,
      field: 'relationType',
      oldText: null,
      newText: parts[1],
      source: source,
      sourceSessionId: sessionId,
      sourceTurnId: turnId,
      summary: '对话落位关系：${parts[0]}·${parts[1]}·${parts[2]}',
    );
    return relationId;
  }

  // ---------------------------------------------------------------------------
  // 5. 变更记录（可回溯来源）
  // ---------------------------------------------------------------------------

  Future<void> _recordWorkingChange({
    required String resourcePath,
    required String resourceType,
    required String? resourceId,
    required String? field,
    required String? oldText,
    required String? newText,
    required String source,
    String? sourceSessionId,
    String? sourceTurnId,
    required String summary,
  }) async {
    await _db.into(_db.workingChanges).insert(
          WorkingChangesCompanion.insert(
            id: 'wch_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
            resourcePath: canonicalResourcePath(resourcePath),
            resourceType: resourceType,
            resourceId: Value(resourceId),
            field: Value(field),
            changeType: 'canon_settlement',
            source: source,
            sourceSessionId: Value(sourceSessionId),
            sourceTurnId: Value(sourceTurnId),
            summary: Value(summary),
            oldText: Value(oldText),
            newText: Value(newText),
            status: const Value('committed'),
          ),
        );
  }
}
