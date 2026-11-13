// 职责: R-33 Skill 三层目录纯函数解析 —— 合并 project/user/builtin 同名覆盖，
//   按 project > user > builtin 优先级产出摘要、正文快照与按需加载器。
// 关联文件:
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/services/bundled_control_skills.dart
//   lib/shared/models/agent_skill.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/models/content_kind.dart
// 遵循的 Rules:
//   .agents/rules/agent-skills.md

import '../../models/agent_skill.dart';
import '../../models/agent_skill_reference.dart';
import '../../models/content_kind.dart';
import '../../models/novel_agent_skill.dart';
import '../bundled_control_skills.dart';

/// R-33 三层解析结果。
///
/// [summaries] 只含当前作品实际可见的技能摘要；[content] 是 name → prompt
/// 的正文快照；[loader] 按名称加载完整指令与附件，并保持同名覆盖优先级。
class AgentSkillResolution {
  const AgentSkillResolution({
    required this.summaries,
    required this.content,
    required this.loader,
  });

  final List<AgentSkillSummary> summaries;
  final Map<String, String> content;
  final Future<AgentSkillLoadResult?> Function(String name) loader;
}

/// 合并三层 Skill 目录，并固定本轮任务快照。
///
/// - [projectSkills]：单部局部覆盖集，当前无 DB 载体，由宿主注入；
/// - [userSkills]：应用全局已安装技能（`installedAgentSkillsProvider`）；
/// - [bundledSkills]：已按作品类型过滤、且未被 project/user 覆盖的默认 fallback；
/// - [bundledLoader]：按 callName 加载 bundled 技能的按需入口。
///
/// 同名优先级为 `project > user > builtin`。任何一层存在同名技能（含
/// disabled/blocked）都会压制更低层，与现有「用户同名覆盖 bundled 默认行为」
/// 语义一致；disabled/blocked 技能不可加载，但不回落到低层。
AgentSkillResolution resolveAgentSkillLayers({
  required List<NovelAgentSkillModel> projectSkills,
  required List<NovelAgentSkillModel> userSkills,
  required List<BundledControlSkill> bundledSkills,
  required String contentKind,
  required Future<BundledControlSkill?> Function(String callName) bundledLoader,
}) {
  // 同层内重名时取首次出现，保证解析确定性；项目层优先屏蔽 user/builtin。
  final projectByName = <String, NovelAgentSkillModel>{};
  for (final skill in projectSkills) {
    projectByName.putIfAbsent(skill.name, () => skill);
  }
  final userByName = <String, NovelAgentSkillModel>{};
  for (final skill in userSkills) {
    userByName.putIfAbsent(skill.name, () => skill);
  }
  final projectNames = projectByName.keys.toSet();
  final userNames = userByName.keys.toSet();

  bool isBuiltinAllowed(String callName) {
    if (contentKind == contentKindScreenplay && callName == '创作向导') {
      return false;
    }
    if (contentKind != contentKindScreenplay && callName == '剧本工具使用规范') {
      return false;
    }
    return true;
  }

  AgentSkillSummary summaryForNovel(NovelAgentSkillModel skill) {
    return AgentSkillSummary(
      name: skill.name,
      whenToUse: skill.whenToUse,
      description: skill.description,
    );
  }

  AgentSkillSummary summaryForBundled(BundledControlSkill skill) {
    return AgentSkillSummary(
      name: skill.callName,
      whenToUse: skill.whenToUse,
      description: skill.description,
    );
  }

  AgentSkillLoadResult loadResultForNovel(NovelAgentSkillModel skill) {
    return AgentSkillLoadResult(
      instructions: skill.prompt,
      references: [
        for (final reference in skill.references)
          AgentSkillReferenceDescriptor(path: reference.path),
      ],
    );
  }

  AgentSkillLoadResult loadResultForBundled(BundledControlSkill skill) {
    return AgentSkillLoadResult(
      instructions: skill.prompt,
      references: [
        for (final reference in skill.references)
          AgentSkillReferenceDescriptor(path: reference.path),
      ],
    );
  }

  final summaries = <AgentSkillSummary>[];
  final content = <String, String>{};

  for (final skill in projectSkills) {
    // 只处理每层首次出现的同名条目，避免重复摘要/正文。
    if (projectByName[skill.name]?.id != skill.id) {
      continue;
    }
    if (!skill.isExecutable) {
      continue;
    }
    summaries.add(summaryForNovel(skill));
    content[skill.name] = skill.prompt;
  }

  for (final skill in userSkills) {
    if (userByName[skill.name]?.id != skill.id) {
      continue;
    }
    if (projectNames.contains(skill.name) || !skill.isExecutable) {
      continue;
    }
    summaries.add(summaryForNovel(skill));
    content[skill.name] = skill.prompt;
  }

  for (final skill in bundledSkills) {
    if (projectNames.contains(skill.callName) ||
        userNames.contains(skill.callName) ||
        !isBuiltinAllowed(skill.callName)) {
      continue;
    }
    summaries.add(summaryForBundled(skill));
    content[skill.callName] = skill.prompt;
  }

  Future<AgentSkillLoadResult?> loader(String name) async {
    final project = projectByName[name];
    if (project != null) {
      return project.isExecutable ? loadResultForNovel(project) : null;
    }
    final user = userByName[name];
    if (user != null) {
      return user.isExecutable ? loadResultForNovel(user) : null;
    }
    if (!bundledControlCallNames.contains(name)) {
      return null;
    }
    final bundled = await bundledLoader(name);
    if (bundled == null) {
      return null;
    }
    return loadResultForBundled(bundled);
  }

  return AgentSkillResolution(
    summaries: List<AgentSkillSummary>.unmodifiable(summaries),
    content: Map<String, String>.unmodifiable(content),
    loader: loader,
  );
}
