// 职责: M6e MemoryProposalService — 记忆变更提案的生成、裁决与落位（§4.1）。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (FactProposals/DecisionLogs 表)
//   lib/shared/services/conversation_to_canon_service.dart (M3 正典衔接)
//   lib/shared/services/canon_service.dart (M2 四态正典)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（专项设计 §3.1）：AI 改变正式 Canon 的每一处均经过提案、锁定验证、
//   版本检查和审批；拒绝/延期/修改提案均保留决策历史（DecisionLog Append-only）；
//   提案携带原文证据、置信度、来源模型，供作者裁决时复核。
//
// 与 M3 的分工：
//   M3 ConversationToCanon 处理「对话产出 → 正典 proposal 层」；
//   M6e 处理「记忆/设定变更 → FactProposal 待裁决 → DecisionLog 账本 → 落位」，
//   两者都写 CanonEntries，但 M6e 额外保留结构化提案与裁决历史。

import 'dart:convert';

import 'package:drift/drift.dart' hide Column;

import '../database/novel_content_database.dart';
import '../database/novel_content_daos/decision_log_dao.dart';
import '../database/novel_content_daos/fact_proposal_dao.dart';
import '../utils/short_entity_id.dart';

/// 提案证据项（原文锚点，可定位可复核，§4.1 EvidenceRef）。
class ProposalEvidence {
  const ProposalEvidence({
    required this.sourceAnchor,
    this.quote = '',
    this.revisionId = '',
  });

  /// 原文锚点（章节/段落定位）。
  final String sourceAnchor;

  /// 命中原文片段。
  final String quote;

  /// 来源版本 hash。
  final String revisionId;

  Map<String, dynamic> toJson() => {
    'sourceAnchor': sourceAnchor,
    'quote': quote,
    'revisionId': revisionId,
  };

  factory ProposalEvidence.fromJson(Map<String, dynamic> json) =>
      ProposalEvidence(
        sourceAnchor: json['sourceAnchor'] as String? ?? '',
        quote: json['quote'] as String? ?? '',
        revisionId: json['revisionId'] as String? ?? '',
      );
}

/// 提案创建请求（AI 产出的记忆/设定变更候选）。
class MemoryProposalRequest {
  const MemoryProposalRequest({
    required this.projectId,
    required this.targetType,
    required this.targetId,
    this.predicate = '',
    required this.proposedValue,
    this.expectedHash = '',
    this.evidence = const [],
    this.confidence = 0.5,
    this.sourceModel = '',
    this.sourceSessionId,
    this.sourceTurnId,
  });

  final String projectId;
  final String targetType;
  final String targetId;
  final String predicate;
  final String proposedValue;

  /// 目标对象预期版本 hash（裁决时核对，防基于过期版本落位）。
  final String expectedHash;
  final List<ProposalEvidence> evidence;
  final double confidence;
  final String sourceModel;
  final String? sourceSessionId;
  final String? sourceTurnId;
}

/// 裁决结果。
class MemoryProposalDecision {
  const MemoryProposalDecision({
    required this.proposalId,
    required this.action,
    required this.proposalReviewStatus,
    required this.logId,
    required this.expectedHashMatched,
    this.resolutionNote = '',
  });

  final String proposalId;
  final String action;
  final String proposalReviewStatus;
  final String logId;
  final bool expectedHashMatched;
  final String resolutionNote;
}

/// §4.1 FactProposal + DecisionLog 裁决服务。
class MemoryProposalService {
  MemoryProposalService(
    this.db, {
    ShortEntityIdBuilder shortId = buildShortEntityId,
  }) : _shortId = shortId;

  final NovelContentDatabase db;
  final ShortEntityIdBuilder _shortId;

  FactProposalDao get _dao => db.factProposalDao;
  DecisionLogDao get _log => db.decisionLogDao;

  // ---------------------------------------------------------------------------
  // 1. 提案生成
  // ---------------------------------------------------------------------------

  /// 生成一条待裁决提案（pending），不直接写入正式正典。
  Future<FactProposalRow> propose(MemoryProposalRequest request) async {
    final now = DateTime.now();
    final id = _newProposalId();
    await _dao.upsert(
      FactProposalsCompanion.insert(
        id: id,
        projectId: Value(request.projectId),
        targetType: request.targetType,
        targetId: request.targetId,
        predicate: Value(request.predicate),
        proposedValue: Value(request.proposedValue),
        expectedHash: Value(request.expectedHash),
        evidenceJson: Value(
          jsonEncode([for (final e in request.evidence) e.toJson()]),
        ),
        confidence: Value(request.confidence),
        sourceModel: Value(request.sourceModel),
        sourceSessionId: Value(request.sourceSessionId),
        sourceTurnId: Value(request.sourceTurnId),
        reviewStatus: const Value(proposalReviewStatusPending),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    return (await _dao.getById(id))!;
  }

  // ---------------------------------------------------------------------------
  // 2. 作者裁决
  // ---------------------------------------------------------------------------

  /// 作者裁决单条提案。
  ///
  /// 每次裁决都追加一条 [DecisionLogs]（Append-only）并更新提案状态；
  /// [expectedHash] 与实际目标 hash 不符时仍记录裁决，但标记
  /// `expectedHashMatched=false`（调用方需基于最新版本复核，§3.1 版本检查）。
  ///
  /// [action] 取 decisionActionAccept/Reject/Defer/Modify。
  /// [onAccept] 在 accept 时执行落位回调（写入目标对象/正典），
  ///   返回落位说明（如正典条目 ID）。
  Future<MemoryProposalDecision> decide({
    required String proposalId,
    required String action,
    String actor = decisionActorAuthor,
    String comment = '',
    String? expectedHash,
    Future<String> Function()? onAccept,
  }) async {
    final proposal = await _dao.getById(proposalId);
    if (proposal == null) {
      throw ArgumentError('提案不存在：$proposalId');
    }

    // 版本检查（§3.1）：期望 hash 一致才允许落位。
    final hash = expectedHash ?? proposal.expectedHash;
    final hashMatched = hash.isEmpty || proposal.expectedHash.isEmpty
        ? true
        : hash == proposal.expectedHash;

    final reviewStatus = _statusForAction(action);
    String resolutionNote = '';

    if (action == decisionActionAccept) {
      if (!hashMatched) {
        throw StateError(
          '版本不匹配：提案基于 ${proposal.expectedHash}，当前 $hash；'
          '请基于最新版本重新提案（§3.1 版本检查）。',
        );
      }
      if (onAccept != null) {
        resolutionNote = await onAccept();
      }
    }

    await _dao.updateStatus(
      proposalId,
      reviewStatus,
      resolutionNote: resolutionNote,
    );

    final logId = _newDecisionLogId();
    await _log.append(
      DecisionLogsCompanion.insert(
        id: logId,
        proposalId: proposalId,
        actor: Value(actor),
        decision: action,
        comment: Value(comment),
        expectedHash: Value(hash),
        createdAt: Value(DateTime.now()),
      ),
    );

    return MemoryProposalDecision(
      proposalId: proposalId,
      action: action,
      proposalReviewStatus: reviewStatus,
      logId: logId,
      expectedHashMatched: hashMatched,
      resolutionNote: resolutionNote,
    );
  }

  /// 接受提案并落位到正典（与 M3 衔接：提升为 canon 条目）。
  ///
  /// 供 [decide] 的 onAccept 使用——将提案事实写入 CanonEntries canon 层，
  /// 并记录来源（session/turn），返回正典条目 id。
  Future<String> acceptIntoCanon({
    required String proposalId,
    String? sourceSessionId,
    String? sourceTurnId,
  }) async {
    final proposal = await _dao.getById(proposalId);
    if (proposal == null) {
      throw ArgumentError('提案不存在：$proposalId');
    }
    final entryId = 'canon_${_shortId(ShortEntityIdType.foreshadowing)}';
    final now = DateTime.now();
    await db.into(db.canonEntries).insert(
      CanonEntriesCompanion.insert(
        id: entryId,
        resourceType: proposal.targetType,
        resourceId: proposal.targetId,
        level: canonLevelCanon,
        title: Value(proposal.predicate),
        fact: Value(proposal.proposedValue),
        source: 'proposal',
        sourceSessionId: Value(sourceSessionId ?? proposal.sourceSessionId),
        sourceTurnId: Value(sourceTurnId ?? proposal.sourceTurnId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    return entryId;
  }

  // ---------------------------------------------------------------------------
  // 3. 查询
  // ---------------------------------------------------------------------------

  Future<List<FactProposalRow>> listPending({String? projectId}) async {
    final pending = await _dao.listByStatus(proposalReviewStatusPending);
    if (projectId == null) {
      return pending;
    }
    return pending.where((p) => p.projectId == projectId).toList();
  }

  Future<List<FactProposalRow>> listByProject(String projectId) =>
      _dao.listByProject(projectId);

  Future<List<DecisionLogRow>> historyFor(String proposalId) =>
      _log.listByProposal(proposalId);

  Future<List<DecisionLogRow>> allDecisions({int? limit}) =>
      _log.listAll(limit: limit);

  /// 解析提案证据（容错损坏 JSON）。
  List<ProposalEvidence> parseEvidence(FactProposalRow proposal) {
    if (proposal.evidenceJson.isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(proposal.evidenceJson);
      if (decoded is! List) {
        return const [];
      }
      return [
        for (final item in decoded)
          if (item is Map)
            ProposalEvidence.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (_) {
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // 4. 工具
  // ---------------------------------------------------------------------------

  String _statusForAction(String action) => switch (action) {
    decisionActionAccept => proposalReviewStatusApproved,
    decisionActionReject => proposalReviewStatusRejected,
    decisionActionDefer => proposalReviewStatusDeferred,
    decisionActionModify => proposalReviewStatusModified,
    _ => throw ArgumentError('未知裁决动作：$action'),
  };

  String _newProposalId() => 'proposal_${_shortId(ShortEntityIdType.item)}';
  String _newDecisionLogId() => 'decide_${_shortId(ShortEntityIdType.item)}';
}
