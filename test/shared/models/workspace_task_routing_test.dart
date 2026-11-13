// 职责: 验证 R-39 任务种类到工作区 section 的纯函数映射。
// 关联文件:
//   lib/shared/models/workspace_task_routing.dart
//   lib/shared/models/novel_workspace.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/models/workspace_task_routing.dart';

void main() {
  test('maps every task kind to the correct workspace section', () {
    expect(
      resolveSectionForTask(WorkspaceTaskKind.characterSetting),
      NovelWorkspaceSection.characters,
    );
    expect(
      resolveSectionForTask(WorkspaceTaskKind.characterRelation),
      NovelWorkspaceSection.entity_graph,
    );
    expect(
      resolveSectionForTask(WorkspaceTaskKind.chapterContext),
      NovelWorkspaceSection.chapters,
    );
    expect(
      resolveSectionForTask(WorkspaceTaskKind.volumePlotline),
      NovelWorkspaceSection.outlines,
    );
    expect(
      resolveSectionForTask(WorkspaceTaskKind.storyTime),
      NovelWorkspaceSection.story_progress,
    );
    expect(
      resolveSectionForTask(WorkspaceTaskKind.foreshadowing),
      NovelWorkspaceSection.foreshadowings,
    );
    expect(
      resolveSectionForTask(WorkspaceTaskKind.impactReview),
      NovelWorkspaceSection.impact_audit,
    );
    expect(
      resolveSectionForTask(WorkspaceTaskKind.visualAsset),
      NovelWorkspaceSection.materials,
    );
  });
}
