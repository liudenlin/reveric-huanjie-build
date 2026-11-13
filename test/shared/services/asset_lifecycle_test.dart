// 职责: R-43 资产生命周期状态机测试 — 状态推进规则、锁定解锁、旧数据兼容、merge 保留。
// 关联文件:
//   lib/shared/models/asset_lifecycle.dart
//   lib/shared/services/asset_lifecycle_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（R-43）：CANDIDATE→REVIEWED→APPROVED→LOCKED→DEPRECATED 单向推进；
//   锁定资产禁止静默降级（需显式解锁+原因）；旧资产无 lifecycle 键不崩。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/asset_lifecycle.dart';
import 'package:reveric/shared/services/asset_lifecycle_service.dart';

void main() {
  late AppDatabase db;
  late AssetLifecycleService service;

  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
    service = AssetLifecycleService(db);
  });

  tearDown(() async => db.close());

  Future<void> insertAsset({
    required String id,
    String source = 'uploaded',
    Map<String, dynamic>? metadata,
  }) async {
    await db.into(db.assets).insert(
      AssetsCompanion.insert(
        id: id,
        type: 'image',
        purpose: 'reference',
        source: Value(source),
        metadataJson: Value(metadata ?? const {}),
      ),
    );
  }

  group('assetLifecycle 推进规则', () {
    test('正常链推进：uploaded→candidate→reviewed→approved→locked→deprecated', () async {
      await insertAsset(id: 'a1');
      expect(await service.lifecycleOf('a1'), assetLifecycleUploaded);

      await service.updateLifecycle('a1', assetLifecycleCandidate);
      await service.updateLifecycle('a1', assetLifecycleReviewed);
      await service.updateLifecycle('a1', assetLifecycleApproved);
      expect(await service.lifecycleOf('a1'), assetLifecycleApproved);

      await service.updateLifecycle('a1', assetLifecycleLocked);
      expect(await service.lifecycleOf('a1'), assetLifecycleLocked);

      await service.updateLifecycle('a1', assetLifecycleDeprecated);
      expect(await service.lifecycleOf('a1'), assetLifecycleDeprecated);
    });

    test('可跳过中间档（uploaded→approved 直接可推进）', () async {
      await insertAsset(id: 'a1');
      await service.updateLifecycle('a1', assetLifecycleApproved);
      expect(await service.lifecycleOf('a1'), assetLifecycleApproved);
    });

    test('非法回退拒绝（approved 不能回 candidate）', () async {
      await insertAsset(id: 'a1', metadata: {'lifecycle': assetLifecycleApproved});
      expect(
        () => service.updateLifecycle('a1', assetLifecycleCandidate),
        throwsStateError,
      );
    });

    test('LOCKED 降级（解锁）必须显式 allowUnlock + 原因', () async {
      await insertAsset(id: 'a1', metadata: {'lifecycle': assetLifecycleLocked});
      // 无 allowUnlock → 拒绝。
      expect(
        () => service.updateLifecycle('a1', assetLifecycleReviewed),
        throwsStateError,
      );
      // allowUnlock 但无原因 → 拒绝。
      expect(
        () => service.updateLifecycle(
          'a1',
          assetLifecycleReviewed,
          allowUnlock: true,
        ),
        throwsStateError,
      );
      // 显式解锁 + 原因 → 放行。
      await service.updateLifecycle(
        'a1',
        assetLifecycleReviewed,
        allowUnlock: true,
        unlockReason: '作者确认修订后重锁',
      );
      expect(await service.lifecycleOf('a1'), assetLifecycleReviewed);
    });

    test('DEPRECATED 终态不可回退', () async {
      await insertAsset(
        id: 'a1',
        metadata: {'lifecycle': assetLifecycleDeprecated},
      );
      expect(
        () => service.updateLifecycle('a1', assetLifecycleApproved),
        throwsStateError,
      );
      // nextAssetLifecycles 返回空。
      expect(nextAssetLifecycles(assetLifecycleDeprecated), isEmpty);
    });

    test('generate 来源旧资产回退 generated；uploaded 来源回退 uploaded', () async {
      await insertAsset(id: 'gen', source: 'generated');
      await insertAsset(id: 'up', source: 'uploaded');
      expect(await service.lifecycleOf('gen'), assetLifecycleGenerated);
      expect(await service.lifecycleOf('up'), assetLifecycleUploaded);
    });
  });

  group('normalizeAssetLifecycle', () {
    test('null/非法值容错', () {
      expect(
        normalizeAssetLifecycle(null, source: 'uploaded'),
        assetLifecycleUploaded,
      );
      expect(
        normalizeAssetLifecycle('not_a_status'),
        assetLifecycleUploaded,
      );
      expect(
        normalizeAssetLifecycle(assetLifecycleApproved),
        assetLifecycleApproved,
      );
    });
  });
}