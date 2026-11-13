// 职责: R-33 单部局部(project) AgentSkill 覆盖集管理面板 —— 按 novel 维度列出、
//   新建、编辑、删除与启停 project 级覆盖技能。复用全局编辑表单结构。
// 关联文件:
//   lib/shared/providers/project_agent_skill_providers.dart
//   lib/shared/database/daos/novel_agent_skill_override_dao.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/desktop/features/agent_skills/setup_edit_panel.dart
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_more_menu_button.dart';
import '../../../shared/components/reveric_switch.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/novel_agent_skill.dart';
import '../../../shared/providers/project_agent_skill_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import '../../widgets/desktop_window_frame.dart';
import 'setup_edit_panel.dart';

/// 某作品的 project 层覆盖集管理页。
///
/// 与全局 [SkillSetupPanel] 不同，本页只管理 `novelId` 归属的覆盖技能，
/// 不涉及全局安装与目录。列表由
/// [projectAgentSkillOverridesProvider] 的 Drift watch 流驱动，写后自动刷新。
class ProjectAgentSkillPanel extends HookConsumerWidget {
  const ProjectAgentSkillPanel({
    super.key,
    required this.novelId,
    required this.novelTitle,
    required this.onBack,
    this.headerTrailingInset = 0,
    this.headerGestureExclusionKey,
  });

  final String novelId;
  final String novelTitle;
  final VoidCallback onBack;
  final double headerTrailingInset;
  final GlobalKey? headerGestureExclusionKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    // 非 null 时整页切换到编辑表单；null = 列表。
    final editing = useState<_ProjectEditTarget?>(null);

    if (editing.value != null) {
      return _ProjectSkillEditor(
        novelId: novelId,
        target: editing.value!,
        headerTrailingInset: headerTrailingInset,
        headerGestureExclusionKey: headerGestureExclusionKey,
        onBack: () => editing.value = null,
      );
    }

    final skillsAsync = ref.watch(projectAgentSkillOverridesProvider(novelId));
    final skills = skillsAsync.value ?? const <NovelAgentSkillModel>[];

    return Material(
      color: colors.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(
            context,
            colors,
            typo,
            onCreate: () {
              editing.value = const _ProjectNewSkill();
            },
          ),
          Divider(
            height: RevericSizes.dividerThickness,
            color: colors.border,
          ),
          Expanded(
            child: skillsAsync.isLoading && skills.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _ProjectSkillList(
                    skills: skills,
                    onCreate: () {
                      editing.value = const _ProjectNewSkill();
                    },
                    onToggle: (id, enabled) {
                      _toggle(context, ref, id, enabled);
                    },
                    onEdit: (skill) {
                      editing.value = _ProjectExistingSkill(skill);
                    },
                    onDelete: (skill) {
                      _delete(context, ref, skill);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo, {
    required VoidCallback onCreate,
  }) {
    return Container(
      key: headerGestureExclusionKey,
      height: DesktopWindowFrame.titleBarHeight,
      padding: EdgeInsetsDirectional.only(
        start: RevericSpacing.x2l,
        end: RevericSpacing.lg + headerTrailingInset,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onBack,
            icon: RevericIcon(
              RevericIcons.arrow_back,
              size: 18,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(width: RevericSpacing.xs),
          RevericIcon(
            RevericIcons.psychology_outlined,
            size: 18,
            color: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  context.t(LocaleKeys.agentSkillProjectTitle),
                  style: typo.heading2.copyWith(color: colors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  novelTitle,
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: onCreate,
            icon: RevericIcon(RevericIcons.add, size: 14),
            label: Text(context.t(LocaleKeys.commonCreate)),
          ),
        ],
      ),
    );
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    String id,
    bool enabled,
  ) async {
    await ref
        .read(projectAgentSkillOverrideServiceProvider)
        .setEnabled(id, enabled);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    NovelAgentSkillModel skill,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.t(LocaleKeys.commonDelete),
      message: context.t(
        LocaleKeys.agentSkillDeleteConfirm,
        namedArgs: {'name': skill.name},
      ),
      confirmLabel: context.t(LocaleKeys.agentSkillRemove),
      variant: ConfirmDialogVariant.error,
    );
    if (!confirmed) {
      return;
    }
    await ref
        .read(projectAgentSkillOverrideServiceProvider)
        .delete(skill.id);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.t(
            LocaleKeys.agentSkillToastRemoved,
            namedArgs: {'name': skill.name},
          ),
        ),
      ),
    );
  }
}

/// 编辑目标：新建或编辑已有覆盖。
sealed class _ProjectEditTarget {
  const _ProjectEditTarget();
}

class _ProjectNewSkill extends _ProjectEditTarget {
  const _ProjectNewSkill();
}

class _ProjectExistingSkill extends _ProjectEditTarget {
  const _ProjectExistingSkill(this.skill);

  final NovelAgentSkillModel skill;
}

/// project 覆盖编辑表单，复用 [AgentSkillSetupEditPanel]，保存写 service。
class _ProjectSkillEditor extends ConsumerWidget {
  const _ProjectSkillEditor({
    required this.novelId,
    required this.target,
    required this.onBack,
    this.headerTrailingInset = 0,
    this.headerGestureExclusionKey,
  });

  final String novelId;
  final _ProjectEditTarget target;
  final VoidCallback onBack;
  final double headerTrailingInset;
  final GlobalKey? headerGestureExclusionKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skill = target is _ProjectExistingSkill
        ? (target as _ProjectExistingSkill).skill
        : null;
    return AgentSkillSetupEditPanel(
      draft: skill == null
          ? const AgentSkillSetupEditDraft.novel()
          : AgentSkillSetupEditDraft(
              name: skill.name,
              whenToUse: skill.whenToUse,
              description: skill.description,
              prompt: skill.prompt,
              category: skill.category,
              tags: skill.tags,
              references: skill.references,
              enabled: skill.enabled,
            ),
      createTitleKey: LocaleKeys.agentSkillProjectCreate,
      subtitleKey: LocaleKeys.agentSkillProjectSubtitle,
      headerTrailingInset: headerTrailingInset,
      headerGestureExclusionKey: headerGestureExclusionKey,
      onBack: onBack,
      // project 覆盖暂无版本历史表，不显示历史入口。
      onOpenHistory: null,
      onSave: (draft) async {
        final service = ref.read(projectAgentSkillOverrideServiceProvider);
        await service.upsert(
          ProjectAgentSkillOverrideInput(
            novelId: novelId,
            name: draft.name,
            whenToUse: draft.whenToUse,
            description: draft.description,
            prompt: draft.prompt,
            category: draft.category,
            tags: draft.tags,
            references: draft.references,
            enabled: draft.enabled,
            existingId: skill?.id,
          ),
        );
        return draft;
      },
      // 保存成功后回到列表。延迟到帧尾，避免编辑表单 save() 的
      // finally 仍在访问已卸载的局部 hook state。
      onSaved: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onBack();
        });
      },
    );
  }
}

// ── 列表与行 ────────────────────────────────────────────────────────────────

class _ProjectSkillList extends StatelessWidget {
  const _ProjectSkillList({
    required this.skills,
    required this.onCreate,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final List<NovelAgentSkillModel> skills;
  final VoidCallback onCreate;
  final void Function(String id, bool enabled) onToggle;
  final ValueChanged<NovelAgentSkillModel> onEdit;
  final ValueChanged<NovelAgentSkillModel> onDelete;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) {
      return _ProjectEmptyState(onCreate: onCreate);
    }
    return ListView(
      padding: const EdgeInsetsDirectional.fromSTEB(
        RevericSpacing.x5l,
        RevericSpacing.x3l,
        RevericSpacing.x5l,
        RevericSpacing.x5l,
      ),
      children: [
        for (final skill in skills) ...[
          _ProjectSkillRow(
            skill: skill,
            onToggle: () => onToggle(skill.id, !skill.enabled),
            onEdit: () => onEdit(skill),
            onDelete: () => onDelete(skill),
          ),
          const SizedBox(height: RevericSpacing.lg),
        ],
      ],
    );
  }
}

class _ProjectSkillRow extends StatelessWidget {
  const _ProjectSkillRow({
    required this.skill,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final NovelAgentSkillModel skill;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final blocked = skill.executionBlockedReason != null;
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      decoration: BoxDecoration(
        color: blocked ? colors.warningBg : colors.surface,
        border: Border.all(
          color: blocked ? colors.warningText : colors.borderInput,
        ),
        borderRadius: BorderRadius.circular(RevericRadius.large),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(RevericRadius.large),
              child: Padding(
                padding: const EdgeInsets.only(right: RevericSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      skill.name,
                      style: typo.uiSmallSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    if (skill.whenToUse.isNotEmpty) ...[
                      const SizedBox(height: RevericSpacing.xs),
                      Text(
                        skill.whenToUse,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ],
                    const SizedBox(height: RevericSpacing.sm),
                    Text(
                      skill.description,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                    if (blocked)
                      Padding(
                        padding: const EdgeInsets.only(top: RevericSpacing.md),
                        child: _ProjectBlockedChip(
                          label: context.t(LocaleKeys.agentSkillBlocked),
                          fg: colors.warningText,
                          bg: colors.warningBg,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: RevericSpacing.lg),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RevericMoreMenuButton(
                entries: () => [
                  RevericMenuItem(
                    icon: RevericIcons.edit_outlined,
                    label: context.t(LocaleKeys.commonEdit),
                    onTap: onEdit,
                  ),
                  RevericMenuItem(
                    icon: RevericIcons.delete,
                    iconColor: colors.warningText,
                    labelColor: colors.warningText,
                    label: context.t(LocaleKeys.agentSkillRemove),
                    onTap: onDelete,
                  ),
                ],
              ),
              const SizedBox(width: RevericSpacing.md),
              RevericSwitch(
                value: skill.enabled,
                onChanged: (_) => onToggle(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProjectEmptyState extends StatelessWidget {
  const _ProjectEmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: RevericSpacing.x6l,
          horizontal: RevericSpacing.x4l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.psychology_outlined,
              size: 30,
              color: colors.textSubtle,
            ),
            const SizedBox(height: RevericSpacing.md),
            Text(
              context.t(LocaleKeys.agentSkillProjectEmptyTitle),
              style: typo.heading2.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: RevericSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                context.t(LocaleKeys.agentSkillProjectEmptyText),
                textAlign: TextAlign.center,
                style: typo.ui.copyWith(color: colors.textMuted, height: 1.6),
              ),
            ),
            const SizedBox(height: RevericSpacing.lg),
            FilledButton.icon(
              onPressed: onCreate,
              icon: RevericIcon(RevericIcons.add, size: 14),
              label: Text(context.t(LocaleKeys.commonCreate)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectBlockedChip extends StatelessWidget {
  const _ProjectBlockedChip({
    required this.label,
    required this.fg,
    required this.bg,
  });

  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(RevericIcons.warning_circle, size: 13, color: fg),
          const SizedBox(width: RevericSpacing.xxs),
          Text(label, style: typo.uiTiny.copyWith(color: fg)),
        ],
      ),
    );
  }
}
