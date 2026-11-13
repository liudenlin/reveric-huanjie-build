// 职责: M3 Conversation-to-Canon 编排测试 — 匹配/冲突/提案/裁决落位/来源回溯。
// 关联文件:
//   lib/shared/services/conversation_to_canon_service.dart
//   lib/shared/services/conversation_to_canon_models.dart
//   lib/shared/services/canon_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（需求框架 M3）：对话修改人物 → 确认后人物档案/关系/剧情正确落位，
//   且决策记录可回溯到原始会话/回合。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/services/conversation_to_canon_models.dart';
import 'package:reveric/shared/services/conversation_to_canon_service.dart';
import 'package:reveric/shared/services/novel_content.dart';

void main() {
  late NovelContentDatabase db;
  late NovelContentService content;
  late ConversationToCanonService service;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(db);
    service = ConversationToCanonService(content: content);
  });

  tearDown(() async => db.close());

  test('未锁定资源：匹配无冲突，新人物可安全落位', () async {
    final match = await service.matchSuggestion(
      const CanonSuggestion(
        kind: CanonSuggestionKind.character,
        action: CanonSettlementAction.create,
        title: '林晚',
        field: 'biography',
        value: '女主角，左眼角有泪痣。',
      ),
    );
    expect(match, isNotNull);
    expect(match!.matchedId, isNull);
    expect(match.conflict, isFalse);
  });

  test('同名实体：命中匹配并标记冲突（create vs 已有）', () async {
    await db.characterProfileDao.upsert(
      CharacterProfile(
        id: 'c_hero',
        name: '林晚',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        deletedAt: notDeletedSentinel,
        role: characterRoleProtagonist,
        gender: characterGenderFemale,
        aliases: const ['晚晚'],
        tags: const [],
        biography: '旧档案',
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
    );

    // 按正名匹配
    final byName = await service.matchSuggestion(
      const CanonSuggestion(
        kind: CanonSuggestionKind.character,
        action: CanonSettlementAction.create,
        title: '林晚',
      ),
    );
    expect(byName!.matchedId, 'c_hero');
    expect(byName.conflict, isTrue);

    // 按别名匹配
    final byAlias = await service.matchSuggestion(
      const CanonSuggestion(
        kind: CanonSuggestionKind.character,
        action: CanonSettlementAction.update,
        title: '晚晚',
      ),
    );
    expect(byAlias!.matchedId, 'c_hero');
    expect(byAlias.conflict, isFalse, reason: 'update 命中原实体不算冲突');
  });

  test('提案落位：人物档案写入 + 升 canon + 来源可回溯', () async {
    const sessionId = 'ses_001';
    const turnId = 'trn_001';
    final proposal = await service.propose(
      suggestion: const CanonSuggestion(
        kind: CanonSuggestionKind.character,
        action: CanonSettlementAction.create,
        title: '沈砚',
        field: 'biography',
        value: '男主，冷静克制。',
      ),
      source: 'conversation_canon',
      sourceSessionId: sessionId,
      sourceTurnId: turnId,
    );

    // 提案写入 proposal 层。
    final entry = await db.canonEntryDao.findById(proposal.entryId);
    expect(entry, isNotNull);
    expect(entry!.level, canonLevelProposal);
    expect(entry.sourceSessionId, sessionId);
    expect(entry.sourceTurnId, turnId);

    // 裁决：接受 → 落位。
    final outcome = await service.decide(
      entryId: proposal.entryId,
      suggestion: proposal.match.suggestion,
      accept: true,
      source: 'conversation_canon',
      sourceSessionId: sessionId,
      sourceTurnId: turnId,
    );
    expect(outcome.accepted, isTrue);
    expect(outcome.resourceId, isNotNull);

    // 档案已写入。
    final character = await db.characterProfileDao.getById(outcome.resourceId!);
    expect(character, isNotNull);
    expect(character!.name, '沈砚');
    expect(character.biography, '男主，冷静克制。');

    // 正典升为 canon + 自动加锁（幂等）。
    final canon = await db.canonEntryDao.findById(proposal.entryId);
    expect(canon!.level, canonLevelCanon);
    final locks = await db.contentLockDao.listActive();
    expect(locks, isNotEmpty, reason: 'canonize 应自动加锁保护');
    expect(
      locks.any((l) => l.resourceId == outcome.resourceId),
      isTrue,
    );

    // WorkingChange 记录（可回溯来源）。
    final changes = await db.workingChangeDao.getByResource(
      'characters/${outcome.resourceId}',
    );
    expect(changes, isNotEmpty);
    expect(changes.first.sourceSessionId, sessionId);
    expect(changes.first.sourceTurnId, turnId);
  });

  test('提案否决：落位废弃（deprecated），档案不写入', () async {
    final proposal = await service.propose(
      suggestion: const CanonSuggestion(
        kind: CanonSuggestionKind.character,
        action: CanonSettlementAction.create,
        title: '路人甲',
        field: 'biography',
        value: '不该落位。',
      ),
      source: 'conversation_canon',
    );

    final outcome = await service.decide(
      entryId: proposal.entryId,
      suggestion: proposal.match.suggestion,
      accept: false,
      decisionNote: '与设定冲突，否决。',
    );
    expect(outcome.accepted, isFalse);

    final entry = await db.canonEntryDao.findById(proposal.entryId);
    expect(entry!.level, canonLevelDeprecated);
    // 无档案写入。
    final all = await db.characterProfileDao.getAll();
    expect(all, isEmpty);
  });

  test('世界设定落位：Items 写入 + 冲突检查按标题匹配', () async {
    await db.itemDao.upsert(
      Item(
        id: 'it_world1',
        type: 'world',
        title: '灵气复苏',
        content: '旧设定',
        status: itemEntryStatusActive,
        category: '',
        sortOrder: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        deletedAt: notDeletedSentinel,
      ),
    );

    // 同名设定项：匹配到已有。
    final match = await service.matchSuggestion(
      const CanonSuggestion(
        kind: CanonSuggestionKind.world,
        action: CanonSettlementAction.create,
        title: '灵气复苏',
      ),
    );
    expect(match!.matchedId, 'it_world1');
    expect(match.conflict, isTrue);

    // 新设定项：落位。
    final proposal = await service.propose(
      suggestion: const CanonSuggestion(
        kind: CanonSuggestionKind.world,
        action: CanonSettlementAction.create,
        title: '上古剑冢',
        field: 'world',
        value: '剑冢现世，灵气枯竭的转折点。',
      ),
      source: 'conversation_canon',
    );
    final outcome = await service.decide(
      entryId: proposal.entryId,
      suggestion: proposal.match.suggestion,
      accept: true,
    );
    final item = await db.itemDao.getById(outcome.resourceId!);
    expect(item, isNotNull);
    expect(item!.title, '上古剑冢');
    expect(item.content, '剑冢现世，灵气枯竭的转折点。');
  });

  test('关系落位：sourceId|relationType|targetId 三点式', () async {
    await db.characterProfileDao.upsert(
      CharacterProfile(
        id: 'c_a',
        name: '沈砚',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        deletedAt: notDeletedSentinel,
        role: characterRoleProtagonist,
        gender: characterGenderMale,
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
    );
    await db.characterProfileDao.upsert(
      CharacterProfile(
        id: 'c_b',
        name: '林晚',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        deletedAt: notDeletedSentinel,
        role: characterRoleSupporting,
        gender: characterGenderFemale,
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
    );

    final proposal = await service.propose(
      suggestion: const CanonSuggestion(
        kind: CanonSuggestionKind.relation,
        action: CanonSettlementAction.create,
        title: '沈砚·林晚 关系',
        value: '对话中确认：青梅竹马。',
      ),
      source: 'conversation_canon',
    );
    final outcome = await service.decide(
      entryId: proposal.entryId,
      suggestion: proposal.match.suggestion,
      accept: true,
      // 青梅竹马 → friend（character→character 允许类型，[对称]）。
      targetResourceId: 'c_a|friend|c_b',
    );
    expect(outcome.accepted, isTrue);
    expect(outcome.resourceId, isNotNull);

    final relation = await content.entityRelationsService.getRelationById(
      outcome.resourceId!,
    );
    expect(relation, isNotNull);
    expect(relation!.sourceId, 'c_a');
    expect(relation.targetId, 'c_b');
  });

  test('关系落位缺端点：拒绝并报错（fail-closed）', () async {
    final proposal = await service.propose(
      suggestion: const CanonSuggestion(
        kind: CanonSuggestionKind.relation,
        action: CanonSettlementAction.create,
        title: '缺失端点',
      ),
      source: 'conversation_canon',
    );
    expect(
      () => service.decide(
        entryId: proposal.entryId,
        suggestion: proposal.match.suggestion,
        accept: true,
        targetResourceId: 'bad_format',
      ),
      throwsA(isA<CanonSettlementException>()),
    );
  });
}
