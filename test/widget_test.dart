// 职责: 应用启动 smoke test — 验证 root widget 与应用级生命周期处理。
// 关联文件:
//   lib/main.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:drift/native.dart';

import 'package:reveric/main.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/providers/anonymous_reporting_providers.dart';
import 'package:reveric/shared/providers/mcp_providers.dart';
import 'package:reveric/shared/providers/plugin_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/anonymous_outbox_service.dart';
import 'package:reveric/shared/services/mcp/settings_service.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart' as plugin_registry;
import 'package:shared_preferences/shared_preferences.dart';

// 测试用 MCP 配置服务 stub：initState 只等 initialized / 调 close，
// 真实服务在 FakeAsync zone 的关闭链会挂死，这里给已完成的 future 与 no-op。
class _FakeMcpSettings extends McpSettingsService {
  // initState 只消费 initialized / close；用内存库构造以避开生产关闭链，
  // base 的 _initialize() 仅读取内存库设置，无网络与平台通道副作用。
  _FakeMcpSettings(super.database, {super.supportsStdio = false});

  @override
  Future<void> get initialized => Future<void>.value();

  @override
  Future<void> close() => Future<void>.value();
}

// 测试用插件宿主 stub：绕开 start() 里的 AssetManifest / supportDirectory
// 平台通道，避免在 FakeAsync zone 留下永不完成的 pending Timer。
class _FakePluginHost extends PluginHostService {
  _FakePluginHost(AppDatabase database)
      : super(
          dao: database.pluginDao,
          registry:
              plugin_registry.PluginRegistry(hostToolNames: const <String>{}),
        );

  @override
  Future<void> start() => Future<void>.value();

  @override
  Future<void> setForeground(bool foreground) => Future<void>.value();

  @override
  Future<void> dispose() => Future<void>.value();
}

void main() {
  testWidgets('MyApp is a ConsumerWidget', (WidgetTester tester) async {
    // 不渲染完整 widget 树（依赖 database / EasyLocalization），
    // 只验证 MyApp 是可实例化的 ConsumerWidget。
    const app = MyApp();
    expect(app, isA<ConsumerWidget>());
  });

  testWidgets('lifecycle changes leave HardwareKeyboard state to Flutter', (
    WidgetTester tester,
  ) async {
    // AppLifecycleWatcher.initState 会等 anonymousReportingConsentProvider
    // （走真实 SharedPreferences 平台通道）。不 mock 的话该 future 在 FakeAsync
    // zone 永不完成，测试结束时遗留 pending Timer。
    SharedPreferences.setMockInitialValues({});
    final usageHttpClient = http.Client();
    final database = AppDatabase.forTest(NativeDatabase.memory());
    final outbox = AnonymousOutboxService(
      database: database,
      httpClient: usageHttpClient,
      getBaseUrl: () => null,
      getEnabled: () => false,
    );
    addTearDown(usageHttpClient.close);
    addTearDown(database.close);
    // AppLifecycleWatcher.initState 会 read mcpSettingsServiceProvider，
    // 其底层依赖 appSettingsDatabaseProvider。不 override 的话走真实
    // AppDatabase 懒连接（drift Timer），在 FakeAsync zone 永不落定。
    // 插件宿主 start() 走 AssetManifest / supportDirectory 平台通道，
    // 同样留 pending Timer，故一并 stub。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          mcpSettingsServiceProvider
              .overrideWith((ref) => _FakeMcpSettings(database)),
          pluginHostServiceProvider
              .overrideWith((ref) => _FakePluginHost(database)),
          anonymousOutboxServiceProvider.overrideWithValue(outbox),
        ],
        child: const AppLifecycleWatcher(),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.metaLeft,
      platform: 'macos',
    );
    expect(HardwareKeyboard.instance.isMetaPressed, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(HardwareKeyboard.instance.isMetaPressed, isTrue);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
    expect(HardwareKeyboard.instance.isMetaPressed, isFalse);
  });
}
