// 职责: 工作区导航请求信号 — 「最近改动」点击条目时写入请求，novel_editor 监听后切换 selection/主内容区。
// 关联文件:
//   lib/shared/widgets/ai/diff/recent_changes_log.dart
//   lib/desktop/pages/novel_editor.dart
//   lib/shared/models/novel_workspace.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/novel_workspace.dart';
import '../models/workspace_task_routing.dart';

part 'workspace_navigation_provider.g.dart';

/// 一次性工作区导航请求：跳转到 [section] 下的 [itemId]（null 表示该 section 无独立条目，如作品简介）。
class WorkspaceNavigationRequest {
  const WorkspaceNavigationRequest({
    required this.section,
    this.itemId,
    this.isAutoRouted = false,
  });

  final NovelWorkspaceSection section;
  final String? itemId;

  /// 是否为任务自动路由（R-39）：true 表示由任务上下文触发，而非用户点击。
  /// 消费端可据此展示/记录来源；固定视图拦截发生在 [WorkspaceNavigation.requestTask]。
  final bool isAutoRouted;
}

/// 桌面端「最近改动」→ 工作区跳转的一次性信号。写入后由 novel_editor 监听消费并立即 [clear]。
@Riverpod(keepAlive: true)
class WorkspaceNavigation extends _$WorkspaceNavigation {
  /// R-39 固定视图：开启后任务自动路由不再切走主区（用户点击导航不受影响）。
  bool pinned = false;

  @override
  WorkspaceNavigationRequest? build() => null;

  void request(WorkspaceNavigationRequest value) => state = value;

  /// 任务自动路由（R-39）：按任务种类解析目标 section 后发起导航请求；
  /// 固定视图开启时静默丢弃，避免 AI 对话/后台任务擅自切换主视图。
  void requestTask(WorkspaceTaskKind kind, {String? itemId}) {
    if (pinned) {
      return;
    }
    request(
      WorkspaceNavigationRequest(
        section: resolveSectionForTask(kind),
        itemId: itemId,
        isAutoRouted: true,
      ),
    );
  }

  void togglePinned() {
    pinned = !pinned;
    // Riverpod 中 state 不变时 watch(provider.notifier) 不会自动重建，
    // 显式通知固定视图按钮刷新图标与 tooltip。
    ref.notifyListeners();
  }

  void clear() => state = null;
}
