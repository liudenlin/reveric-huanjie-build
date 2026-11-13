// 职责: M7 研究任务独立窗口 — 承载多模型研究任务面板（任务列表/发起/审批/执行/回填）。
// 关联文件:
//   lib/desktop/widgets/detached_window.dart (DetachedWindowSession/Anchor)
//   lib/shared/services/research_task_service.dart (ResearchTaskService)
//   lib/desktop/pages/novel_editor.dart (Anchor 挂载点)
// 遵循的 Rules:
//   .agents/rules/design-system.md
//
// §M7 研究任务：独立窗口 + 模型选择 + 预算 + 提交审批 + 结果回填。
// 本窗口是 M7 的 UI 外壳：一个 DetachedWindowSession 承载 ResearchTaskPanel，
// 面板内部管理任务列表、发起表单（模型/预算）、审批/执行按钮与结果展示。

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/ai_provider.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/theme/theme.dart';
import '../ai/model/model_selector.dart';
import '../desktop_window_frame.dart';
import '../detached_window.dart';

/// 研究任务独立窗口会话。
class ResearchTaskWindowSession extends DetachedWindowSession {
  ResearchTaskWindowSession()
    : super(
        placementKey: 'research_task_window_placement',
        defaultSize: const Size(760, 880),
        constraints: const BoxConstraints(minWidth: 520, minHeight: 480),
        logModule: 'ResearchTaskWindow',
      );

  Novel? _novel;

  /// 打开指定作品的研究任务窗口；已打开时切换到该作品并激活。
  Future<void> openForNovel(Novel novel, {required DetachedWindowTheme theme}) {
    _novel = novel;
    return open(
      title: novel.title.isNotEmpty ? '${novel.title} · 研究任务' : '研究任务',
      theme: theme,
    );
  }
}

/// 独立窗口宿主：挂在编辑页级（与阅读窗口同级）。
class ResearchTaskWindowAnchor extends StatelessWidget {
  const ResearchTaskWindowAnchor({
    super.key,
    required this.session,
    required this.child,
  });

  final ResearchTaskWindowSession session;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DetachedWindowAnchor(
      session: session,
      builder: (context) {
        final novel = session._novel;
        if (novel == null) {
          return const SizedBox.shrink();
        }
        return ResearchTaskWindowPage(
          key: ValueKey(novel.id),
          session: session,
        );
      },
      child: child,
    );
  }
}

/// 研究任务窗口主页面。
class ResearchTaskWindowPage extends ConsumerStatefulWidget {
  const ResearchTaskWindowPage({
    super.key,
    required this.session,
  });

  final ResearchTaskWindowSession session;

  @override
  ConsumerState<ResearchTaskWindowPage> createState() =>
      _ResearchTaskWindowPageState();
}

class _ResearchTaskWindowPageState extends ConsumerState<ResearchTaskWindowPage> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _budgetController = TextEditingController();

  // 已选中的模型 provider id；与 [_selectedModelId] 成对存储，
  // 提交研究任务时传给 ResearchTaskService.submit(providerId:, modelId:)。
  String? _selectedProviderId;

  // 已选中的模型 id（AiModelOption.id 中 '::' 分隔的后半段）。
  String? _selectedModelId;

  @override
  void dispose() {
    _titleController.dispose();
    _promptController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Scaffold(
      backgroundColor: colors.canvas,
      body: DesktopWindowFrame(
        showCustomTitleBar: false,
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.x2l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.t(LocaleKeys.workspaceResearchTaskWindowTitle),
                style: typo.heading2.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.xs),
              Text(
                context.t(LocaleKeys.workspaceResearchTaskWindowHint),
                style: typo.ui.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              Expanded(
                child: ListView(
                  children: [
                    _buildSectionLabel(context, '发起研究'),
                    _buildTitleInput(context),
                    _buildPromptInput(context),
                    _buildBudgetInput(context),
                    _buildModelSelector(context),
                    const SizedBox(height: RevericSpacing.xl),
                    _buildTaskList(context),
                    _buildActions(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(BuildContext context, String label) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.xs),
      child: Text(label, style: typo.ui.copyWith(color: colors.textMuted)),
    );
  }

  Widget _buildTitleInput(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return TextField(
      controller: _titleController,
      decoration: InputDecoration(
        hintText: '任务标题（如：研究反派动机）',
        filled: true,
        fillColor: colors.canvas,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(RevericRadius.x2l),
          borderSide: BorderSide(color: colors.border),
        ),
      ),
    );
  }

  Widget _buildPromptInput(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: RevericSpacing.xs),
      child: TextField(
        controller: _promptController,
        maxLines: 4,
        decoration: InputDecoration(
          hintText: '研究指令 / 问题（喂给 Agent 的 prompt）',
          filled: true,
          fillColor: colors.canvas,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(RevericRadius.x2l),
            borderSide: BorderSide(color: colors.border),
          ),
        ),
      ),
    );
  }

  Widget _buildBudgetInput(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: RevericSpacing.xs),
      child: TextField(
        controller: _budgetController,
        keyboardType: const TextInputType.numberWithOptions(signed: false),
        decoration: InputDecoration(
          hintText: '预算上限（token，0=不限）',
          suffixText: ' tokens',
          filled: true,
          fillColor: colors.canvas,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(RevericRadius.x2l),
            borderSide: BorderSide(color: colors.border),
          ),
        ),
      ),
    );
  }

  Widget _buildModelSelector(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: RevericSpacing.xs),
      // 研究任务由文本 Agent 执行，只列出 chat 类可用模型；选择结果存入
      // [_selectedProviderId]/[_selectedModelId]，供提交研究任务时使用。
      child: Consumer(
        builder: (context, ref, _) {
          final options = [
            for (final m in ref.watch(availableAiModelsProvider))
              if (m.kind == AiModelKind.chat) m,
          ];
          final selectedId =
              _selectedProviderId != null && _selectedModelId != null
                  ? '$_selectedProviderId::$_selectedModelId'
                  : null;
          final selectedOption = selectedId == null
              ? null
              : options.where((o) => o.id == selectedId).firstOrNull;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: ModelSelector.field(
                  availableModels: options,
                  selectedId: selectedId,
                  placeholder: '选择模型',
                  emptyMessage: '请先在设置中配置模型',
                  onChanged: (id) => _onModelIdChanged(id),
                  dense: true,
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              SizedBox(
                width: 160,
                child: selectedOption == null
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          '未选择模型',
                          style:
                              typo.uiSmall.copyWith(color: colors.textMuted),
                        ),
                      )
                    : Align(
                        alignment: Alignment.centerRight,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              selectedOption.displayModelName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: typo.uiSmall.copyWith(
                                color: colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              selectedOption.providerDisplayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: typo.uiTiny.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 模型选择回调：`ModelSelector.field` 返回组合 id（`providerId::model`）。
  void _onModelIdChanged(String? id) {
    setState(() {
      if (id == null) {
        // 选择了「未设置」。
        _selectedProviderId = null;
        _selectedModelId = null;
        return;
      }
      final parts = id.split('::');
      if (parts.length == 2) {
        _selectedProviderId = parts[0];
        _selectedModelId = parts[1];
      }
    });
  }

  Widget _buildTaskList(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: RevericSpacing.xl),
      child: Text(
        '任务列表（发起→审批→执行→回填）将在此渲染。',
        style: TextStyle(fontSize: 13, color: colors.textMuted),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: RevericSpacing.xl, bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () {},
            child: Text('提交审批', style: TextStyle(color: colors.textPrimary)),
          ),
          const SizedBox(width: RevericSpacing.xs),
          FilledButton(
            onPressed: () {},
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
            ),
            child: Text('执行研究任务'),
          ),
        ],
      ),
    );
  }
}
