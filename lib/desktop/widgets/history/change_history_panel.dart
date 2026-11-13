// 职责: 桌面端全局修改历史面板 — 双栏组装 commit 列表与选中提交明细 diff，复用 shared 组件。
// 关联文件:
//   lib/shared/widgets/history/change_history_components.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/services/working_change_summary.dart
//   lib/shared/widgets/ai/diff/diff_view.dart
//   lib/shared/localization/locale_keys.dart
//   lib/desktop/widgets/history/resource_history_button.dart
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/history/change_history_components.dart';

class ChangeHistoryPanel extends ConsumerStatefulWidget {
  const ChangeHistoryPanel({
    super.key,
    required this.databasePath,
    this.novelId,
    this.resourceId,
    this.resourceLabel,
    this.onClose,
  });

  final String databasePath;
  final int? novelId;
  final String? resourceId;
  final String? resourceLabel;
  final VoidCallback? onClose;

  @override
  ConsumerState<ChangeHistoryPanel> createState() => _ChangeHistoryPanelState();
}

class _ChangeHistoryPanelState extends ConsumerState<ChangeHistoryPanel> {
  String? _selectedCommitId;
  HistorySourceFilter _filter = HistorySourceFilter.all;
  HistoryTimeRange _timeRange = HistoryTimeRange.all;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scopedResourceId = widget.resourceId;
    final commitsAsync = ref.watch(
      changeCommitsProvider(path: widget.databasePath, limit: 200),
    );
    final resourceHistoryAsync = scopedResourceId == null
        ? const AsyncValue<List<ChangeCommitItem>>.data(<ChangeCommitItem>[])
        : ref.watch(
            resourceIdChangeHistoryProvider(
              path: widget.databasePath,
              resourceId: scopedResourceId,
              limit: 200,
            ),
          );

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: SelectionArea(
        child: Column(
          children: [
            _buildHeader(context, typo, colors),
            Divider(height: 1, color: colors.borderSubtle),
            Expanded(
              child: commitsAsync.when(
                data: (commits) {
                  final resourceHistory = resourceHistoryAsync.asData?.value;
                  if (scopedResourceId != null && resourceHistory == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final (from, to) = _timeBounds(_timeRange);
                  final filtered = filterChangeCommits(
                    commits: commits,
                    filter: _filter,
                    resourceId: scopedResourceId,
                    resourceHistory: resourceHistory,
                    from: from,
                    to: to,
                  );
                  if (filtered.isEmpty) {
                    return _buildEmpty(context, typo, colors);
                  }
                  final commitItemMap = groupCommitItemsByCommit(
                    resourceHistory,
                  );
                  final selectedId =
                      _selectedCommitId != null &&
                          filtered.any((c) => c.id == _selectedCommitId)
                      ? _selectedCommitId!
                      : filtered.first.id;
                  final selected = filtered.firstWhere(
                    (c) => c.id == selectedId,
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 320,
                        child: CommitList(
                          commits: filtered,
                          commitItemMap: commitItemMap,
                          selectedId: selectedId,
                          onSelect: (id) =>
                              setState(() => _selectedCommitId = id),
                        ),
                      ),
                      VerticalDivider(width: 1, color: colors.borderSubtle),
                      Expanded(
                        child: CommitDetail(
                          databasePath: widget.databasePath,
                          commit: selected,
                          resourceId: widget.resourceId,
                          onClose: widget.onClose,
                        ),
                      ),
                    ],
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => Center(
                  child: Text(
                    context.t(LocaleKeys.historyLoadingFailed),
                    style: typo.uiMedium.copyWith(color: colors.textMuted),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    RevericTypography typo,
    RevericColors colors,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.md,
      ),
      color: colors.surfaceDim,
      child: Row(
        children: [
          RevericIcon(
            RevericIcons.history_rounded,
            size: 18,
            color: colors.textSecondary,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            widget.resourceLabel == null
                ? context.t(LocaleKeys.historyTitle)
                : context.t(
                    LocaleKeys.historyResourceTitle,
                    namedArgs: {'name': widget.resourceLabel!},
                  ),
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(width: RevericSpacing.x3l),
          HistoryFilterChip(
            label: context.t(LocaleKeys.historyFilterAll),
            selected: _filter == HistorySourceFilter.all,
            onTap: () => setState(() => _filter = HistorySourceFilter.all),
          ),
          const SizedBox(width: RevericSpacing.xs),
          HistoryFilterChip(
            label: context.t(LocaleKeys.historyFilterSourceAi),
            selected: _filter == HistorySourceFilter.ai,
            onTap: () => setState(() => _filter = HistorySourceFilter.ai),
          ),
          const SizedBox(width: RevericSpacing.xs),
          HistoryFilterChip(
            label: context.t(LocaleKeys.historyFilterSourceManual),
            selected: _filter == HistorySourceFilter.manual,
            onTap: () => setState(() => _filter = HistorySourceFilter.manual),
          ),
          const SizedBox(width: RevericSpacing.x3l),
          HistoryFilterChip(
            label: _timeRangeLabel(context, HistoryTimeRange.all),
            selected: _timeRange == HistoryTimeRange.all,
            onTap: () =>
                setState(() => _timeRange = HistoryTimeRange.all),
          ),
          const SizedBox(width: RevericSpacing.xs),
          HistoryFilterChip(
            label: _timeRangeLabel(context, HistoryTimeRange.today),
            selected: _timeRange == HistoryTimeRange.today,
            onTap: () =>
                setState(() => _timeRange = HistoryTimeRange.today),
          ),
          const SizedBox(width: RevericSpacing.xs),
          HistoryFilterChip(
            label: _timeRangeLabel(context, HistoryTimeRange.last7Days),
            selected: _timeRange == HistoryTimeRange.last7Days,
            onTap: () =>
                setState(() => _timeRange = HistoryTimeRange.last7Days),
          ),
          const SizedBox(width: RevericSpacing.xs),
          HistoryFilterChip(
            label: _timeRangeLabel(context, HistoryTimeRange.last30Days),
            selected: _timeRange == HistoryTimeRange.last30Days,
            onTap: () =>
                setState(() => _timeRange = HistoryTimeRange.last30Days),
          ),
          const Spacer(),
          if (widget.onClose != null)
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonLabel,
              icon: const RevericIcon(RevericIcons.close_rounded, size: 18),
              onPressed: widget.onClose,
              color: colors.textMuted,
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(
    BuildContext context,
    RevericTypography typo,
    RevericColors colors,
  ) {
    // 来源或时间范围激活时，追加一行说明该筛选条件下无匹配记录，
    // 避免与"完全没有历史记录"混淆。
    final hasActiveFilters =
        _filter != HistorySourceFilter.all ||
        _timeRange != HistoryTimeRange.all;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            RevericIcons.inbox_outlined,
            size: 32,
            color: colors.textMuted,
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            widget.resourceId == null
                ? context.t(LocaleKeys.historyEmpty)
                : context.t(LocaleKeys.historyResourceEmpty),
            style: typo.uiMedium.copyWith(color: colors.textMuted),
          ),
          if (hasActiveFilters) ...[
            const SizedBox(height: RevericSpacing.xs),
            Text(
              // 该提示未走 i18n：本次改动不允许触碰 locale_keys 与翻译 JSON，
              // 项目为本地中文写作工具，直接使用中文字面量即可。
              '当前筛选条件下没有匹配记录',
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  /// 把外层档位翻译成 chip 文案。
  ///
  /// "全部"复用既有 key history.filter_all；今天/近7天/近30天暂无对应翻译键，
  /// 本次不允许改动 locale_keys 与翻译 JSON，直接使用中文字面量
  /// （项目为本地中文写作工具，与"全部"的区分度足够）。
  String _timeRangeLabel(
    BuildContext context,
    HistoryTimeRange range,
  ) {
    switch (range) {
      case HistoryTimeRange.all:
        return context.t(LocaleKeys.historyFilterAll);
      case HistoryTimeRange.today:
        return '今天';
      case HistoryTimeRange.last7Days:
        return '近7天';
      case HistoryTimeRange.last30Days:
        return '近30天';
    }
  }

  /// 计算时间范围档位对应的起止闭区间；"全部"返回 (null, null) 表示不设限。
  (DateTime?, DateTime?) _timeBounds(HistoryTimeRange range) {
    final now = DateTime.now();
    // 按本地时区的自然日切分：当天 0 点为起点，次日 0 点为终点（含当天全部时刻）。
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));
    switch (range) {
      case HistoryTimeRange.all:
        return (null, null);
      case HistoryTimeRange.today:
        return (todayStart, todayEnd);
      case HistoryTimeRange.last7Days:
        // 近7天 = 今天 + 之前6天，共7个自然日。
        return (todayStart.subtract(const Duration(days: 6)), todayEnd);
      case HistoryTimeRange.last30Days:
        // 近30天 = 今天 + 之前29天，共30个自然日。
        return (todayStart.subtract(const Duration(days: 29)), todayEnd);
    }
  }
}
