// 职责: 记忆写入路由 — 提交变更后同步正典条目并做跨章一致性校验
// 关联文件:
//   lib/shared/services/novel_content.dart
//   lib/shared/services/canon_service.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/impact_audit_service.dart

import 'package:drift/drift.dart' hide Column;

import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import 'canon_service.dart';
import 'novel_content.dart';

final _log = AppLogger.forModule('MemoryWriteRouter');

/// 本路由写入正典时使用的来源标识（存入 CanonEntries.source）。
const String memoryWriteRouterSource = 'memory_write_router';

/// 支持自动同步正典的资源类型（单数，与 ContentLockService 口径一致）。
const Set<String> memoryWriteRouterResourceTypes = <String>{
  'chapter',
  'character',
  'foreshadowing',
  'item',
  'location',
  'relation',
};

/// 跨章一致性问题的种类。
enum ConsistencyIssueKind {
  /// 伏笔回收：payoff 指向的章节/段落缺失，或 status 与回收引用不匹配。
  foreshadowPayoff,

  /// 设定吃书：正典条目 fact 与当前对象关键字段冲突。
  settingContradiction,
}

/// 单条跨章一致性问题。
class ConsistencyIssue {
  const ConsistencyIssue({
    required this.kind,
    required this.resourceType,
    required this.resourceId,
    required this.message,
    this.detail,
  });

  final ConsistencyIssueKind kind;
  final String resourceType;
  final String resourceId;
  final String message;

  /// 可选补充说明（如缺失的章节 ID、字段差异摘要）。
  final String? detail;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        'resourceType': resourceType,
        'resourceId': resourceId,
        'message': message,
        if (detail != null) 'detail': detail,
      };

  @override
  String toString() =>
      'ConsistencyIssue(${kind.name}, $resourceType/$resourceId, $message)';
}

/// 一次跨章一致性校验的结果。
class ConsistencyCheckResult {
  const ConsistencyCheckResult({required this.issues});

  final List<ConsistencyIssue> issues;

  bool get isEmpty => issues.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'issues': issues.map((e) => e.toJson()).toList(),
      };
}

/// 一次正典同步的结果，供调用方记日志或断言。
class MemoryWriteOutcome {
  const MemoryWriteOutcome({
    required this.status,
    required this.resourceType,
    required this.resourceId,
    this.canonEntryId,
    this.consistency = const ConsistencyCheckResult(issues: []),
  });

  /// skipped：对象缺失或类型不支持；created：新建正典条目；
  /// updated：更新本路由此前写入的条目；unchanged：条目已一致。
  final String status;
  final String resourceType;
  final String resourceId;
  final String? canonEntryId;
  final ConsistencyCheckResult consistency;

  bool get hasConsistencyIssues => !consistency.isEmpty;
}

/// 正典写入路由：把已提交的章节/人物/伏笔/道具/地点/关系变更同步到 CanonEntries，
/// 并对伏笔回收、设定吃书做跨章一致性校验。
///
/// 保守策略：
/// - 资源尚无正典条目时，新建 discussion 层条目，source 固定为
///   [memoryWriteRouterSource]（可附带段落锚点）。
/// - 已有条目时，只有该条目仍由本路由持有（source 匹配且未被用户裁决、
///   未废弃）且 fact 确实变化时才更新；用户手动 decide/deprecate 的层级一律不覆盖。
class MemoryWriteRouter {
  MemoryWriteRouter(this._content, {CanonService? canonService})
      : _canon = canonService ?? CanonService(_content.database);

  final NovelContentService _content;
  final CanonService _canon;

  NovelContentDatabase get _db => _content.database;

  /// 处理一次已提交的变更。任何失败都不应阻断调用方的保存流程，
  /// 调用方需自行 try/catch 并只记日志。
  Future<MemoryWriteOutcome> handleCommittedChange({
    required String resourceType,
    required String resourceId,
    String? resourcePath,
    String? source,
    String? sourceTurnId,
    String? sourceAnchor,
  }) async {
    final type = normalizeResourceType(resourceType);
    if (!memoryWriteRouterResourceTypes.contains(type) ||
        resourceId.trim().isEmpty) {
      return MemoryWriteOutcome(
        status: 'skipped',
        resourceType: type,
        resourceId: resourceId,
      );
    }

    final fact = await _buildFact(type, resourceId);
    if (fact == null) {
      // 对象不存在（可能已被删除）：不抛异常，返回 skipped 让调用方记日志。
      return MemoryWriteOutcome(
        status: 'skipped',
        resourceType: type,
        resourceId: resourceId,
      );
    }

    final existing = await _canon.currentFor(type, resourceId);
    String? entryId;
    String status = 'unchanged';
    if (existing == null) {
      final created = await _insertEntry(
        type: type,
        resourceId: resourceId,
        fact: fact,
        sourceAnchor: sourceAnchor,
        sourceTurnId: sourceTurnId,
      );
      entryId = created.id;
      status = 'created';
    } else if (_isRouterOwned(existing) && existing.fact != fact) {
      await (_db.update(_db.canonEntries)..where((t) => t.id.equals(existing.id)))
          .write(
        CanonEntriesCompanion(
          fact: Value(fact),
          source: Value(_composeSource(sourceAnchor)),
          sourceTurnId: sourceTurnId == null
              ? const Value.absent()
              : Value(sourceTurnId),
          updatedAt: Value(DateTime.now()),
        ),
      );
      entryId = existing.id;
      status = 'updated';
    } else {
      entryId = existing.id;
    }

    final consistency = await checkConsistency(
      resourceType: type,
      resourceId: resourceId,
    );
    if (consistency.issues.isNotEmpty) {
      _log.warning(
        '[MemoryRouter] consistency issues resource=$type/$resourceId '
        'issues=${consistency.issues.map((e) => e.toString()).join('; ')}',
      );
    }
    return MemoryWriteOutcome(
      status: status,
      resourceType: type,
      resourceId: resourceId,
      canonEntryId: entryId,
      consistency: consistency,
    );
  }

  /// 跨章一致性校验入口，可独立调用（不必经过正典写入）。
  Future<ConsistencyCheckResult> checkConsistency({
    required String resourceType,
    required String resourceId,
  }) async {
    final type = normalizeResourceType(resourceType);
    final issues = <ConsistencyIssue>[];
    if (type == 'foreshadowing') {
      issues.addAll(await _checkForeshadowingPayoff(resourceId));
    }
    final contradiction = await _checkSettingContradiction(type, resourceId);
    if (contradiction != null) {
      issues.add(contradiction);
    }
    // 时间线冲突：当前 Chapters 表没有顺序之外的时间字段（无 startDate/时间线列），
    // 同卷章节「声明时间 vs 顺序」无法比对，此处按约定返回空，待时间线字段落地后补充。
    return ConsistencyCheckResult(issues: issues);
  }

  // ---------------------------------------------------------------------------
  // 正典条目写入
  // ---------------------------------------------------------------------------

  bool _isRouterOwned(CanonEntry entry) =>
      (entry.source == memoryWriteRouterSource ||
              entry.source.startsWith('$memoryWriteRouterSource:')) &&
          entry.decidedBy == null &&
          entry.level != canonLevelDeprecated;

  String _composeSource(String? anchor) => anchor == null || anchor.isEmpty
      ? memoryWriteRouterSource
      : '$memoryWriteRouterSource:<$anchor>';

  Future<CanonEntry> _insertEntry({
    required String type,
    required String resourceId,
    required String fact,
    required String? sourceAnchor,
    required String? sourceTurnId,
  }) async {
    final now = DateTime.now();
    final id = 'cn_${now.microsecondsSinceEpoch.toRadixString(36)}';
    await _db.into(_db.canonEntries).insert(
          CanonEntriesCompanion.insert(
            id: id,
            resourceType: type,
            resourceId: resourceId,
            level: canonLevelDiscussion,
            title: Value(await _buildTitle(type, resourceId)),
            fact: Value(fact),
            source: _composeSource(sourceAnchor),
            sourceTurnId:
                sourceTurnId == null ? const Value.absent() : Value(sourceTurnId),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    return (await _db.canonEntryDao.findById(id))!;
  }

  Future<String> _buildTitle(String type, String resourceId) async {
    switch (type) {
      case 'chapter':
        final chapter = await _content.getChapterById(resourceId);
        return chapter?.title ?? '';
      case 'character':
        return (await _content.getCharacterProfileById(resourceId))?.name ?? '';
      case 'foreshadowing':
        return (await _content.getForeshadowingById(resourceId))?.title ?? '';
      case 'item':
        return (await _content.getItemById(resourceId))?.title ?? '';
      case 'location':
        return (await _content.locationsService.getLocationById(resourceId))
                ?.name ??
            '';
      case 'relation':
        final relation = await _loadRelation(resourceId);
        return relation?.relationType ?? '';
    }
    return '';
  }

  /// 汇总当前对象的关键字段为 fact 文本，用于正典条目和吃书检测。
  /// 对象缺失时返回 null（由调用方决定跳过）。
  Future<String?> _buildFact(String type, String resourceId) async {
    switch (type) {
      case 'chapter':
        final chapter = await _content.getChapterById(resourceId);
        if (chapter == null) return null;
        return _joinFacts([
          'title=${chapter.title ?? ''}',
          'outline=${chapter.outline}',
          'content=${chapter.content}',
        ]);
      case 'character':
        final profile = await _content.getCharacterProfileById(resourceId);
        if (profile == null) return null;
        return _joinFacts([
          'name=${profile.name}',
          'role=${profile.role}',
          'gender=${profile.gender}',
          'identity=${profile.identity}',
          'age=${profile.age}',
          'motivation=${profile.motivation}',
          'biography=${profile.biography}',
        ]);
      case 'foreshadowing':
        final f = await _content.getForeshadowingById(resourceId);
        if (f == null) return null;
        return _joinFacts([
          'title=${f.title}',
          'setup=${f.setup}',
          'payoff=${f.payoff}',
          'setupChapterId=${f.setupChapterId ?? ''}',
          'payoffChapterId=${f.payoffChapterId ?? ''}',
          'status=${f.status}',
        ]);
      case 'item':
        final item = await _content.getItemById(resourceId);
        if (item == null) return null;
        return _joinFacts([
          'type=${item.type}',
          'title=${item.title}',
          'category=${item.category}',
          'content=${item.content}',
        ]);
      case 'location':
        final location =
            await _content.locationsService.getLocationById(resourceId);
        if (location == null) return null;
        return _joinFacts([
          'name=${location.name}',
          'type=${location.type}',
          'parentId=${location.parentId ?? ''}',
          'description=${location.description}',
        ]);
      case 'relation':
        final relation = await _loadRelation(resourceId);
        if (relation == null) return null;
        return _joinFacts([
          'source=${relation.sourceType}/${relation.sourceId}',
          'target=${relation.targetType}/${relation.targetId}',
          'relationType=${relation.relationType}',
          'status=${relation.status}',
          'chapterId=${relation.chapterId ?? ''}',
        ]);
    }
    return null;
  }

  String _joinFacts(List<String> parts) =>
      parts.where((e) => e.isNotEmpty).join('\u0001');

  Future<RelationSummary?> _loadRelation(String id) =>
      _content.entityRelationsService.getRelationSummaryById(id);

  // ---------------------------------------------------------------------------
  // 跨章一致性检查
  // ---------------------------------------------------------------------------

  /// 伏笔回收检查：payoffChapterId 指向的章节必须存在；payoffSceneId 若能解析
  /// 也应存在；status=payoff 要求至少有回收章节或回收文本，反之有回收引用却
  /// 仍标 pending/planted 也算不一致。
  Future<List<ConsistencyIssue>> _checkForeshadowingPayoff(String id) async {
    final f = await _content.getForeshadowingById(id);
    if (f == null) {
      return const [];
    }
    final issues = <ConsistencyIssue>[];
    final payoffChapterId = f.payoffChapterId;
    if (payoffChapterId != null && payoffChapterId.isNotEmpty) {
      final chapter = await _content.getChapterById(payoffChapterId);
      if (chapter == null) {
        issues.add(ConsistencyIssue(
          kind: ConsistencyIssueKind.foreshadowPayoff,
          resourceType: 'foreshadowing',
          resourceId: id,
          message: '伏笔回收章节不存在',
          detail: 'payoffChapterId=$payoffChapterId',
        ));
      }
    }
    final payoffSceneId = f.payoffSceneId;
    if (payoffSceneId != null && payoffSceneId.isNotEmpty) {
      final paragraph =
          await _db.chapterParagraphDao.getByParagraphId(payoffSceneId);
      if (paragraph == null) {
        issues.add(ConsistencyIssue(
          kind: ConsistencyIssueKind.foreshadowPayoff,
          resourceType: 'foreshadowing',
          resourceId: id,
          message: '伏笔回收段落锚点不存在',
          detail: 'payoffSceneId=$payoffSceneId',
        ));
      }
    }
    final hasPayoffRef =
        (payoffChapterId != null && payoffChapterId.isNotEmpty) ||
            (payoffSceneId != null && payoffSceneId.isNotEmpty);
    final statusIsPayoff = f.status == foreshadowingStatusPayoff;
    if (statusIsPayoff &&
        !hasPayoffRef &&
        f.payoff.trim().isEmpty) {
      issues.add(ConsistencyIssue(
        kind: ConsistencyIssueKind.foreshadowPayoff,
        resourceType: 'foreshadowing',
        resourceId: id,
        message: '伏笔标记为已回收但缺少回收章节/段落/文本',
      ));
    }
    if (!statusIsPayoff &&
        f.status != foreshadowingStatusAbandoned &&
        hasPayoffRef) {
      issues.add(ConsistencyIssue(
        kind: ConsistencyIssueKind.foreshadowPayoff,
        resourceType: 'foreshadowing',
        resourceId: id,
        message: '伏笔已填写回收引用但状态仍非 payoff',
        detail: 'status=${f.status}',
      ));
    }
    return issues;
  }

  /// 设定吃书检查：同一资源已有正典条目且 fact 与当前对象关键字段不一致。
  /// 用户裁决过的条目同样会报告（只报告，不覆盖）。
  Future<ConsistencyIssue?> _checkSettingContradiction(
    String type,
    String resourceId,
  ) async {
    final existing = await _canon.currentFor(type, resourceId);
    if (existing == null || existing.level == canonLevelDeprecated) {
      return null;
    }
    final fact = await _buildFact(type, resourceId);
    if (fact == null || fact == existing.fact) {
      return null;
    }
    return ConsistencyIssue(
      kind: ConsistencyIssueKind.settingContradiction,
      resourceType: type,
      resourceId: resourceId,
      message: '正典条目与当前对象关键字段冲突（设定吃书）',
      detail: 'canonLevel=${existing.level}',
    );
  }
}

/// 资源类型归一化：兼容路径复数段名与锁定口径单数名。
String normalizeResourceType(String raw) {
  switch (raw) {
    case 'chapters':
      return 'chapter';
    case 'characters':
      return 'character';
    case 'foreshadowings':
      return 'foreshadowing';
    case 'items':
      return 'item';
    case 'locations':
      return 'location';
    case 'relations':
      return 'relation';
    default:
      return raw;
  }
}
