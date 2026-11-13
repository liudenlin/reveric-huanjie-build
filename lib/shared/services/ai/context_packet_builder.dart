// 职责: M6d ContextPacketBuilder — 从内容库各 DAO/服务动态组装 §7.5 的 12 字段上下文包。
// 关联文件:
//   lib/shared/services/ai/context_packet.dart (ContextPacket 模型)
//   lib/shared/database/novel_content_database.dart (全部表)
//   lib/shared/services/canon_service.dart / content_lock_service.dart (M2)
//   lib/shared/services/impact_audit_service.dart (M4)
//   lib/shared/services/embedding/embedding_search_service.dart (M6a)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（专项设计 §7.5）：任务/当前对象/正典/编年史/角色认知/读者认知/
//   大纲/证据/锁/风格/冲突/策略 12 字段动态组装；每字段携带 sourceRevision；
//   检索结果二次过可见性过滤器；不将所有小说文件不加筛选丢给模型。

import 'dart:convert';

import '../../database/novel_content_database.dart';
import '../canon_service.dart';
import '../content_lock_service.dart';
import '../embedding/embedding_search_service.dart';
import 'context_packet.dart';

/// §7.5 组装器的构建请求：调用方提供「任务目标」与「当前对象」，
/// 其余字段由 Builder 从数据库动态补全。
class ContextPacketBuildRequest {
  const ContextPacketBuildRequest({
    required this.task,
    this.approvalMode = 'none',
    this.currentObjectType,
    this.currentObjectId,
    this.projectId,
    this.readerSubject = 'reader',
    this.evidenceQuery,
    this.evidenceLimit = 6,
    this.canonLimit = 12,
    this.chronologyLimit = 20,
    this.characterKnowledgeLimit = 12,
    this.readerKnowledgeLimit = 12,
    this.outlineLimit = 8,
    this.lockLimit = 12,
    this.conflictLimit = 10,
    this.styleLimit = 8,
  });

  /// 任务目标（§7.5 task：任务目标和审批模式）。
  final String task;

  /// 审批模式：none / user_confirm / author_only。
  final String approvalMode;

  /// 当前对象类型（chapter / character / item / scene / outline …）。
  final String? currentObjectType;

  /// 当前对象 ID。
  final String? currentObjectId;

  /// 项目 ID（用于弧线/人物等按项目过滤）。
  final String? projectId;

  /// 读者主体标记（ReaderPerspectives.subject，默认 'reader'）。
  final String readerSubject;

  /// 语义检索查询词（evidence 字段）；空则跳过检索。
  final String? evidenceQuery;

  final int evidenceLimit;
  final int canonLimit;
  final int chronologyLimit;
  final int characterKnowledgeLimit;
  final int readerKnowledgeLimit;
  final int outlineLimit;
  final int lockLimit;
  final int conflictLimit;
  final int styleLimit;
}

/// §7.5 Context Packet 动态组装器。
class ContextPacketBuilder {
  ContextPacketBuilder(
    this.db, {
    EmbeddingSearchService? embedding,
    ContextVisibilityFilter visibilityFilter = const AllowAllVisibilityFilter(),
  })  : _embedding = embedding,
        _visibilityFilter = visibilityFilter;

  final NovelContentDatabase db;
  final EmbeddingSearchService? _embedding;
  final ContextVisibilityFilter _visibilityFilter;

  CanonService get _canon => CanonService(db);
  ContentLockService get _locks => ContentLockService(db);

  /// 组装完整的 ContextPacket（12 字段）。
  Future<ContextPacket> build(ContextPacketBuildRequest request) async {
    final fields = <ContextPacketField>[];

    // —— task：调用方提供 ——
    fields.add(ContextPacketField(
      key: 'task',
      content: _renderTask(request),
      sourceRevision: 'request',
    ));

    // —— currentObject：当前正文/人物/场景及版本 ——
    fields.add(await _buildCurrentObject(request));

    // —— canon：正式规则、设定、人物状态 ——
    fields.add(await _buildCanon(request));

    // —— chronology：故事时间与阅读顺序 ——
    fields.add(await _buildChronology(request));

    // —— characterKnowledge：角色当前知晓的信息 ——
    fields.add(await _buildCharacterKnowledge(request));

    // —— readerKnowledge：读者已知/未知/误解 ——
    fields.add(await _buildReaderKnowledge(request));

    // —— outline：总纲/卷纲/章纲授权相关部分 ——
    fields.add(await _buildOutline(request));

    // —— evidence：原文与研究证据锚点 ——
    fields.add(await _buildEvidence(request));

    // —— locks：硬锁、审批锁、例外规则 ——
    fields.add(await _buildLocks(request));

    // —— style：已固定版本的项目写作风格 ——
    fields.add(await _buildStyle(request));

    // —— conflicts：尚未处理的审计发现 ——
    fields.add(await _buildConflicts(request));

    // —— policy：模型、权限、token 预算、禁止写入的工具 ——
    fields.add(await _buildPolicy(request));

    return ContextPacket(fields: fields, approvalMode: request.approvalMode);
  }

  // —— task ——
  String _renderTask(ContextPacketBuildRequest request) {
    final mode = switch (request.approvalMode) {
      'user_confirm' => '需用户确认后写入',
      'author_only' => '仅作者可写入，AI 只读',
      _ => '按默认策略',
    };
    return '任务：${request.task.trim()}\n审批模式：$mode';
  }

  // —— currentObject ——
  Future<ContextPacketField> _buildCurrentObject(
    ContextPacketBuildRequest request,
  ) async {
    final type = request.currentObjectType;
    final id = request.currentObjectId;
    if (type == null || id == null || type.isEmpty || id.isEmpty) {
      return ContextPacketField(key: 'currentObject', content: '');
    }

    final buffer = StringBuffer();
    var revision = '';

    if (type == 'chapter') {
      final chapter = await db.chapterDao.getContentById(id);
      if (chapter == null) {
        return ContextPacketField(key: 'currentObject', content: '');
      }
      final title = chapter.title?.trim().isNotEmpty == true
          ? chapter.title!.trim()
          : '未命名章节';
      buffer.writeln('对象类型：章节');
      buffer.writeln('对象 ID：$id');
      buffer.writeln('标题：$title');
      buffer.writeln('章号：${chapter.chapterNum ?? '—'}');
      buffer.writeln('状态：${chapter.stat}');
      buffer.writeln('字数：${chapter.wordCount}');
      if (chapter.outline.trim().isNotEmpty) {
        buffer.writeln('章纲：${chapter.outline.trim()}');
      }
      if (chapter.brief.trim().isNotEmpty) {
        buffer.writeln('写后总结：${chapter.brief.trim()}');
      }
      if (chapter.content.trim().isNotEmpty) {
        buffer.writeln('正文预览：${_clip(chapter.content.trim(), 600)}');
      }
      revision = 'chapter:$id@${chapter.updatedAt.toIso8601String()}';
    } else if (type == 'character') {
      final profile = await db.characterProfileDao.getById(id);
      if (profile == null) {
        return ContextPacketField(key: 'currentObject', content: '');
      }
      buffer.writeln('对象类型：人物');
      buffer.writeln('对象 ID：$id');
      buffer.writeln('姓名：${profile.name}');
      if (profile.role.trim().isNotEmpty) {
        buffer.writeln('定位：${profile.role.trim()}');
      }
      if (profile.currentState.trim().isNotEmpty) {
        buffer.writeln('当前状态：${profile.currentState.trim()}');
      }
      if (profile.biography.trim().isNotEmpty) {
        buffer.writeln('小传：${_clip(profile.biography.trim(), 400)}');
      }
      revision = 'character:$id';
    } else if (type == 'item') {
      final item = await db.itemDao.getById(id);
      if (item == null) {
        return ContextPacketField(key: 'currentObject', content: '');
      }
      buffer.writeln('对象类型：条目');
      buffer.writeln('对象 ID：$id');
      buffer.writeln('标题：${item.title.trim()}');
      buffer.writeln('类型：${item.type.trim()}');
      if (item.content.trim().isNotEmpty) {
        buffer.writeln('内容：${_clip(item.content.trim(), 600)}');
      }
      revision = 'item:$id';
    } else {
      // 其他类型：尽量给 ID 与类型，不读取具体内容。
      buffer.writeln('对象类型：$type');
      buffer.writeln('对象 ID：$id');
      revision = '$type:$id';
    }

    return ContextPacketField(
      key: 'currentObject',
      content: buffer.toString().trim(),
      sourceRevision: revision,
    );
  }

  // —— canon ——
  Future<ContextPacketField> _buildCanon(
    ContextPacketBuildRequest request,
  ) async {
    final entries = await _canon.listAll();
    final active = entries
        .where((e) => e.level == canonLevelCanon || e.level == canonLevelProposal)
        .where((e) => e.deletedAt == notDeletedSentinel)
        .take(request.canonLimit)
        .toList();
    if (active.isEmpty) {
      return ContextPacketField(key: 'canon', content: '');
    }

    final buffer = StringBuffer();
    for (final entry in active) {
      final fact = entry.fact.trim();
      final title = entry.title.trim();
      buffer.writeln('- [${entry.level}] ${entry.resourceType}/${entry.resourceId}'
          '${title.isNotEmpty ? '：$title' : ''}'
          '${fact.isNotEmpty ? '\n  $fact' : ''}');
    }

    return ContextPacketField(
      key: 'canon',
      content: buffer.toString().trim(),
      sourceRevision:
          'canon:${active.map((e) => e.id).join(',')}@${active.length}',
    );
  }

  // —— chronology ——
  Future<ContextPacketField> _buildChronology(
    ContextPacketBuildRequest request,
  ) async {
    final tree = await db.chapterDao.getTree();
    if (tree.isEmpty) {
      return ContextPacketField(key: 'chronology', content: '');
    }

    final buffer = StringBuffer();
    var count = 0;
    for (final chapter in tree) {
      if (chapter.isVolume) {
        continue;
      }
      if (count >= request.chronologyLimit) {
        break;
      }
      final title = chapter.title?.trim().isNotEmpty == true
          ? chapter.title!.trim()
          : '未命名章节';
      buffer.writeln('- 第 ${chapter.chapterNum ?? '—'}章「$title」'
          '(id=${chapter.id})');
      count++;
    }

    return ContextPacketField(
      key: 'chronology',
      content: buffer.toString().trim(),
      sourceRevision: 'chronology:${tree.length}chapters',
    );
  }

  // —— characterKnowledge：角色当前知晓的信息（ReaderPerspectives by subject）——
  Future<ContextPacketField> _buildCharacterKnowledge(
    ContextPacketBuildRequest request,
  ) async {
    final subject = request.currentObjectId != null
        ? 'character:${request.currentObjectId}'
        : null;
    final rows = subject != null
        ? await db.readerPerspectiveDao.listBySubject(subject)
        : <ReaderPerspectiveRow>[];
    if (rows.isEmpty) {
      return ContextPacketField(key: 'characterKnowledge', content: '');
    }

    final buffer = StringBuffer();
    var count = 0;
    for (final row in rows) {
      if (count >= request.characterKnowledgeLimit) {
        break;
      }
      buffer.writeln('- 事实(${row.factId})：${_stateLabel(row.state)}'
          '${row.storyTime.isNotEmpty ? ' @ ${row.storyTime}' : ''}'
          '${row.evidence.isNotEmpty ? '\n  ${row.evidence}' : ''}');
      count++;
    }

    return ContextPacketField(
      key: 'characterKnowledge',
      content: buffer.toString().trim(),
      sourceRevision: 'characterKnowledge:$subject@${rows.length}',
    );
  }

  // —— readerKnowledge：读者已知/未知/误解 ——
  Future<ContextPacketField> _buildReaderKnowledge(
    ContextPacketBuildRequest request,
  ) async {
    final rows = await db.readerPerspectiveDao.listBySubject(
      request.readerSubject,
    );
    if (rows.isEmpty) {
      return ContextPacketField(key: 'readerKnowledge', content: '');
    }

    final buffer = StringBuffer();
    var count = 0;
    for (final row in rows) {
      if (count >= request.readerKnowledgeLimit) {
        break;
      }
      buffer.writeln('- 事实(${row.factId})：${_stateLabel(row.state)}'
          '${row.disclosureAnchor.isNotEmpty ? ' 揭示于 ${row.disclosureAnchor}' : ''}'
          '${row.note.isNotEmpty ? '\n  ${row.note}' : ''}');
      count++;
    }

    return ContextPacketField(
      key: 'readerKnowledge',
      content: buffer.toString().trim(),
      sourceRevision: 'readerKnowledge:${request.readerSubject}@${rows.length}',
    );
  }

  // —— outline ——
  Future<ContextPacketField> _buildOutline(
    ContextPacketBuildRequest request,
  ) async {
    final rows = await db.outlineDao.getOutlineRows();
    if (rows.isEmpty) {
      return ContextPacketField(key: 'outline', content: '');
    }

    final buffer = StringBuffer();
    var count = 0;
    for (final outline in rows) {
      if (count >= request.outlineLimit) {
        break;
      }
      buffer.writeln('- ${outline.title.trim().isNotEmpty ? outline.title.trim() : outline.documentId}'
          '(状态 ${outline.status})');
      final beats = await db.outlineDao.getBeatRows(outline.documentId);
      for (final beat in beats.take(6)) {
        final beatTitle = beat.title.trim();
        if (beatTitle.isNotEmpty) {
          buffer.writeln('  · $beatTitle');
        }
      }
      count++;
    }

    return ContextPacketField(
      key: 'outline',
      content: buffer.toString().trim(),
      sourceRevision: 'outline:${rows.length}docs',
    );
  }

  // —— evidence：原文与研究证据锚点 ——
  Future<ContextPacketField> _buildEvidence(
    ContextPacketBuildRequest request,
  ) async {
    final query = request.evidenceQuery?.trim();
    if (query == null || query.isEmpty || _embedding == null) {
      return ContextPacketField(key: 'evidence', content: '');
    }

    final hits = await _embedding.search(
      query: query,
      limit: request.evidenceLimit,
    );

    final allowed = <SemanticHit>[
      for (final hit in hits)
        if (_visibilityFilter.isAllowed(
          sourceType: hit.sourceType,
          sourceId: hit.sourceId,
          anchor: hit.sourceAnchor,
        ))
          hit,
    ];
    if (allowed.isEmpty) {
      return ContextPacketField(key: 'evidence', content: '');
    }

    final buffer = StringBuffer();
    for (final hit in allowed) {
      buffer.writeln('- ${hit.title.isNotEmpty ? hit.title : hit.path}'
          '(score ${hit.score.toStringAsFixed(2)})');
      buffer.writeln('  锚点：${hit.sourceAnchor}');
      buffer.writeln('  ${_clip(hit.content, 220)}');
    }

    return ContextPacketField(
      key: 'evidence',
      content: buffer.toString().trim(),
      sourceRevision: 'evidence:$query@${allowed.length}',
    );
  }

  // —— locks ——
  Future<ContextPacketField> _buildLocks(
    ContextPacketBuildRequest request,
  ) async {
    final locks = await _locks.listLocks(activeOnly: true);
    if (locks.isEmpty) {
      return ContextPacketField(key: 'locks', content: '');
    }

    final buffer = StringBuffer();
    var count = 0;
    for (final lock in locks) {
      if (count >= request.lockLimit) {
        break;
      }
      buffer.writeln('- [${lock.scope}] ${lock.resourceType}'
          '${lock.resourceId != null ? '/${lock.resourceId}' : ''}'
          '${lock.field != null ? '·${lock.field}' : ''}'
          '${lock.reason.isNotEmpty ? '：${lock.reason}' : ''}'
          '(发起 ${lock.createdBy},${lock.authorUnlockable ? '作者可解' : '不可解'})');
      count++;
    }

    return ContextPacketField(
      key: 'locks',
      content: buffer.toString().trim(),
      sourceRevision: 'locks:${locks.length}',
    );
  }

  // —— style：写作风格 ——
  Future<ContextPacketField> _buildStyle(
    ContextPacketBuildRequest request,
  ) async {
    final rules = await db.agentRuleDao.getAll();
    final enabled = rules.where((r) => r.enabled).toList();
    if (enabled.isEmpty) {
      return ContextPacketField(key: 'style', content: '');
    }

    final buffer = StringBuffer();
    var count = 0;
    for (final rule in enabled) {
      if (count >= request.styleLimit) {
        break;
      }
      if (rule.content.trim().isNotEmpty) {
        buffer.writeln('- ${rule.name}：${_clip(rule.content.trim(), 200)}');
      }
      count++;
    }

    return ContextPacketField(
      key: 'style',
      content: buffer.toString().trim(),
      sourceRevision: 'style:${enabled.length}rules',
    );
  }

  // —— conflicts：未处理审计发现 ——
  Future<ContextPacketField> _buildConflicts(
    ContextPacketBuildRequest request,
  ) async {
    final pending = await db.impactAuditDao.listPending(limit: request.conflictLimit);
    if (pending.isEmpty) {
      return ContextPacketField(key: 'conflicts', content: '');
    }

    final buffer = StringBuffer();
    for (final audit in pending) {
      final summary = _auditSummary(audit.resultJson);
      buffer.writeln('- ${audit.resourcePath}'
          '(命中 ${audit.hitCount}${summary.isNotEmpty ? '：$summary' : ''})');
    }

    return ContextPacketField(
      key: 'conflicts',
      content: buffer.toString().trim(),
      sourceRevision: 'conflicts:${pending.length}',
    );
  }

  // —— policy：模型/权限/token 预算/禁止工具 ——
  Future<ContextPacketField> _buildPolicy(
    ContextPacketBuildRequest request,
  ) async {
    // policy 主要来自运行环境配置；此处提供默认声明，供模型了解边界。
    final buffer = StringBuffer()
      ..writeln('写入边界：AI 产生的变更一律进入 WorkingChange 并触发影响审计')
      ..writeln('正典保护：canon 级事实在锁定范围内不可被 AI 覆盖')
      ..writeln('禁止工具：无（由运行时策略注入）');
    return ContextPacketField(
      key: 'policy',
      content: buffer.toString().trim(),
      sourceRevision: 'policy:default',
    );
  }

  // —— 工具 ——
  String _clip(String text, int max) {
    if (text.length <= max) {
      return text;
    }
    return '${text.substring(0, max)}…';
  }

  String _stateLabel(String state) {
    return switch (state) {
      readerPerspectiveStateAware => '知晓',
      readerPerspectiveStateMisled => '被误导',
      readerPerspectiveStateRevealed => '已揭示',
      _ => '未知',
    };
  }

  /// 从 ImpactAudit.resultJson 提取简短摘要（容错缺失/损坏 JSON）。
  String _auditSummary(String resultJson) {
    if (resultJson.isEmpty) {
      return '';
    }
    try {
      final decoded = jsonDecode(resultJson);
      if (decoded is! Map<String, dynamic>) {
        return '';
      }
      return decoded['summary'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }
}
