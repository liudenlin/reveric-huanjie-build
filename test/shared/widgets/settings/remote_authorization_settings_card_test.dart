// P0-B B4: 授权管理 UI —— RemoteAuthorizationSettingsCard 挂载验证。
// 覆盖：空态、有授权记录、存储错误横幅、事件渲染与类型筛选、
//       实时更新（审计流触发列表刷新）。
// 运行（隔离副本 cwd，需临时禁用 super_native_extensions hook + 清代理）:
//   fvm flutter test b4_ui_widget_test.dart
// P0-B.3 任务4：EasyLocalization.ensureInitialized() 在测试环境会触发
// shared_preferences 插件通道调用，未 mock 时抛 MissingPluginException
// （No implementation found for method getAll on channel
//  plugins.flutter.io/shared_preferences）——用 shared_preferences 官方测试
//  API SharedPreferences.setMockInitialValues({}) 建立内存 mock，使 widget
//  测试可真实运行（不得删除测试或把 continue-on-error 当作通过）。
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/providers/remote_bridge_providers.dart';
import 'package:reveric/shared/services/remote/remote_authorization_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/remote_authorization_settings_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P0-B.3 任务4：widget 测试环境的 rootBundle 不保证提供 pubspec 声明的
/// 翻译资产（assets/translations/*.json），MergingAssetLoader 会静默 catch
/// 并返回空 map → tr() 返回 key → 文本找不到（5 个用例全失败）。改用
/// **磁盘直读**（File IO，测试工作区始终存在，不依赖 rootBundle 资产打包）
/// 预加载全部翻译 namespace，语义与生产 MergingAssetLoader 一致（合并）。
class _DiskTranslationsLoader extends AssetLoader {
  const _DiskTranslationsLoader();

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final localeDir = '$path/${locale.toStringWithSeparator(separator: "-")}';
    final merged = <String, dynamic>{};
    final dir = Directory(localeDir);
    if (!dir.existsSync()) {
      return merged;
    }
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        final map =
            jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
        merged.addAll(map);
      } catch (_) {
        // 跳过无法解析的 namespace（与生产加载器一致）。
      }
    }
    return merged;
  }
}

/// 测试用授权存储（可注入读取失败）。
class _MemoryStore extends RemoteAuthorizationStore {
  String? _value;
  bool failRead = false;

  @override
  Future<String?> read(String key) async {
    if (failRead) {
      throw StateError('forced store read failure');
    }
    return _value;
  }

  @override
  Future<void> write(String key, String value) async {
    _value = value;
  }
}

/// 测试用审计存储。
class _MemoryAuditStore implements RemoteAuthorizationAuditStore {
  final List<RemoteAuthorizationAuditEvent> events = [];

  @override
  Future<void> append(RemoteAuthorizationAuditEvent event) async {
    events.add(event);
  }

  @override
  Future<List<RemoteAuthorizationAuditEvent>> query({
    DateTime? since,
    DateTime? until,
    String? channelType,
    String? chatId,
    String? userId,
    String? jobId,
    Set<String>? eventTypes,
    int limit = 200,
  }) async {
    return [
      for (final e in events.reversed)
        if ((eventTypes == null ||
                eventTypes.isEmpty ||
                eventTypes.contains(e.event)) &&
            (channelType == null || e.channelType == channelType) &&
            (chatId == null || e.chatId == chatId))
          e,
    ].take(limit).toList();
  }

  @override
  Future<int> cleanupBefore(DateTime cutoff) async {
    final before = events.length;
    events.removeWhere((e) => e.at.isBefore(cutoff));
    return before - events.length;
  }
}

Widget _wrap(Widget child, RemoteAuthorizationService service) {
  return ProviderScope(
    overrides: [
      remoteAuthorizationServiceProvider.overrideWithValue(service),
    ],
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      startLocale: const Locale('en'),
      fallbackLocale: const Locale('en'),
      saveLocale: false,
      path: 'assets/translations',
      // P0-B.3 任务4：测试环境用磁盘直读加载器（rootBundle 不保证提供资产）。
      assetLoader: const _DiskTranslationsLoader(),
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(body: child),
          ),
        ),
      ),
    ),
  );
}

void main() {
  const channel = 'wechat';
  const chatA = 'wxid_alice';

  setUpAll(() async {
    // P0-B.3 任务4：shared_preferences 内存 mock —— EasyLocalization 初始化
    // 会读 SharedPreferences（保存语言/路径），未 mock 抛 MissingPluginException。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('空态：无授权记录无事件 → 显示空提示与「暂无判定」', (tester) async {
    final service = RemoteAuthorizationService(
      _MemoryStore(),
      auditStore: _MemoryAuditStore(),
    );
    await tester.pumpWidget(_wrap(const RemoteAuthorizationSettingsCard(), service));
    await tester.pumpAndSettle();
    expect(find.text('Remote Authorization'), findsOneWidget);
    expect(find.textContaining('No authorizations yet'), findsOneWidget);
    expect(find.text('No decision recorded yet.'), findsOneWidget);
    expect(find.text('No events yet.'), findsOneWidget);
  });

  testWidgets('有授权记录 → 展示记录与生效状态', (tester) async {
    final store = _MemoryStore();
    final service = RemoteAuthorizationService(store, auditStore: _MemoryAuditStore());
    await service.authorizeRemoteUser(
      channelType: channel,
      chatId: chatA,
      userId: 'wxid_user',
      scope: RemotePermissionScope.write,
      grantedBy: 'test',
    );
    await tester.pumpWidget(_wrap(const RemoteAuthorizationSettingsCard(), service));
    await tester.pumpAndSettle();
    // 记录标识与 scope/状态。
    expect(find.textContaining('wxid_alice'), findsWidgets);
    expect(find.textContaining('Write'), findsWidgets);
    expect(find.textContaining('Active'), findsWidgets);
  });

  testWidgets('存储读取失败 → 显示存储错误横幅（不误用空态）', (tester) async {
    final store = _MemoryStore()..failRead = true;
    final service = RemoteAuthorizationService(store, auditStore: _MemoryAuditStore());
    await tester.pumpWidget(_wrap(const RemoteAuthorizationSettingsCard(), service));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed to read authorizations'), findsOneWidget);
    // 不应显示「暂无授权」误导空态。
    expect(find.textContaining('No authorizations yet'), findsNothing);
  });

  testWidgets('事件渲染与类型筛选：拒绝筛选仅显示拒绝事件', (tester) async {
    final audit = _MemoryAuditStore();
    final service = RemoteAuthorizationService(_MemoryStore(), auditStore: audit);
    await audit.append(RemoteAuthorizationAuditEvent(
      event: 'grant',
      channelType: channel,
      chatId: chatA,
      userId: 'wxid_user',
      detail: 'scope=write by=test',
      at: DateTime.now(),
    ));
    await audit.append(RemoteAuthorizationAuditEvent(
      event: 'deny_message',
      channelType: channel,
      chatId: chatA,
      userId: 'wxid_user',
      detail: 'no valid authorization record',
      at: DateTime.now(),
    ));
    await tester.pumpWidget(_wrap(const RemoteAuthorizationSettingsCard(), service));
    await tester.pumpAndSettle();
    expect(find.text('grant'), findsWidgets);
    // 事件 label 会同时出现在「最近判定横幅」（_LastDecisionBanner，若 deny_*
    // 为判定事件）与事件列表（_EventRow）两处 → findsWidgets（≥1），而非
    // findsOneWidget（P0-B B4 UI 设计如此；翻译未加载时从未暴露此不一致）。
    expect(find.text('message rejected'), findsWidgets);
    // 点击「Deny」筛选 chip。
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();
    expect(find.text('message rejected'), findsWidgets);
    expect(find.text('grant'), findsNothing);
  });

  testWidgets('实时更新：授权后列表自动刷新（审计流驱动）', (tester) async {
    final service = RemoteAuthorizationService(
      _MemoryStore(),
      auditStore: _MemoryAuditStore(),
    );
    await tester.pumpWidget(_wrap(const RemoteAuthorizationSettingsCard(), service));
    await tester.pumpAndSettle();
    expect(find.textContaining('No authorizations yet'), findsOneWidget);

    // 触发授权 → 审计流事件 → revision++ → 列表自动刷新。
    await service.authorizeRemoteUser(
      channelType: channel,
      chatId: chatA,
      userId: 'wxid_user',
      scope: RemotePermissionScope.all,
      grantedBy: 'test',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('wxid_alice'), findsWidgets);
    expect(find.textContaining('All'), findsWidgets);
  });
}
