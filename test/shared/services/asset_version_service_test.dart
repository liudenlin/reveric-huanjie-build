// 职责: M5 AssetVersionService 测试 — 版本快照留存、currentVersion 递增、历史查询。
// 关联文件:
//   lib/shared/services/asset_version_service.dart
//   lib/shared/database/novel_content_database.dart (AssetVersions 表)
// 遵循的 Rules:
//   .agents/rules/testing.md
//
// 验收（总纲 §4 M5）：人物/道具/场景视觉资产被覆盖时先留版本，历史保留、引用不丢。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/asset_version_service.dart';

void main() {
  late NovelContentDatabase db;
  late AssetVersionService service;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = AssetVersionService(db);
  });

  tearDown(() async => db.close());

  group('AssetVersionService', () {
    test('recordVersion 版本号从 1 递增', () async {
      await service.recordVersion(
        assetId: 'asset_1',
        novelId: 'novel_x',
        snapshotPath: 'data/a1.png',
        snapshotSha256: 'sha1',
        snapshotName: '林晚_v1.png',
        source: 'generated',
      );
      final v1 = await service.listVersions('asset_1');
      expect(v1, hasLength(1));
      expect(v1.single.version, 1);

      await service.recordVersion(
        assetId: 'asset_1',
        novelId: 'novel_x',
        snapshotPath: 'data/a2.png',
        snapshotSha256: 'sha2',
        snapshotName: '林晚_v2.png',
        source: 'generated',
      );
      final v2 = await service.listVersions('asset_1');
      expect(v2, hasLength(2));
      // 新→旧：[v2, v1]
      expect(v2.first.version, 2);
      expect(v2.last.version, 1);
      expect(v2.first.snapshotPath, 'data/a2.png');
    });

    test('currentVersion 无记录时返回 0', () async {
      expect(await db.assetVersionDao.currentVersion('none'), 0);
    });

    test('listVersions 空资产返回空列表', () async {
      expect(await service.listVersions('never_recorded'), isEmpty);
    });

    test('getVersion 可取回指定版本快照', () async {
      await service.recordVersion(
        assetId: 'asset_x',
        novelId: 'novel_x',
        snapshotPath: 'data/x.png',
        snapshotSha256: 'shax',
        snapshotName: 'v1',
        source: 'uploaded',
      );
      final versions = await db.assetVersionDao.listByAsset('asset_x');
      final id = versions.single.id;
      final got = await service.getVersion(id);
      expect(got, isNotNull);
      expect(got!.snapshotName, 'v1');
      expect(got.source, 'uploaded');
    });

    test('不同逻辑资产版本独立计数', () async {
      await service.recordVersion(
        assetId: 'asset_A',
        novelId: 'n',
        snapshotPath: 'a',
        snapshotSha256: '1',
        snapshotName: 'A1',
      );
      await service.recordVersion(
        assetId: 'asset_B',
        novelId: 'n',
        snapshotPath: 'b',
        snapshotSha256: '2',
        snapshotName: 'B1',
      );
      expect(await db.assetVersionDao.currentVersion('asset_A'), 1);
      expect(await db.assetVersionDao.currentVersion('asset_B'), 1);
    });

    test('AssetVersions 软删哨兵默认值正确', () async {
      await db.into(db.assetVersions).insert(
        AssetVersionsCompanion.insert(
          id: 'av_defaults',
          assetId: 'asset_d',
        ),
      );
      final row = (await db.assetVersionDao.getById('av_defaults'))!;
      expect(row.deletedAt, notDeletedSentinel);
      expect(row.version, 1);
      expect(row.metadataJson, '{}');
    });
  });
}
