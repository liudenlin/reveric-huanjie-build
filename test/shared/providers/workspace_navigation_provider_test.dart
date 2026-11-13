// 职责: 验证工作区导航请求与 R-39 固定视图拦截。
// 关联文件:
//   lib/shared/providers/workspace_navigation_provider.dart
//   lib/shared/models/workspace_task_routing.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/testing.md

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/models/workspace_task_routing.dart';
import 'package:reveric/shared/providers/workspace_navigation_provider.dart';

void main() {
  test('requestTask routes to the resolved section with auto flag', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(workspaceNavigationProvider.notifier);

    notifier.requestTask(WorkspaceTaskKind.chapterContext, itemId: 'ch_1');
    final state = container.read(workspaceNavigationProvider);
    expect(state?.section, NovelWorkspaceSection.chapters);
    expect(state?.itemId, 'ch_1');
    expect(state?.isAutoRouted, isTrue);
  });

  test('pinned view blocks auto routing and toggle restores it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(workspaceNavigationProvider.notifier);

    notifier.requestTask(WorkspaceTaskKind.foreshadowing, itemId: 'f_1');
    final before = container.read(workspaceNavigationProvider);

    notifier.togglePinned();
    expect(notifier.pinned, isTrue);
    notifier.requestTask(WorkspaceTaskKind.characterSetting);
    expect(container.read(workspaceNavigationProvider), same(before));

    notifier.togglePinned();
    expect(notifier.pinned, isFalse);
    notifier.requestTask(WorkspaceTaskKind.storyTime);
    final after = container.read(workspaceNavigationProvider);
    expect(after?.section, NovelWorkspaceSection.story_progress);
    expect(after?.isAutoRouted, isTrue);
  });

  test('clear resets the navigation request', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(workspaceNavigationProvider.notifier);

    notifier.requestTask(WorkspaceTaskKind.visualAsset);
    expect(container.read(workspaceNavigationProvider), isNotNull);

    notifier.clear();
    expect(container.read(workspaceNavigationProvider), isNull);
  });
}
