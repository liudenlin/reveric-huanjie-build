// 职责: 「影响审计」面板 — 展示 AI / 手动修改正文后自动生成的变更影响报告，
//   列出受影响章节 / 伏笔 / 关系 / 人物，附原文证据与置信度，支持人工标记已复核。
// 关联文件:
//   lib/desktop/widgets/workspace/impact_audit_panel.dart
//   lib/shared/services/impact_audit_models.dart (ImpactAuditResult / ImpactHit)
//   lib/shared/database/novel_content_daos/impact_audit_dao.dart (ImpactAuditDao)
//   lib/shared/database/novel_content_database.dart (ImpactAudits 表 / 状态常量)
//   lib/shared/providers/novel_providers.dart (novelContentDatabaseProvider)
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/widget-decomposition.md
//   .agents/rules/hooks.md
//
// 验收（施工总纲 M4）：影响报告展示 — 桌面端展示 auditRow.resultJson、
//   待复核标记、已复核点击。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../database/novel_content_database.dart';
import '../localization/app_localization.dart';
import '../localization/locale_keys.dart';
import '../logger/app_logger.dart';
import '../providers/novel_providers.dart';
import '../services/impact_audit_models.dart';
import '../theme/theme.dart';

final _log = AppLogger.forModule('ImpactAudit');

/// 影响审计面板 — 按时间倒序展示全部审计记录。
///
/// 每条记录对应一次正文/设定变更：列出受影响的下游章节、伏笔、关系与人物，
/// 每条命中带原文证据、出处与置信度。有下游命中且尚未人工确认的记录标记为
/// 「待复核」，用户确认下游无碍后点「标记已复核」解除。
class ImpactAuditPanel extends ConsumerWidget {
  const ImpactAuditPanel({
    super.key,
    required this.databasePath,
    this.padding = const EdgeInsets.fromLTRB(
      RevericSpacing.x6l,
      RevericSpacing.x4l,
      RevericSpacing.x6l,
      RevericSpacing.x6l,
    ),
  });

  final String? databasePath;

  /// 外层滚动区内边距；移动端传入更紧的边距。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = databasePath;
    if (path == null || path.trim().isEmpty) {
      return const _ImpactAuditEmptyState();
    }

    // 审计记录流（新→旧）：经 impactAuditsProvider 可被测试 override。
    final recordsAsync = ref.watch(impactAuditsProvider(path));

    final records = recordsAsync.asData?.value;
    if (recordsAsync.hasError) {
      return SingleChildScrollView(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ImpactAuditHeader(total: 0),
            const SizedBox(height: RevericSpacing.x3l),
            _ImpactAuditErrorState(error: recordsAsync.error ?? ''),
          ],
        ),
      );
    }
    if (records == null) {
      return const _ImpactAuditLoadingState();
    }
    return SingleChildScrollView(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ImpactAuditHeader(total: records.length),
          const SizedBox(height: RevericSpacing.x3l),
          if (records.isEmpty)
            const _ImpactAuditEmptyState()
          else
            for (final audit in records) ...[
              _AuditRecordCard(
                audit: audit,
                onMarkReviewed: audit.status == impactAuditStatusRecorded
                    ? () => _markReviewed(context, ref, path, audit.id)
                    : null,
              ),
              const SizedBox(height: RevericSpacing.x2l),
            ],
        ],
      ),
    );
  }

  Future<void> _markReviewed(
    BuildContext context,
    WidgetRef ref,
    String path,
    String auditId,
  ) async {
    try {
      await ref
          .read(novelContentDatabaseProvider(path))
          .impactAuditDao
          .markReviewed(auditId);
    } catch (e) {
      _log.warning('标记已复核失败: $auditId: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('标记已复核失败：$e')),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 头部
// ---------------------------------------------------------------------------

class _ImpactAuditHeader extends StatelessWidget {
  const _ImpactAuditHeader({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      children: [
        RevericIcon(
          RevericIcons.checklist_rounded,
          size: 16,
          color: colors.textMuted,
        ),
        const SizedBox(width: RevericSpacing.sm),
        Expanded(
          child: Text(
            context.t(LocaleKeys.workspaceImpactAudit),
            style: typo.uiSemibold.copyWith(color: colors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          context.t(
            LocaleKeys.workspaceImpactAuditTotalHits,
            namedArgs: {'count': '$total'},
          ),
          style: typo.uiSmall.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 单条审计记录卡
// ---------------------------------------------------------------------------

class _AuditRecordCard extends StatelessWidget {
  const _AuditRecordCard({required this.audit, required this.onMarkReviewed});

  final ImpactAudit audit;
  final VoidCallback? onMarkReviewed;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);

    // resultJson → 可展示结构；解析失败则退化为原文片段。
    final result = _parseResult(audit.resultJson);
    final hasHits = result != null && result.totalHitCount > 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RecordHeader(audit: audit, hasHits: hasHits),
          const SizedBox(height: RevericSpacing.lg),
          _ResourceMeta(audit: audit),
          if (result != null) ...[
            const SizedBox(height: RevericSpacing.lg),
            _CoverageNotice(result: result),
            const SizedBox(height: RevericSpacing.sm),
            _SuggestedAction(result: result),
          ],
          const SizedBox(height: RevericSpacing.lg),
          if (result != null && hasHits) ...[
            _HitsSection(result: result),
          ] else if (result != null) ...[
            _NoHitsNotice(),
          ] else ...[
            _RawResultFallback(raw: audit.resultJson),
          ],
          if (onMarkReviewed != null) ...[
            const SizedBox(height: RevericSpacing.x2l),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: onMarkReviewed,
                icon: RevericIcon(
                  RevericIcons.check_circle,
                  size: 16,
                  color: colors.success,
                ),
                label: Text(context.t(LocaleKeys.workspaceImpactAuditMarkReviewed)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 记录头：状态徽章 + 命中数 + 时间。
class _RecordHeader extends StatelessWidget {
  const _RecordHeader({required this.audit, required this.hasHits});

  final ImpactAudit audit;
  final bool hasHits;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      children: [
        _StatusBadge(status: audit.status, hasHits: hasHits),
        const SizedBox(width: RevericSpacing.md),
        Expanded(
          child: Text(
            hasHits
                ? context.t(
                    LocaleKeys.workspaceImpactAuditTotalHits,
                    namedArgs: {'count': '${audit.hitCount}'},
                  )
                : context.t(LocaleKeys.workspaceImpactAuditNoHits),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: RevericSpacing.md),
        Text(
          _formatTime(audit.createdAt),
          style: typo.uiTiny.copyWith(color: colors.textSubtle),
        ),
      ],
    );
  }
}

/// 状态徽章：待复核（橙）/ 已复核（绿）/ 无下游影响（灰）。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, required this.hasHits});

  final String status;
  final bool hasHits;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final (label, color, bg) = switch (status) {
      impactAuditStatusRecorded => (
        context.t(LocaleKeys.workspaceImpactAuditRecorded),
        colors.warningText,
        colors.warningBg,
      ),
      impactAuditStatusReviewed => (
        context.t(LocaleKeys.workspaceImpactAuditReviewed),
        colors.success,
        colors.success.withValues(alpha: 0.12),
      ),
      _ => (
        context.t(LocaleKeys.workspaceImpactAuditNone),
        colors.textMuted,
        colors.surfaceContainer,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Text(
        label,
        style: typo.uiTinySemibold.copyWith(color: color),
      ),
    );
  }
}

/// 变更对象元信息：资源路径 + 来源。
class _ResourceMeta extends StatelessWidget {
  const _ResourceMeta({required this.audit});

  final ImpactAudit audit;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: RevericSpacing.lg,
      runSpacing: RevericSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _MetaItem(
          icon: RevericIcons.rule_outlined,
          label: audit.resourcePath,
        ),
        if (audit.resourceType.isNotEmpty)
          _MetaItem(
            icon: RevericIcons.info,
            label: audit.resourceType,
          ),
      ],
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.icon, required this.label});

  final String icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RevericIcon(icon, size: 14, color: colors.textMuted),
        const SizedBox(width: RevericSpacing.xs),
        Flexible(
          child: Text(
            label,
            style: typo.mono.copyWith(color: colors.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 覆盖提示 + 默认建议（R-20 / R-21）
// ---------------------------------------------------------------------------

/// 覆盖提示：已检查 N 个对象，尚有 M 个未检查；M>0 时高亮「不能视为已通过」。
class _CoverageNotice extends StatelessWidget {
  const _CoverageNotice({required this.result});

  final ImpactAuditResult result;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final unchecked = result.uncheckedCount;
    final isPartial = result.hasUnchecked && result.totalRelevantCount > 0;
    final text = isPartial
        ? '已检查 ${result.checkedCount} 个对象，尚有 $unchecked 个未检查'
        : '已检查 ${result.checkedCount} 个对象，覆盖完整';
    final hintColor = isPartial ? colors.warningText : colors.success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            RevericIcon(
              isPartial
                  ? RevericIcons.visibility_off_outlined
                  : RevericIcons.shield_check,
              size: 14,
              color: hintColor,
            ),
            const SizedBox(width: RevericSpacing.xs),
            Expanded(
              child: Text(
                text,
                style: typo.uiSmallSemibold.copyWith(color: hintColor),
              ),
            ),
          ],
        ),
        if (isPartial) ...[
          const SizedBox(height: RevericSpacing.xxs),
          Text(
            '未扫描部分不能视为已通过，建议补扫后复核',
            style: typo.uiTiny.copyWith(color: colors.warningText),
          ),
        ],
      ],
    );
  }
}

/// 默认建议文案（按结果最高影响档位）。
class _SuggestedAction extends StatelessWidget {
  const _SuggestedAction({required this.result});

  final ImpactAuditResult result;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RevericIcon(RevericIcons.lightbulb_outline, size: 14, color: colors.textMuted),
        const SizedBox(width: RevericSpacing.xs),
        Expanded(
          child: Text(
            '建议：${result.recommendedAction}',
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 下游命中分组
// ---------------------------------------------------------------------------

class _HitsSection extends StatelessWidget {
  const _HitsSection({required this.result});

  final ImpactAuditResult result;

  @override
  Widget build(BuildContext context) {
    final sections = <(String, String, List<ImpactHit>)>[
      (
        LocaleKeys.workspaceImpactAuditAffectedChapters,
        RevericIcons.format_list_numbered,
        result.affectedChapters,
      ),
      (
        LocaleKeys.workspaceImpactAuditAffectedForeshadowings,
        RevericIcons.warning_amber_rounded,
        result.affectedForeshadowings,
      ),
      (
        LocaleKeys.workspaceImpactAuditAffectedRelations,
        RevericIcons.shield_check,
        result.affectedRelations,
      ),
      (
        LocaleKeys.workspaceImpactAuditAffectedCharacters,
        RevericIcons.person_outline,
        result.affectedCharacters,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (labelKey, icon, hits) in sections)
          if (hits.isNotEmpty) ...[
            _HitGroupHeader(labelKey: labelKey, icon: icon, count: hits.length),
            const SizedBox(height: RevericSpacing.sm),
            for (final hit in hits) ...[
              _HitRow(hit: hit),
              const SizedBox(height: RevericSpacing.sm),
            ],
            const SizedBox(height: RevericSpacing.lg),
          ],
      ],
    );
  }
}

class _HitGroupHeader extends StatelessWidget {
  const _HitGroupHeader({
    required this.labelKey,
    required this.icon,
    required this.count,
  });

  final String labelKey;
  final String icon;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      children: [
        RevericIcon(icon, size: 14, color: colors.textMuted),
        const SizedBox(width: RevericSpacing.xs),
        Text(
          context.t(labelKey),
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(width: RevericSpacing.sm),
        Text(
          '$count',
          style: typo.uiTiny.copyWith(color: colors.textSubtle),
        ),
      ],
    );
  }
}

/// 单条命中：标题 + 证据引用 + 出处 + 置信度。
class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit});

  final ImpactHit hit;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (hit.reviewPending) ...[
                RevericIcon(
                  RevericIcons.warning,
                  size: 14,
                  color: colors.warningText,
                ),
                const SizedBox(width: RevericSpacing.xs),
              ],
              Expanded(
                child: Text(
                  hit.title.isEmpty ? '—' : hit.title,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              _SeverityBadge(severity: hit.severity),
              const SizedBox(width: RevericSpacing.xs),
              _ConfidenceBadge(confidence: hit.confidence),
            ],
          ),
          if (hit.evidence.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.sm),
            Text(
              '“${hit.evidence}”',
              style: typo.bodySmall.copyWith(color: colors.textSecondary),
            ),
          ],
          if (hit.context.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.xs),
            Text(
              context.t(LocaleKeys.workspaceImpactAuditContext),
              style: typo.uiTiny.copyWith(color: colors.textSubtle),
            ),
            Text(
              hit.context,
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// 影响强度徽章：DIRECT/HIGH 橙红、MEDIUM 橙、LOW/UNKNOWN 灰。
class _SeverityBadge extends StatelessWidget {
  const _SeverityBadge({required this.severity});

  final String severity;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final color = switch (severity) {
      ImpactSeverity.direct || ImpactSeverity.high => colors.error,
      ImpactSeverity.medium => colors.warningText,
      _ => colors.textMuted,
    };
    final label = switch (severity) {
      ImpactSeverity.direct => '直接',
      ImpactSeverity.high => '高',
      ImpactSeverity.medium => '中',
      ImpactSeverity.low => '低',
      ImpactSeverity.none => '无',
      _ => '未知',
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.xs,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Text(
        label,
        style: typo.uiTinySemibold.copyWith(color: color),
      ),
    );
  }
}

/// 置信度徽章：1.0 高置信（绿）/ 0.6 弱匹配（橙）。
class _ConfidenceBadge extends StatelessWidget {
  const _ConfidenceBadge({required this.confidence});

  final double confidence;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final high = confidence >= 0.9;
    final color = high ? colors.success : colors.warningText;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.xs,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Text(
        '${(confidence * 100).round()}%',
        style: typo.uiTinySemibold.copyWith(color: color),
      ),
    );
  }
}

class _NoHitsNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      children: [
        RevericIcon(
          RevericIcons.check_circle,
          size: 14,
          color: colors.success,
        ),
        const SizedBox(width: RevericSpacing.sm),
        Text(
          context.t(LocaleKeys.workspaceImpactAuditNoHits),
          style: typo.uiSmall.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// resultJson 解析失败时的原文兜底展示。
class _RawResultFallback extends StatelessWidget {
  const _RawResultFallback({required this.raw});

  final String raw;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Text(
      raw,
      style: typo.mono.copyWith(color: colors.textMuted),
      maxLines: 6,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ---------------------------------------------------------------------------
// 状态视图
// ---------------------------------------------------------------------------

class _ImpactAuditLoadingState extends StatelessWidget {
  const _ImpactAuditLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

class _ImpactAuditErrorState extends StatelessWidget {
  const _ImpactAuditErrorState({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x4l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.error_outline,
              size: 32,
              color: colors.error,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImpactAuditEmptyState extends StatelessWidget {
  const _ImpactAuditEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: RevericSizes.placeholderMaxWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: RevericSpacing.x4l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RevericIcon(
                RevericIcons.checklist_rounded,
                size: 32,
                color: colors.textMuted,
              ),
              const SizedBox(height: RevericSpacing.lg),
              Text(
                context.t(LocaleKeys.workspaceImpactAuditEmpty),
                style: typo.uiSemibold.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.workspaceImpactAuditEmptyHint),
                textAlign: TextAlign.center,
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 解析辅助
// ---------------------------------------------------------------------------

ImpactAuditResult? _parseResult(String json) {
  try {
    if (json.trim().isEmpty) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    return ImpactAuditResult.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    return null;
  }
}

String _formatTime(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
