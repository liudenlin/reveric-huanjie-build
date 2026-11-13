// 职责: 验证阅读设置可切换字体，且设置页只展示宿主平台的翻页设置。
// 关联文件:
//   lib/shared/widgets/reading/reading_settings_controls.dart
//   lib/shared/widgets/reading/reading_font_family_picker.dart
//   lib/shared/widgets/settings/reading_settings_section.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/components/reveric_select.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/database/app_database.dart' show AppDatabase;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/system_font_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/reading/reading_settings_controls.dart';
import 'package:reveric/shared/widgets/settings/reading_settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

// testWidgets 的 FakeAsync zone 不会推进真实 DB I/O，AppSettingsNotifier.build
// 里的凭证迁移与全量读取永不完成，会让设置写入挂在未完成的 future 上。
// 这里注入即时 notifier：build 同步返回默认设置，字体写入只改内存状态，
// 与项目其它设置页用例保持同一套注入写法。
class _TestSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
        theme: AppTheme.reveric,
        themeMode: AppThemeMode.light,
        language: 'en',
        aiSettings: AiSettings(providers: []),
      );

  @override
  Future<void> setReadingFontFamily(String fontFamily) async {
    state = AsyncData(state.requireValue.copyWith(readingFontFamily: fontFamily));
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(rootBundle.clear);

  // 独立 container 便于在 pumpWidget 前用 runAsync 预热设置状态，
  // 避开 EasyLocalization 首帧未挂载导致取不到 Scope 的问题。
  ProviderContainer buildContainer(AppDatabase appDb) => ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(appDb),
          appSettingsDatabaseProvider.overrideWithValue(appDb),
          appSettingsProvider.overrideWith(_TestSettings.new),
          systemFontFamiliesProvider.overrideWith(
            (ref) async => const ['Songti SC'],
          ),
        ],
      );

  testWidgets('reading settings dialog switches the reading font', (
    tester,
  ) async {
    final appDb = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(appDb.close);
    final container = buildContainer(appDb);
    addTearDown(container.dispose);
    await tester.runAsync(() => container.read(appSettingsProvider.future));
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(
      tester,
      container,
      const SingleChildScrollView(
        child: ReadingSettingsControls(
          compact: false,
          platform: ReadingSettingsPlatform.desktop,
        ),
      ),
    );

    final select = find.byType(RevericSelect<String>);
    expect(select, findsOneWidget);
    await tester.tap(select);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Songti SC').last);
    await tester.pumpAndSettle();

    expect(container.read(readingFontFamilyProvider), 'Songti SC');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('settings page shows only the host platform page turning', (
    tester,
  ) async {
    final appDb = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(appDb.close);
    final container = buildContainer(appDb);
    addTearDown(container.dispose);
    await tester.runAsync(() => container.read(appSettingsProvider.future));
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final platform in ReadingSettingsPlatform.values) {
      await _pump(tester, container, ReadingSettingsSection(platform: platform));

      final desktop = platform == ReadingSettingsPlatform.desktop;
      expect(find.text(tr(LocaleKeys.settingsReadingPageTurn)), findsOneWidget);
      // 说明只挂在首个 section，后续 section 不重复。
      expect(
        find.text(tr(LocaleKeys.settingsReadingDescription)),
        findsOneWidget,
      );
      expect(
        find.text(tr(LocaleKeys.settingsDesktopReadingContinuousScroll)),
        desktop ? findsOneWidget : findsNothing,
      );
      expect(
        find.text(tr(LocaleKeys.settingsMobileReadingHorizontal)),
        desktop ? findsNothing : findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            builder: (context, child) =>
                RevericTheme(data: RevericThemeData.reveric, child: child!),
            home: Scaffold(body: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
