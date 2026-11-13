// 职责: 测试 R-33 Skill 三层解析器 —— 验证 project > user > builtin 同名覆盖、
//   disabled/blocked 压制、作品类型过滤与按需加载器。
// 关联文件:
//   lib/shared/services/ai/agent_skill_layers.dart
//   lib/shared/services/bundled_control_skills.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/models/agent_skill.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/agent_skill_reference.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/services/ai/agent_skill_layers.dart';
import 'package:reveric/shared/services/bundled_control_skills.dart';

NovelAgentSkillModel _novelSkill(
  String name, {
  String prompt = 'user prompt',
  bool enabled = true,
  String? blockedReason,
  List<AgentSkillReferenceFile> references = const [],
}) {
  return NovelAgentSkillModel(
    id: 'id_$name',
    sourceKind: AgentSkillSourceKind.novelLocal,
    name: name,
    description: 'desc $name',
    prompt: prompt,
    whenToUse: 'when $name',
    enabled: enabled,
    executionBlockedReason: blockedReason,
    references: references,
  );
}

BundledControlSkill _bundledSkill(String callName) {
  return BundledControlSkill(
    callName: callName,
    runCommand: null,
    name: callName,
    whenToUse: 'when $callName',
    description: 'desc $callName',
    prompt: 'bundled prompt $callName',
    assetPath: 'assets/bundled_skills/$callName/SKILL.md',
  );
}

Future<BundledControlSkill?> Function(String) _bundledLoaderFor(
  List<BundledControlSkill> bundled,
) {
  final byName = {for (final skill in bundled) skill.callName: skill};
  return (callName) async => byName[callName];
}

AgentSkillResolution _resolve({
  List<NovelAgentSkillModel> project = const [],
  List<NovelAgentSkillModel> user = const [],
  List<BundledControlSkill> bundled = const [],
  String contentKind = contentKindNovel,
}) {
  return resolveAgentSkillLayers(
    projectSkills: project,
    userSkills: user,
    bundledSkills: bundled,
    contentKind: contentKind,
    bundledLoader: _bundledLoaderFor(bundled),
  );
}

void main() {
  group('R-33 three-layer resolver', () {
    test(
      'builtin-only resolution exposes summaries, content and loader',
      () async {
        final resolution = _resolve(
          bundled: [_bundledSkill('系统管理'), _bundledSkill('创作向导')],
        );

        expect(resolution.summaries.map((skill) => skill.name), [
          '系统管理',
          '创作向导',
        ]);
        expect(resolution.content['系统管理'], 'bundled prompt 系统管理');
        expect(resolution.content['创作向导'], 'bundled prompt 创作向导');
        expect(
          (await resolution.loader('系统管理'))!.instructions,
          'bundled prompt 系统管理',
        );
        expect(await resolution.loader('不存在的技能'), isNull);
      },
    );

    test(
      'user same-name override suppresses builtin and wins loader',
      () async {
        final resolution = _resolve(
          user: [_novelSkill('系统管理', prompt: 'user 系统管理')],
          bundled: [_bundledSkill('系统管理')],
        );

        expect(resolution.summaries, hasLength(1));
        expect(resolution.summaries.single.name, '系统管理');
        expect(resolution.content['系统管理'], 'user 系统管理');
        expect((await resolution.loader('系统管理'))!.instructions, 'user 系统管理');
      },
    );

    test(
      'disabled user same-name suppresses builtin without falling back',
      () async {
        final resolution = _resolve(
          user: [_novelSkill('系统管理', enabled: false)],
          bundled: [_bundledSkill('系统管理')],
        );

        expect(resolution.summaries, isEmpty);
        expect(resolution.content, isEmpty);
        expect(await resolution.loader('系统管理'), isNull);
      },
    );

    test('project same-name override wins over user and builtin', () async {
      final resolution = _resolve(
        project: [_novelSkill('系统管理', prompt: 'project 系统管理')],
        user: [_novelSkill('系统管理', prompt: 'user 系统管理')],
        bundled: [_bundledSkill('系统管理')],
      );

      expect(resolution.summaries, hasLength(1));
      expect(resolution.summaries.single.name, '系统管理');
      expect(resolution.content['系统管理'], 'project 系统管理');
      expect((await resolution.loader('系统管理'))!.instructions, 'project 系统管理');
    });

    test('disabled project suppresses user and builtin', () async {
      final resolution = _resolve(
        project: [_novelSkill('系统管理', enabled: false)],
        user: [_novelSkill('系统管理')],
        bundled: [_bundledSkill('系统管理')],
      );

      expect(resolution.summaries, isEmpty);
      expect(resolution.content, isEmpty);
      expect(await resolution.loader('系统管理'), isNull);
    });

    test('blocked project suppresses lower layers', () async {
      final resolution = _resolve(
        project: [_novelSkill('系统管理', blockedReason: 'emergency revoke')],
        user: [_novelSkill('系统管理')],
        bundled: [_bundledSkill('系统管理')],
      );

      expect(resolution.summaries, isEmpty);
      expect(await resolution.loader('系统管理'), isNull);
    });

    test(
      'project only overrides same name, other layers stay visible',
      () async {
        final resolution = _resolve(
          project: [_novelSkill('创作向导', prompt: 'project 创作向导')],
          user: [_novelSkill('系统管理', prompt: 'user 系统管理')],
          bundled: [_bundledSkill('故事连续性维护')],
        );

        expect(resolution.summaries.map((skill) => skill.name), [
          '创作向导',
          '系统管理',
          '故事连续性维护',
        ]);
        expect(resolution.content['创作向导'], 'project 创作向导');
        expect(resolution.content['系统管理'], 'user 系统管理');
        expect(resolution.content['故事连续性维护'], 'bundled prompt 故事连续性维护');
      },
    );

    test('content kind filters builtin summaries and content', () {
      final screenplay = _resolve(
        bundled: [
          _bundledSkill('创作向导'),
          _bundledSkill('剧本工具使用规范'),
          _bundledSkill('系统管理'),
        ],
        contentKind: contentKindScreenplay,
      );
      expect(screenplay.summaries.map((skill) => skill.name), [
        '剧本工具使用规范',
        '系统管理',
      ]);
      expect(screenplay.content.containsKey('创作向导'), isFalse);

      final novel = _resolve(
        bundled: [
          _bundledSkill('创作向导'),
          _bundledSkill('剧本工具使用规范'),
          _bundledSkill('系统管理'),
        ],
        contentKind: contentKindNovel,
      );
      expect(novel.summaries.map((skill) => skill.name), ['创作向导', '系统管理']);
      expect(novel.content.containsKey('剧本工具使用规范'), isFalse);
    });

    test('loader propagates references for project and user skills', () async {
      final reference = AgentSkillReferenceFile(
        path: 'references/example.md',
        content: 'example content',
      );
      final resolution = _resolve(
        project: [
          _novelSkill('创作向导', references: [reference]),
        ],
        user: [
          _novelSkill('系统管理', references: [reference]),
        ],
      );

      final projectLoaded = await resolution.loader('创作向导');
      expect(projectLoaded!.references.single.path, 'references/example.md');
      final userLoaded = await resolution.loader('系统管理');
      expect(userLoaded!.references.single.path, 'references/example.md');
    });

    test('resolution snapshot does not observe later list mutations', () async {
      final userSkills = <NovelAgentSkillModel>[_novelSkill('系统管理')];
      final resolution = _resolve(user: userSkills);

      userSkills.add(_novelSkill('创作向导'));

      expect(resolution.summaries.map((skill) => skill.name), ['系统管理']);
      expect(await resolution.loader('创作向导'), isNull);
    });
  });
}
