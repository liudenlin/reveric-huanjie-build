// 职责: R-33 project 层 AgentSkill 覆盖集落库回归测试 —— 验证按 novel 维度
//   upsert/删除/启停、同名唯一与 references 持久化。
// 关联文件:
//   lib/shared/providers/project_agent_skill_providers.dart
//   lib/shared/database/daos/novel_agent_skill_override_dao.dart
//   lib/shared/database/app_database.dart
//   lib/shared/models/novel_agent_skill.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/agent_skill_reference.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/agent_skill_providers.dart';
import 'package:reveric/shared/providers/project_agent_skill_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';

void main() {
  group('R-33 project 层落库', () {
    test('upsert 写入并可流读取', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      await setup.service.upsert(
        const ProjectAgentSkillOverrideInput(
          novelId: 'novel-1',
          name: '天气助手',
          description: '天气描述',
          prompt: '天气提示词',
        ),
      );

      final skills = await setup.readNovel('novel-1');
      expect(skills.length, 1);
      final skill = skills.single;
      expect(skill.name, '天气助手');
      expect(skill.description, '天气描述');
      expect(skill.prompt, '天气提示词');
      expect(skill.enabled, isTrue);
      expect(skill.sourceKind, AgentSkillSourceKind.novelLocal);
    });

    test('同一作品同名 upsert 覆盖而非重复', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      final first = await setup.service.upsert(
        const ProjectAgentSkillOverrideInput(
          novelId: 'novel-1',
          name: '同名技能',
          description: '旧',
          prompt: '旧提示',
        ),
      );
      await setup.service.upsert(
        ProjectAgentSkillOverrideInput(
          novelId: 'novel-1',
          name: '同名技能',
          description: '新',
          prompt: '新提示',
          existingId: first.id,
        ),
      );

      final skills = await setup.readNovel('novel-1');
      expect(skills.length, 1);
      expect(skills.single.description, '新');
      expect(skills.single.prompt, '新提示');
    });

    test('不同作品同名可并存', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      await setup.service.upsert(
        const ProjectAgentSkillOverrideInput(
          novelId: 'novel-1',
          name: '同名技能',
          description: 'a',
          prompt: 'pa',
        ),
      );
      await setup.service.upsert(
        const ProjectAgentSkillOverrideInput(
          novelId: 'novel-2',
          name: '同名技能',
          description: 'b',
          prompt: 'pb',
        ),
      );

      expect((await setup.readNovel('novel-1')).length, 1);
      expect((await setup.readNovel('novel-2')).length, 1);
      expect((await setup.readNovel('novel-1')).single.description, 'a');
      expect((await setup.readNovel('novel-2')).single.description, 'b');
    });

    test('references 持久化', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      await setup.service.upsert(
        const ProjectAgentSkillOverrideInput(
          novelId: 'novel-1',
          name: '带附件技能',
          description: 'd',
          prompt: 'p',
          references: [
            AgentSkillReferenceFile(
              path: 'references/guide.md',
              content: '# 指南',
            ),
          ],
        ),
      );

      final skill = (await setup.readNovel('novel-1')).single;
      expect(skill.references.single.path, 'references/guide.md');
      expect(skill.references.single.content, '# 指南');
    });

    test('删除覆盖及 references', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      final created = await setup.service.upsert(
        const ProjectAgentSkillOverrideInput(
          novelId: 'novel-1',
          name: '待删',
          description: 'd',
          prompt: 'p',
          references: [AgentSkillReferenceFile(path: 'r.md', content: 'c')],
        ),
      );
      await setup.service.delete(created.id);

      expect(await setup.readNovel('novel-1'), isEmpty);
    });

    test('setEnabled 启停', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      final created = await setup.service.upsert(
        const ProjectAgentSkillOverrideInput(
          novelId: 'novel-1',
          name: '启停',
          description: 'd',
          prompt: 'p',
        ),
      );
      await setup.service.setEnabled(created.id, false);

      expect((await setup.readNovel('novel-1')).single.enabled, isFalse);
    });

    test('StreamProvider 写后自动刷新（UI watch 路径）', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      // 用 listen 保持订阅，模拟管理面板 ref.watch；read 会立即关闭订阅导致
      // 冷流被取消、首值不达（Riverpod 3 单次读语义），故不能用 .future。
      final seen = <List<NovelAgentSkillModel>>[];
      final sub = setup.container
          .listen<AsyncValue<List<NovelAgentSkillModel>>>(
            projectAgentSkillOverridesProvider('novel-1'),
            (_, next) {
              final value = next.value;
              if (value != null) {
                seen.add(value);
              }
            },
          );
      addTearDown(sub.close);

      await _waitFor(() => seen.isNotEmpty);
      expect(seen.first, isEmpty);

      await setup.service.upsert(
        const ProjectAgentSkillOverrideInput(
          novelId: 'novel-1',
          name: '流技能',
          description: 'd',
          prompt: 'p',
        ),
      );
      await _waitFor(() => seen.length >= 2);
      expect(seen.last.single.name, '流技能');
    });
  });
}

/// 轮询等待条件成立（plain test 无 FakeAsync，直接让出事件循环）。
Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('waitFor 超时');
}

// ── 测试夹具 ─────────────────────────────────────────────────────────────────

class _TestSetup {
  _TestSetup({required this.db, required this.container});

  final AppDatabase db;
  final ProviderContainer container;

  ProjectAgentSkillOverrideService get service =>
      container.read(projectAgentSkillOverrideServiceProvider);

  Future<List<NovelAgentSkillModel>> readNovel(String novelId) {
    return service.loadByNovelId(novelId);
  }

  Future<void> tearDown() async {
    container.dispose();
    await db.close();
  }
}

Future<_TestSetup> _setup() async {
  final db = AppDatabase.forTest(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      agentSkillAppDatabaseProvider.overrideWithValue(db),
    ],
  );
  return _TestSetup(db: db, container: container);
}
