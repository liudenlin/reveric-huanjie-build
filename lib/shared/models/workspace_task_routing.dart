// 职责: R-39 按任务上下文动态路由工作区视图 — 任务种类到目标 section 的纯函数映射。
// 关联文件:
//   lib/shared/models/novel_workspace.dart (NovelWorkspaceSection)
//   lib/shared/providers/workspace_navigation_provider.dart (任务自动路由请求)
//   lib/desktop/pages/novel_editor.dart (导航请求消费端)
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'novel_workspace.dart';

/// 工作区任务种类（R-39）：由任务上下文驱动「切换到最合适视图」。
///
/// R-39 映射表中搜集资料（Research Workbench）、最近变更（Change Ledger）、
/// 讨论决策（Discussion Intelligence）暂无独立主区 section，待对应视图
/// 存在后再扩展本枚举，不强行路由到相近视图。
enum WorkspaceTaskKind {
  /// 人物设定讨论/修改 → 人物档案。
  characterSetting,

  /// 两人物关系讨论 → 关系图。
  characterRelation,

  /// 某章前后正文讨论 → 章节编辑器。
  chapterContext,

  /// 全卷剧情线/章纲讨论 → 卷纲章纲。
  volumePlotline,

  /// 故事时间线讨论 → 故事进度。
  storyTime,

  /// 伏笔讨论 → 伏笔生命周期。
  foreshadowing,

  /// 修改后影响审计 → 影响审计面板。
  impactReview,

  /// 角色/场景/道具视觉资产 → 素材库。
  visualAsset,
}

/// 任务种类 → 最合适的工作区 section。
///
/// 纯函数无副作用，供 [workspaceNavigationProvider] 的任务自动路由与单测复用。
NovelWorkspaceSection resolveSectionForTask(WorkspaceTaskKind kind) {
  return switch (kind) {
    WorkspaceTaskKind.characterSetting => NovelWorkspaceSection.characters,
    WorkspaceTaskKind.characterRelation => NovelWorkspaceSection.entity_graph,
    WorkspaceTaskKind.chapterContext => NovelWorkspaceSection.chapters,
    WorkspaceTaskKind.volumePlotline => NovelWorkspaceSection.outlines,
    WorkspaceTaskKind.storyTime => NovelWorkspaceSection.story_progress,
    WorkspaceTaskKind.foreshadowing => NovelWorkspaceSection.foreshadowings,
    WorkspaceTaskKind.impactReview => NovelWorkspaceSection.impact_audit,
    WorkspaceTaskKind.visualAsset => NovelWorkspaceSection.materials,
  };
}
