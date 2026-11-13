// 职责: M4e 影响审计面板 widget 测试 — 空态 / 记录渲染 / 状态徽章 / 标记已复核。
// 验收（施工总纲 M4）：影响报告展示 — 桌面端展示 auditRow.resultJson、
//   待复核标记、已复核点击。
// 关联文件:
//   lib/shared/widgets/impact_audit_panel.dart
//   lib/shared/providers/novel_providers.dart (impactAuditsProvider)
//   lib/shared/services/impact_audit_models.dart
// 说明:
//   1. 经 impactAuditsProvider override 注入内存 Stream，不依赖 drift 真实
//      数据库的 watch（后者在 flutter test 的 FakeAsync 区不可控）。
//   2. 包裹结构与仓库既有通过的 workspace widget 测试一致（story_progress_test
//      等）：ProviderScope 在 EasyLocalization 的 Builder 内、包住 MaterialApp。
//      注意 locale 用 zh_CN —— en locale 在本项目测试环境下存在 pre-existing
//      的 asset 加载问题（连纯 Text 都不渲染，provider_actions_test 等同样失败），
//      而 zh_CN 可完整渲染，故按产品默认语言断言中文文案。

import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/impact_audit_models.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/impact_audit_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const path = 'impact_audit_ui_test';

/// 构造 resultJson 字符串（服务写出的 schema 是 toJson()）。
String _resultJson(ImpactAuditResult result) => jsonEncode(result.toJson());

const _hitResult = ImpactAuditResult(
  request: ImpactAuditRequest(
    resourcePath: 'chapters/ch_20',
    resourceType: 'chapter',
    resourceId: 'ch_20',
    field: 'content',
    oldText: '旧正文',
    newText: '新正文',
  ),
  affectedChapters: [
    ImpactHit(
      resourceType: 'chapter',
      resourceId: 'ch_21',
      title: 'Chapter 21',
      evidence: 'Shen Yan appears',
      context: 'Chapter 21 body',
      confidence: 1.0,
      severity: ImpactSeverity.direct,
      reviewPending: true,
    ),
  ],
  affectedForeshadowings: [],
  affectedRelations: [],
  affectedCharacters: [],
  summary: '1 downstream hit',
  // 覆盖 3/5 → 尚有 2 个未检查，应出现高亮提示。
  coverage: '已检查 3 / 5 个对象',
  checkedCount: 3,
  totalRelevantCount: 5,
);

const _noHitResult = ImpactAuditResult(
  request: ImpactAuditRequest(
    resourcePath: 'characters/cha_1',
    resourceType: 'character',
    resourceId: 'cha_1',
    oldText: '旧传记',
    newText: '新传记',
  ),
  affectedChapters: [],
  affectedForeshadowings: [],
  affectedRelations: [],
  affectedCharacters: [],
  summary: '',
);

/// 构造一条 ImpactAudit 记录（drift DataClass 的字段）。
ImpactAudit _audit({
  required String id,
  required String changeId,
  required String status,
  required int hitCount,
  required String resultJson,
}) {
  final now = DateTime.now();
  return ImpactAudit(
    id: id,
    changeId: changeId,
    resourcePath: 'chapters/ch_20',
    resourceType: 'chapter',
    resourceId: 'ch_20',
    resultJson: resultJson,
    status: status,
    hitCount: hitCount,
    createdAt: now,
    updatedAt: now,
  );
}

/// 与仓库既有通过的 widget 测试（story_progress_test 等）保持同一包裹结构。
Widget _wrap(
  Widget child, {
  List<Override> overrides = const [],
  TargetPlatform platform = TargetPlatform.macOS,
}) {
  return EasyLocalization(
    key: UniqueKey(),
    supportedLocales: const [Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('zh', 'CN'),
    startLocale: const Locale('zh', 'CN'),
    child: Builder(
      builder: (context) {
        return ProviderScope(
          overrides: overrides,
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData().copyWith(
              platform: platform,
            ),
            builder: (context, child) {
              return RevericTheme(
                data: RevericThemeData.reveric,
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(body: child),
            ),
          ),
        );
      },
    ),
  );
}

/// 以指定审计记录渲染面板（override 注入内存 Stream）。
Widget _panelWith(List<ImpactAudit> records) {
  return _wrap(
    const ImpactAuditPanel(databasePath: path),
    overrides: [
      impactAuditsProvider(path).overrideWith(
        (ref) => Stream<List<ImpactAudit>>.value(records),
      ),
    ],
  );
}

void main() {
  setUp(() => rootBundle.clear());

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('空态：无审计记录时展示标题与提示', (tester) async {
    await tester.pumpWidget(_panelWith(const []));
    await tester.pumpAndSettle();

    expect(find.text('影响审计'), findsOneWidget);
    expect(find.text('还没有影响审计记录'), findsOneWidget);
    expect(find.text('标记已复核'), findsNothing);
  });

  testWidgets('记录渲染：待复核徽章 + 下游命中分组 + 证据 + 置信度', (tester) async {
    await tester.pumpWidget(_panelWith([
      _audit(
        id: 'audit_1',
        changeId: 'chg_1',
        status: impactAuditStatusRecorded,
        hitCount: 1,
        resultJson: _resultJson(_hitResult),
      ),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('影响审计'), findsOneWidget);
    expect(find.text('待复核'), findsOneWidget);
    // 头部总命中统计 + 记录卡命中数各出现一次，共两处。
    expect(find.text('1 处下游命中'), findsNWidgets(2));
    expect(find.text('受影响章节'), findsOneWidget);
    expect(find.text('Chapter 21'), findsOneWidget);
    expect(find.text('“Shen Yan appears”'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    // 影响强度徽章：直接命中 → 「直接」。
    expect(find.text('直接'), findsOneWidget);
    // 覆盖提示：已检查 3 / 5，尚有 2 个未检查，且高亮未扫描提示。
    expect(find.text('已检查 3 个对象，尚有 2 个未检查'), findsOneWidget);
    expect(find.text('未扫描部分不能视为已通过，建议补扫后复核'), findsOneWidget);
    // 默认建议文案（按结果最高档 DIRECT）。
    expect(find.text('建议：命中变更对象自身名称，优先复核该处引用是否符合新设定'),
        findsOneWidget);
    expect(find.text('标记已复核'), findsOneWidget);
  });

  testWidgets('无下游命中：显示无影响文案，不显示标记按钮', (tester) async {
    await tester.pumpWidget(_panelWith([
      _audit(
        id: 'audit_2',
        changeId: 'chg_2',
        status: impactAuditStatusNone,
        hitCount: 0,
        resultJson: _resultJson(_noHitResult),
      ),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('无下游影响'), findsOneWidget);
    // 覆盖完整（0/0）提示 + 结果级 NONE 默认建议。
    expect(find.text('已检查 0 个对象，覆盖完整'), findsOneWidget);
    expect(find.text('建议：未发现下游引用，可暂不处理'), findsOneWidget);
    expect(find.text('标记已复核'), findsNothing);
  });

  testWidgets('已复核记录：显示已复核徽章，不显示标记按钮', (tester) async {
    await tester.pumpWidget(_panelWith([
      _audit(
        id: 'audit_4',
        changeId: 'chg_4',
        status: impactAuditStatusReviewed,
        hitCount: 1,
        resultJson: _resultJson(_hitResult),
      ),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('已复核'), findsOneWidget);
    expect(find.text('标记已复核'), findsNothing);
  });
}
