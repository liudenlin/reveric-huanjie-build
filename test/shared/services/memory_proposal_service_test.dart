// 职责: M6e MemoryProposalService 测试 — 提案生成、裁决状态机、版本检查、
//       DecisionLog Append-only、与 M3 正典衔接落位。
// 关联文件:
//   lib/shared/services/memory_proposal_service.dart
//   lib/shared/database/novel_content_database.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（专项设计 §3.1/§4.1）：AI 产出候选不直接写正典；每处裁决进账本；
//   拒绝/延期/修改保留决策历史；版本不符拒绝落位；接受后升 canon。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/memory_proposal_service.dart';

void main() {
  late NovelContentDatabase db;
  late MemoryProposalService service;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = MemoryProposalService(db);
  });

  tearDown(() async => db.close());

  group('MemoryProposalService', () {
    test('propose 生成 pending 候选，不直接写正典', () async {
      final proposal = await service.propose(MemoryProposalRequest(
        projectId: 'novel_x',
        targetType: 'character',
        targetId: 'c_hero',
        predicate: 'biography',
        proposedValue: '林晚幼年随师习剑。',
        expectedHash: 'rev-1',
        evidence: const [
          ProposalEvidence(
            sourceAnchor: 'ch_1#0',
            quote: '随师习剑',
            revisionId: 'rev-1',
          ),
        ],
        confidence: 0.9,
        sourceModel: 'test-model',
        sourceSessionId: 'sess_1',
        sourceTurnId: 'turn_1',
      ));

      expect(proposal.reviewStatus, proposalReviewStatusPending);
      expect(proposal.targetType, 'character');
      expect(proposal.confidence, 0.9);

      // 证据 JSON 可解析。
      final evidence = service.parseEvidence(proposal);
      expect(evidence, hasLength(1));
      expect(evidence.single.sourceAnchor, 'ch_1#0');
      expect(evidence.single.revisionId, 'rev-1');

      // 未写入正典（proposal 层不产生 canon 条目）。
      final canon = await db.canonEntryDao.listAll();
      expect(canon, isEmpty);
    });

    test('decide accept：写 DecisionLog + 落位回调 + 状态变 approved', () async {
      final proposal = await service.propose(MemoryProposalRequest(
        projectId: 'novel_x',
        targetType: 'character',
        targetId: 'c_hero',
        predicate: 'biography',
        proposedValue: '林晚幼年随师习剑。',
        expectedHash: 'rev-1',
      ));

      var accepted = false;
      final result = await service.decide(
        proposalId: proposal.id,
        action: decisionActionAccept,
        actor: decisionActorAuthor,
        comment: '确认采纳',
        expectedHash: 'rev-1',
        onAccept: () async {
          accepted = true;
          return 'canon_xxx';
        },
      );

      expect(accepted, isTrue);
      expect(result.action, decisionActionAccept);
      expect(result.proposalReviewStatus, proposalReviewStatusApproved);
      expect(result.expectedHashMatched, isTrue);
      expect(result.resolutionNote, 'canon_xxx');

      final updated = (await db.factProposalDao.getById(proposal.id))!;
      expect(updated.reviewStatus, proposalReviewStatusApproved);
      expect(updated.resolutionNote, 'canon_xxx');

      // DecisionLog Append-only。
      final logs = await service.historyFor(proposal.id);
      expect(logs, hasLength(1));
      expect(logs.single.decision, decisionActionAccept);
      expect(logs.single.actor, decisionActorAuthor);
    });

    test('decide reject：保留历史、状态 rejected、不落位', () async {
      final proposal = await service.propose(MemoryProposalRequest(
        projectId: 'novel_x',
        targetType: 'character',
        targetId: 'c_hero',
        proposedValue: '不该写的设定。',
      ));

      var accepted = false;
      final result = await service.decide(
        proposalId: proposal.id,
        action: decisionActionReject,
        comment: '与主线冲突',
        onAccept: () async {
          accepted = true;
          return '';
        },
      );

      expect(accepted, isFalse);
      expect(result.proposalReviewStatus, proposalReviewStatusRejected);

      final logs = await service.historyFor(proposal.id);
      expect(logs, hasLength(1));
      expect(logs.single.decision, decisionActionReject);
    });

    test('版本不匹配时 accept 拒绝落位（§3.1 版本检查）', () async {
      final proposal = await service.propose(MemoryProposalRequest(
        projectId: 'novel_x',
        targetType: 'character',
        targetId: 'c_hero',
        proposedValue: '过期提案。',
        expectedHash: 'rev-1',
      ));

      // 目标对象已前进到 rev-2，提案基于 rev-1 → 版本不匹配。
      await expectLater(
        service.decide(
          proposalId: proposal.id,
          action: decisionActionAccept,
          expectedHash: 'rev-2',
        ),
        throwsA(isA<StateError>()),
      );

      // 仍保持 pending，无日志追加（未产生裁决）。
      final updated = (await db.factProposalDao.getById(proposal.id))!;
      expect(updated.reviewStatus, proposalReviewStatusPending);
      expect(await service.historyFor(proposal.id), isEmpty);
    });

    test('延期/修改：状态与动作对应、多次裁决都进账本', () async {
      final proposal = await service.propose(MemoryProposalRequest(
        projectId: 'novel_x',
        targetType: 'character',
        targetId: 'c_hero',
        proposedValue: '暂缓的设定。',
      ));

      await service.decide(
        proposalId: proposal.id,
        action: decisionActionDefer,
        comment: '等后续情节再定',
      );
      expect(
        (await db.factProposalDao.getById(proposal.id))!.reviewStatus,
        proposalReviewStatusDeferred,
      );

      // 修改后重提案 → 新提案（旧提案置 modified，历史保留）。
      await service.decide(
        proposalId: proposal.id,
        action: decisionActionModify,
        comment: '改为不同表述',
      );
      expect(
        (await db.factProposalDao.getById(proposal.id))!.reviewStatus,
        proposalReviewStatusModified,
      );

      final logs = await service.historyFor(proposal.id);
      expect(logs, hasLength(2));
      expect(logs.map((l) => l.decision).toSet(),
          {decisionActionDefer, decisionActionModify});
    });

    test('acceptIntoCanon：落位为正典 canon 层并保留来源', () async {
      final proposal = await service.propose(MemoryProposalRequest(
        projectId: 'novel_x',
        targetType: 'character',
        targetId: 'c_hero',
        predicate: 'biography',
        proposedValue: '林晚幼年随师习剑。',
        sourceSessionId: 'sess_1',
        sourceTurnId: 'turn_1',
      ));

      final entryId = await service.acceptIntoCanon(proposalId: proposal.id);
      expect(entryId, startsWith('canon_'));

      final canon = await db.canonEntryDao.listAll();
      expect(canon, hasLength(1));
      expect(canon.single.level, canonLevelCanon);
      expect(canon.single.resourceType, 'character');
      expect(canon.single.resourceId, 'c_hero');
      expect(canon.single.fact, '林晚幼年随师习剑。');
      expect(canon.single.sourceSessionId, 'sess_1');
      expect(canon.single.sourceTurnId, 'turn_1');
    });

    test('listPending 过滤项目；未知裁决动作抛错', () async {
      await service.propose(MemoryProposalRequest(
        projectId: 'novel_a',
        targetType: 'character',
        targetId: 'c_1',
        proposedValue: 'A 项目提案。',
      ));
      await service.propose(MemoryProposalRequest(
        projectId: 'novel_b',
        targetType: 'character',
        targetId: 'c_2',
        proposedValue: 'B 项目提案。',
      ));

      final pendingA = await service.listPending(projectId: 'novel_a');
      expect(pendingA, hasLength(1));
      expect(pendingA.single.projectId, 'novel_a');

      // 未知裁决动作抛 ArgumentError。
      final proposal = await service.propose(MemoryProposalRequest(
        projectId: 'novel_x',
        targetType: 'character',
        targetId: 'c_hero',
        proposedValue: 'x',
      ));
      await expectLater(
        service.decide(proposalId: proposal.id, action: 'explode'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('提案不存在抛 ArgumentError', () async {
      await expectLater(
        service.decide(proposalId: 'missing', action: decisionActionAccept),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('parseEvidence 容错损坏 JSON', () async {
      await db.factProposalDao.upsert(
        FactProposalsCompanion.insert(
          id: 'broken_ev',
          targetType: 'world',
          targetId: 'star',
          evidenceJson: const Value('{not json'),
        ),
      );
      final row = (await db.factProposalDao.getById('broken_ev'))!;
      expect(service.parseEvidence(row), isEmpty);
    });
  });
}
