// 职责: 远程助手最小授权管理 UI — 已授权列表 / 新增授权(chatId+userId+scope) /
//       撤销 / 最近授权与拒绝事件 / 安全状态指示（P0-A.1 任务 3）。
// 安全约定:
//   - 授权仅从本卡（本地可信设置界面）发起，grantedBy=local_settings_ui；
//   - 群聊/身份未验证的会话默认禁止会话级授权（userId 留空会抛错并提示），
//     不提供「绕过 allowSessionWide」的开关，保证群聊不会默认共享会话级授权；
//   - 只展示授权服务 auditEvents（内存缓冲），不误解读消息正文。
// 关联文件:
//   lib/shared/services/remote/remote_authorization_service.dart
//   lib/shared/providers/remote_bridge_providers.dart
//   lib/shared/widgets/settings/remote_bridge_settings_section.dart
//   lib/shared/localization/locale_keys.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_button.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/remote_bridge_providers.dart';
import '../../services/remote/remote_authorization_service.dart';
import '../../services/remote/wechat_adapter.dart' show wechatChannelType;
import '../../theme/theme.dart';
import 'settings_section_widgets.dart';

/// 远程授权管理卡 — 独立组件，由 [RemoteBridgeSettingsSection] 在 connected 卡
/// 下方嵌入。StatefulWidget 保存「已授权列表 + 最近事件」加载态与错误态。
class RemoteAuthorizationSettingsCard extends HookConsumerWidget {
  const RemoteAuthorizationSettingsCard({super.key});

  /// 仅当授权记录表非空时渲染。
  static Future<bool> hasAuthorizations(WidgetRef ref) async {
    final auth = ref.read(remoteAuthorizationServiceProvider);
    final records = await auth.listAuthorizations();
    return records.isNotEmpty;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final auth = ref.watch(remoteAuthorizationServiceProvider);

    // 本地刷新计数：审计流事件 / 手动刷新 +1 重新拉取列表与事件。
    final revision = useState(0);
    // 事件类型筛选（P0-B B4）：all / grant / revoke / deny / allow。
    final eventFilter = useState<_EventFilter>(_EventFilter.all);
    // 事件分页：每页 [pageSize] 条，limit+1 探测是否还有更多。
    final eventPage = useState(1);
    const pageSize = 8;

    // 实时更新：订阅审计广播流，任一事件（授权/撤销/远程判定）触发刷新，
    // 无需轮询或手动点击（P0-B B4）。服务为长生命周期单例，订阅一次常驻。
    useEffect(() {
      final sub = auth.auditStream.listen((_) {
        revision.value += 1;
      });
      return sub.cancel;
    }, [auth]);

    // 授权列表（含存储错误区分：确无授权 vs 存储读取失败）。
    final recordsFuture = useMemoized(
      () => auth.listAuthorizationsDetailed(),
      [auth, revision.value],
    );
    final recordsSnapshot = useFuture(recordsFuture).data;
    final records =
        recordsSnapshot?.records ?? const <RemoteAuthorizationRecord>[];
    final storeError = recordsSnapshot?.error;

    // 事件列表：DB 查询（remote_authorization_audit 表）+ 类型筛选 + 分页。
    final eventTypes = eventFilter.value.eventTypes;
    final eventLimit = pageSize * eventPage.value + 1; // +1 探测还有更多
    final eventsFuture = useMemoized(
      () => auth.queryAuditEvents(eventTypes: eventTypes, limit: eventLimit),
      [auth, revision.value, eventTypes, eventLimit],
    );
    final fetchedEvents =
        useFuture(eventsFuture).data ?? const <RemoteAuthorizationAuditEvent>[];
    final hasMore = fetchedEvents.length > pageSize * eventPage.value;
    final visibleEvents = fetchedEvents
        .take(pageSize * eventPage.value)
        .toList(growable: false);

    // 最后执行权限判定：最近一条 allow/deny 判定事件。
    RemoteAuthorizationAuditEvent? lastDecision;
    for (final event in visibleEvents) {
      if (_isDecisionEvent(event.event)) {
        lastDecision = event;
        break;
      }
    }

    Future<void> refresh() async {
      revision.value += 1;
    }

    return Container(
      margin: const EdgeInsets.only(top: RevericSpacing.x2l),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(colors: colors, typo: typo, onRefresh: refresh),
          const SettingsRowDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x2l,
              RevericSpacing.lg,
              RevericSpacing.x2l,
              RevericSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SecurityStatusChip(
                  colors: colors,
                  typo: typo,
                  enabled: records.any((r) => r.isActive),
                ),
                const SizedBox(height: RevericSpacing.md),
                // 存储读取失败提示：不得用「暂无授权」空态误导（存储故障≠无授权）。
                if (storeError != null) ...[
                  _StoreErrorBanner(
                    colors: colors,
                    typo: typo,
                    message: context.t(
                      LocaleKeys.remoteAuthStoreError,
                      namedArgs: {'error': storeError},
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.md),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.t(LocaleKeys.remoteAuthRecordsTitle),
                        style: typo.uiSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    RevericButton.secondary(
                      size: RevericButtonSize.compact,
                      icon: RevericIcons.add,
                      label: context.t(LocaleKeys.remoteAuthGrant),
                      onPressed: () async {
                        await _showGrantDialog(context, ref, auth);
                        await refresh();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: RevericSpacing.sm),
                if (records.isEmpty && storeError == null)
                  _EmptyHint(
                    colors: colors,
                    typo: typo,
                    text: context.t(LocaleKeys.remoteAuthEmpty),
                  )
                else if (records.isEmpty)
                  // 存储错误已由上方横幅提示，不重复展示误导性空态。
                  const SizedBox.shrink()
                else
                  ...records.map(
                    (record) => _AuthorizationRow(
                      colors: colors,
                      typo: typo,
                      record: record,
                      onRevoke: () async {
                        final confirmed = await _confirmRevoke(context, ref);
                        if (!confirmed) {
                          return;
                        }
                        await auth.revokeRemoteUser(
                          channelType: record.channelType,
                          chatId: record.chatId,
                          userId: record.userId,
                          revokedBy: 'local_settings_ui',
                        );
                        await refresh();
                      },
                    ),
                  ),
                const SizedBox(height: RevericSpacing.lg),
                // 最后执行权限判定（P0-B B4）。
                Text(
                  context.t(LocaleKeys.remoteAuthLastDecision),
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: RevericSpacing.xs),
                if (lastDecision == null)
                  _EmptyHint(
                    colors: colors,
                    typo: typo,
                    text: context.t(LocaleKeys.remoteAuthLastDecisionEmpty),
                  )
                else
                  _LastDecisionBanner(
                    colors: colors,
                    typo: typo,
                    event: lastDecision,
                  ),
                const SizedBox(height: RevericSpacing.lg),
                // 事件筛选 + 列表（P0-B B4）。
                Text(
                  context.t(LocaleKeys.remoteAuthEvents),
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: RevericSpacing.sm),
                _EventFilterChips(
                  colors: colors,
                  typo: typo,
                  selected: eventFilter.value,
                  onChanged: (filter) {
                    eventFilter.value = filter;
                    eventPage.value = 1; // 切换筛选回第一页。
                  },
                ),
                const SizedBox(height: RevericSpacing.sm),
                if (visibleEvents.isEmpty)
                  _EmptyHint(
                    colors: colors,
                    typo: typo,
                    text: context.t(LocaleKeys.remoteAuthEventsEmpty),
                  )
                else
                  ...visibleEvents.map(
                    (event) =>
                        _EventRow(colors: colors, typo: typo, event: event),
                  ),
                if (hasMore)
                  Center(
                    child: RevericButton.text(
                      size: RevericButtonSize.compact,
                      label: context.t(LocaleKeys.remoteAuthEventsLoadMore),
                      onPressed: () => eventPage.value += 1,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 打开「新增授权」对话框；返回 true 表示已提交（调用方刷新列表）。
  Future<void> _showGrantDialog(
    BuildContext context,
    WidgetRef ref,
    RemoteAuthorizationService auth,
  ) async {
    final theme = RevericTheme.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return RevericTheme(
          data: theme,
          child: _GrantDialog(auth: auth, onDone: () {}),
        );
      },
    );
  }

  /// 撤销前二次确认（本地可信操作，避免误触）。
  Future<bool> _confirmRevoke(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = RevericTheme.colorsOf(dialogContext);
        final typo = RevericTheme.typographyOf(dialogContext);
        return RevericTheme(
          data: RevericTheme.of(context),
          child: AlertDialog(
            backgroundColor: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(RevericRadius.x2l),
            ),
            title: Text(
              dialogContext.t(LocaleKeys.remoteAuthRevoke),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            content: Text(
              dialogContext.t(LocaleKeys.remoteAuthRevokeConfirm),
              style: typo.ui.copyWith(color: colors.textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(dialogContext.t(LocaleKeys.remoteLoginCancel)),
              ),
              RevericButton.danger(
                size: RevericButtonSize.compact,
                label: dialogContext.t(LocaleKeys.remoteAuthRevoke),
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
          ),
        );
      },
    );
    return result ?? false;
  }
}

// ─────────────────────────── 头部 ───────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.colors,
    required this.typo,
    required this.onRefresh,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x2l,
        RevericSpacing.lg,
        RevericSpacing.md,
        RevericSpacing.lg,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(RevericRadius.large),
            ),
            child: RevericIcon(
              RevericIcons.rule_outlined,
              size: 18,
              color: colors.accent,
            ),
          ),
          const SizedBox(width: RevericSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t(LocaleKeys.remoteAuthSectionTitle),
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.t(LocaleKeys.remoteAuthSectionDescription),
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRefresh,
            icon: RevericIcon(
              RevericIcons.arrow_clockwise,
              size: 16,
              color: colors.textMuted,
            ),
            iconSize: RevericSizes.iconButtonSize,
            constraints: const BoxConstraints(
              minWidth: RevericSizes.iconButtonSize,
              minHeight: RevericSizes.iconButtonSize,
            ),
            padding: EdgeInsets.zero,
            splashRadius: RevericSizes.iconButtonSize / 2,
          ),
        ],
      ),
    );
  }
}

// ─────────────────── 安全状态指示 ───────────────────────

class _SecurityStatusChip extends StatelessWidget {
  const _SecurityStatusChip({
    required this.colors,
    required this.typo,
    required this.enabled,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = enabled
        ? (
            RevericIcons.check_circle,
            colors.success,
            context.t(LocaleKeys.remoteAuthSecurityOn),
          )
        : (
            RevericIcons.error_outline,
            colors.textMuted,
            context.t(LocaleKeys.remoteAuthSecurityOff),
          );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(icon, size: 14, color: color),
          const SizedBox(width: RevericSpacing.xs),
          Flexible(
            child: Text(label, style: typo.uiTiny.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────── 空态提示 ───────────────────────

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    required this.colors,
    required this.typo,
    required this.text,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
      child: Text(text, style: typo.uiSmall.copyWith(color: colors.textMuted)),
    );
  }
}

// ─────────────────── 单条授权记录 ───────────────────────

class _AuthorizationRow extends StatelessWidget {
  const _AuthorizationRow({
    required this.colors,
    required this.typo,
    required this.record,
    required this.onRevoke,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final RemoteAuthorizationRecord record;
  final VoidCallback onRevoke;

  String _scopeLabel(BuildContext context, RemotePermissionScope scope) {
    switch (scope) {
      case RemotePermissionScope.read:
        return context.t(LocaleKeys.remoteAuthScopeRead);
      case RemotePermissionScope.write:
        return context.t(LocaleKeys.remoteAuthScopeWrite);
      case RemotePermissionScope.all:
        return context.t(LocaleKeys.remoteAuthScopeAll);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = record.isActive;
    final idLabel = [
      record.channelType,
      record.chatId,
      if (record.userId != null) record.userId!,
    ].join(' / ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: active ? colors.success : colors.textMuted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  idLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmall.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 1),
                Text(
                  [
                    _scopeLabel(context, record.scope),
                    active
                        ? context.t(LocaleKeys.remoteAuthActive)
                        : context.t(LocaleKeys.remoteAuthRevoked),
                  ].join(' · '),
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          if (active)
            RevericButton.text(
              size: RevericButtonSize.compact,
              label: context.t(LocaleKeys.remoteAuthRevoke),
              onPressed: onRevoke,
            ),
        ],
      ),
    );
  }
}

// ─────────────────── 事件行 ───────────────────────

/// 事件类型筛选（P0-B B4）。
///
/// 每种筛选映射到审计事件类型集合（服务/存储层下沉过滤），保证历史事件
/// 按类型筛选不失真（最新一页全为放行时，仍能筛出深层拒绝记录）。
enum _EventFilter {
  all(null),
  grant({'grant'}),
  revoke({'revoke'}),
  deny({'deny_message', 'deny_tool', 'deny_runtime'}),
  allow({'allow_message', 'allow_tool'});

  const _EventFilter(this.eventTypes);

  /// 命中该筛选的事件类型；null = 不过滤（全部）。
  final Set<String>? eventTypes;
}

/// 是否为「执行权限判定」事件（allow/deny 类；grant/revoke 是管理操作非判定）。
bool _isDecisionEvent(String event) =>
    event == 'allow_message' ||
    event == 'allow_tool' ||
    event == 'deny_message' ||
    event == 'deny_tool' ||
    event == 'deny_runtime';

/// 紧凑时间：MM-dd HH:mm（locale 无关，审计时间戳展示）。
String _formatAuditTime(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.colors,
    required this.typo,
    required this.event,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final RemoteAuthorizationAuditEvent event;

  String _label(BuildContext context) {
    switch (event.event) {
      case 'grant':
        return context.t(LocaleKeys.remoteAuthEventGrant);
      case 'revoke':
        return context.t(LocaleKeys.remoteAuthEventRevoke);
      case 'deny_message':
        return context.t(LocaleKeys.remoteAuthEventDenyMessage);
      case 'deny_tool':
        return context.t(LocaleKeys.remoteAuthEventDenyTool);
      case 'deny_runtime':
        return context.t(LocaleKeys.remoteAuthEventDenyTool);
      case 'allow_message':
        return context.t(LocaleKeys.remoteAuthEventAllowMessage);
      case 'allow_tool':
        return context.t(LocaleKeys.remoteAuthEventAllowTool);
      default:
        return event.event;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDenial = event.event.startsWith('deny_');
    final color = isDenial ? colors.error : colors.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: RevericIcon(
              isDenial ? RevericIcons.error_outline : RevericIcons.check,
              size: 12,
              color: color,
            ),
          ),
          const SizedBox(width: RevericSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(context),
                  style: typo.uiTiny.copyWith(color: color),
                ),
                if (event.detail != null && event.detail!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    event.detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                [event.channelType, event.chatId].join(':'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
              Text(
                _formatAuditTime(event.at),
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────── 事件筛选 chips ───────────────────────

class _EventFilterChips extends StatelessWidget {
  const _EventFilterChips({
    required this.colors,
    required this.typo,
    required this.selected,
    required this.onChanged,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final _EventFilter selected;
  final ValueChanged<_EventFilter> onChanged;

  String _label(BuildContext context, _EventFilter filter) {
    switch (filter) {
      case _EventFilter.all:
        return context.t(LocaleKeys.remoteAuthEventsFilterAll);
      case _EventFilter.grant:
        return context.t(LocaleKeys.remoteAuthEventsFilterGrant);
      case _EventFilter.revoke:
        return context.t(LocaleKeys.remoteAuthEventsFilterRevoke);
      case _EventFilter.deny:
        return context.t(LocaleKeys.remoteAuthEventsFilterDeny);
      case _EventFilter.allow:
        return context.t(LocaleKeys.remoteAuthEventsFilterAllow);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: RevericSpacing.xs,
      runSpacing: RevericSpacing.xs,
      children: [
        for (final filter in _EventFilter.values)
          InkWell(
            onTap: () => onChanged(filter),
            borderRadius: BorderRadius.circular(RevericRadius.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
                vertical: RevericSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: filter == selected
                    ? colors.accent.withValues(alpha: 0.12)
                    : colors.surfaceContainer,
                borderRadius: BorderRadius.circular(RevericRadius.pill),
                border: Border.all(
                  color: filter == selected
                      ? colors.accent
                      : colors.borderSubtle,
                  width: filter == selected ? 1.5 : 1,
                ),
              ),
              child: Text(
                _label(context, filter),
                style: typo.uiTiny.copyWith(
                  color: filter == selected
                      ? colors.accent
                      : colors.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────── 存储错误提示 ───────────────────────

/// 授权记录存储读取失败横幅（P0-B B4）。
///
/// 存储故障 ≠ 无授权：展示错误，而非误导性的「暂无授权」空态。授权判定仍
/// fail-closed（服务侧按空表拒绝），本横幅仅提示管理侧可见性。
class _StoreErrorBanner extends StatelessWidget {
  const _StoreErrorBanner({
    required this.colors,
    required this.typo,
    required this.message,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          RevericIcon(
            RevericIcons.warning_amber_rounded,
            size: 14,
            color: colors.error,
          ),
          const SizedBox(width: RevericSpacing.xs),
          Expanded(
            child: Text(
              message,
              style: typo.uiTiny.copyWith(color: colors.error),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────── 最后执行权限判定 ───────────────────────

/// 最后一条执行权限判定（allow/deny）展示（P0-B B4）。
class _LastDecisionBanner extends StatelessWidget {
  const _LastDecisionBanner({
    required this.colors,
    required this.typo,
    required this.event,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final RemoteAuthorizationAuditEvent event;

  String _label(BuildContext context) {
    switch (event.event) {
      case 'allow_message':
        return context.t(LocaleKeys.remoteAuthEventAllowMessage);
      case 'allow_tool':
        return context.t(LocaleKeys.remoteAuthEventAllowTool);
      case 'deny_message':
        return context.t(LocaleKeys.remoteAuthEventDenyMessage);
      case 'deny_tool':
        return context.t(LocaleKeys.remoteAuthEventDenyTool);
      case 'deny_runtime':
        return context.t(LocaleKeys.remoteAuthEventDenyTool);
      default:
        return event.event;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDenial = event.event.startsWith('deny_');
    final color = isDenial ? colors.error : colors.success;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          RevericIcon(
            isDenial ? RevericIcons.error_outline : RevericIcons.check_circle,
            size: 14,
            color: color,
          ),
          const SizedBox(width: RevericSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(context),
                  style: typo.uiTiny.copyWith(color: color),
                ),
                if (event.detail != null && event.detail!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    event.detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          Text(
            _formatAuditTime(event.at),
            style: typo.uiTiny.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

// ─────────────────── 新增授权对话框 ───────────────────────

/// 新增授权对话框：chatId（必填）+ userId（可选）+ scope（read/write/all）。
///
/// userId 留空 = 会话级授权。授权服务抛 ArgumentError（群聊默认禁止会话级授权）
/// 时在对话框内展示错误，不绕过 allowSessionWide —— 群聊用户必须填写 userId。
class _GrantDialog extends StatefulWidget {
  const _GrantDialog({required this.auth, required this.onDone});

  final RemoteAuthorizationService auth;
  final VoidCallback onDone;

  @override
  State<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends State<_GrantDialog> {
  final _chatController = TextEditingController();
  final _userController = TextEditingController();
  RemotePermissionScope _scope = RemotePermissionScope.write;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _chatController.dispose();
    _userController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final chatId = _chatController.text.trim();
    if (chatId.isEmpty) {
      setState(() => _error = context.t(LocaleKeys.remoteAuthErrorEmptyChat));
      return;
    }
    final userId = _userController.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.authorizeRemoteUser(
        channelType: wechatChannelType,
        chatId: chatId,
        userId: userId.isEmpty ? null : userId,
        scope: _scope,
        displayName: userId.isEmpty ? null : userId,
        grantedBy: 'local_settings_ui',
        // 群聊默认禁止会话级授权：此处不提供 allowSessionWide 放行开关。
      );
      if (mounted) {
        widget.onDone();
        Navigator.of(context).pop(true);
      }
    } on ArgumentError {
      // 会话级授权被拒（群聊/身份未验证）→ 提示填写 userId，不绕过。
      if (mounted) {
        setState(() {
          _error = context.t(LocaleKeys.remoteAuthErrorSessionWide);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(RevericSpacing.x3l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.t(LocaleKeys.remoteAuthGrantTitle),
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.md),
              TextField(
                controller: _chatController,
                decoration: InputDecoration(
                  labelText: context.t(LocaleKeys.remoteAuthChatId),
                  hintText: 'wxid_xxx',
                ),
              ),
              const SizedBox(height: RevericSpacing.md),
              TextField(
                controller: _userController,
                decoration: InputDecoration(
                  labelText: context.t(LocaleKeys.remoteAuthUserId),
                  hintText: context.t(LocaleKeys.remoteAuthUserIdHint),
                ),
              ),
              const SizedBox(height: RevericSpacing.md),
              Text(
                context.t(LocaleKeys.remoteAuthScope),
                style: typo.uiSmallSemibold.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: RevericSpacing.sm),
              Row(
                children: [
                  for (final scope in RemotePermissionScope.values) ...[
                    _ScopeChip(
                      colors: colors,
                      typo: typo,
                      label: switch (scope) {
                        RemotePermissionScope.read => context.t(
                          LocaleKeys.remoteAuthScopeRead,
                        ),
                        RemotePermissionScope.write => context.t(
                          LocaleKeys.remoteAuthScopeWrite,
                        ),
                        RemotePermissionScope.all => context.t(
                          LocaleKeys.remoteAuthScopeAll,
                        ),
                      },
                      selected: _scope == scope,
                      onTap: () => setState(() => _scope = scope),
                    ),
                    if (scope != RemotePermissionScope.values.last)
                      const SizedBox(width: RevericSpacing.xs),
                  ],
                ],
              ),
              const SizedBox(height: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.remoteAuthSessionWideHint),
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
              if (_error != null) ...[
                const SizedBox(height: RevericSpacing.md),
                Text(_error!, style: typo.uiTiny.copyWith(color: colors.error)),
              ],
              const SizedBox(height: RevericSpacing.x2l),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    child: Text(context.t(LocaleKeys.remoteLoginCancel)),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  RevericButton.primary(
                    size: RevericButtonSize.compact,
                    label: context.t(LocaleKeys.remoteAuthConfirm),
                    onPressed: _busy ? null : _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.colors,
    required this.typo,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.12)
              : colors.surfaceContainer,
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          border: Border.all(
            color: selected ? colors.accent : colors.borderSubtle,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: typo.uiSmall.copyWith(
            color: selected ? colors.accent : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}
