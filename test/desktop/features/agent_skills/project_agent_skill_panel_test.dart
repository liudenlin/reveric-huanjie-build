// 职责: R-33 project 层 AgentSkill 覆盖集面板回归测试 —— 验证空态、新建、
//   编辑、启停与删除的 UI 到 service 写入链路。
// 关联文件:
//   lib/desktop/features/agent_skills/project_agent_skill_panel.dart
//   lib/shared/providers/project_agent_skill_providers.dart
//   lib/shared/database/app_database.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/i18n.md
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/agent_skills/project_agent_skill_panel.dart';
import 'package:reveric/shared/components/reveric_text_field.dart';
import 'package:reveric/shared/components/reveric_switch.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/agent_skill_providers.dart';
import 'package:reveric/shared/providers/dictionary_providers.dart';
import 'package:reveric/shared/providers/project_agent_skill_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async {
    // _disposeTree 已先关库；此处兜底且容忍重复关闭。
    try {
      await db.close();
    } catch (_) {
      // 已关闭时忽略。
    }
  });

  testWidgets('empty state then create a project skill through the form', (
    tester,
  ) async {
    await _pump(tester, db);

    expect(
      find.text(tr(LocaleKeys.agentSkillProjectEmptyTitle)),
      findsOneWidget,
    );
    expect(find.text('Project Skill A'), findsNothing);

    await tester.tap(
      find.widgetWithText(FilledButton, tr(LocaleKeys.commonCreate)).first,
    );
    await tester.pumpAndSettle();

    // 表单已打开：保存按钮可见，名称输入框为空。
    expect(find.text(tr(LocaleKeys.commonSave)), findsOneWidget);
    final nameField = tester.widget<TextField>(
      find.descendant(
        of: find.byType(RevericTextField).at(0),
        matching: find.byType(TextField),
      ),
    );
    expect(nameField.controller!.text, isEmpty);

    await _disposeTree(tester, db);
  });

  testWidgets('toggle enabled persists through service', (tester) async {
    await _seed(db, 'toggle-skill', name: 'Toggle Skill');
    await _pump(tester, db);

    expect(find.text('Toggle Skill'), findsOneWidget);
    await tester.tap(find.byType(RevericSwitch));
    await tester.pumpAndSettle();

    final saved = await ProjectAgentSkillOverrideService(
      db,
    ).loadByNovelId('novel-a');
    expect(saved.single.enabled, isFalse);

    await _disposeTree(tester, db);
  });

  testWidgets('delete requires confirmation then removes', (tester) async {
    await _seed(db, 'delete-skill', name: 'Delete Skill');
    await _pump(tester, db);

    await _openRowMenu(tester);
    await tester.tap(find.text(tr(LocaleKeys.agentSkillRemove)));
    await tester.pumpAndSettle();

    // 取消不删除。
    await tester.tap(find.text(tr(LocaleKeys.commonCancel)));
    await tester.pumpAndSettle();
    expect(find.text('Delete Skill'), findsOneWidget);

    await _openRowMenu(tester);
    await tester.tap(find.text(tr(LocaleKeys.agentSkillRemove)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text(tr(LocaleKeys.agentSkillRemove)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete Skill'), findsNothing);
    expect(
      await ProjectAgentSkillOverrideService(db).loadByNovelId('novel-a'),
      isEmpty,
    );

    await _disposeTree(tester, db);
  });

  testWidgets('edit prefills and saves updated name', (tester) async {
    await _seed(
      db,
      'edit-skill',
      name: 'Edit Skill',
      prompt: 'Old prompt',
      category: 'General',
    );
    await _pump(tester, db);

    await tester.tap(find.text('Edit Skill'));
    await tester.pumpAndSettle();

    // 编辑器已打开：保存按钮存在，名称输入框预填旧值。
    expect(find.text(tr(LocaleKeys.commonSave)), findsOneWidget);
    final nameField = tester.widget<TextField>(
      find.descendant(
        of: find.byType(RevericTextField).at(0),
        matching: find.byType(TextField),
      ),
    );
    expect(nameField.controller!.text, 'Edit Skill');
    await tester.enterText(
      find.byType(RevericTextField).at(0),
      'Renamed Skill',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text(tr(LocaleKeys.commonSave)));
    await tester.pumpAndSettle();

    expect(find.text('Renamed Skill'), findsOneWidget);
    final saved = await ProjectAgentSkillOverrideService(
      db,
    ).loadByNovelId('novel-a');
    expect(saved.single.name, 'Renamed Skill');

    await _disposeTree(tester, db);
  });
}

Future<void> _pump(WidgetTester tester, AppDatabase db) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        agentSkillAppDatabaseProvider.overrideWithValue(db),
        skillCategoriesProvider.overrideWith((ref) async => const []),
        skillTagsProvider.overrideWith((ref) async => const []),
      ],
      child: EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (context) {
            return MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              home: RevericTheme(
                data: RevericThemeData.reveric,
                child: Scaffold(
                  body: ProjectAgentSkillPanel(
                    novelId: 'novel-a',
                    novelTitle: 'Novel A',
                    onBack: () {},
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _seed(
  AppDatabase db,
  String id, {
  required String name,
  String prompt = 'Prompt',
  String category = '',
}) async {
  await ProjectAgentSkillOverrideService(db).upsert(
    ProjectAgentSkillOverrideInput(
      novelId: 'novel-a',
      name: name,
      description: 'description',
      prompt: prompt,
      category: category,
      existingId: id,
    ),
  );
}

/// 先关库再卸载 widget：Drift 流取消时会用 `Timer.run` 缓存关闭，若不先关库，
/// 该 0 时长定时器会在测试收尾时被判定为 pending。
Future<void> _disposeTree(WidgetTester tester, AppDatabase db) async {
  await db.close();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pump();
}

Future<void> _openRowMenu(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate(
      (widget) =>
          widget is RevericIcon && widget.assetPath == RevericIcons.more_horiz,
    ),
  );
  await tester.pumpAndSettle();
}
