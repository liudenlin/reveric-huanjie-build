// 职责: M5 资产版本历史服务 —— 覆盖/换图前留存快照，保证「历史保留、引用不丢」。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (AssetVersions 表)
//   lib/shared/database/novel_content_daos/asset_version_dao.dart
//   lib/shared/services/image_library_service.dart (图片上传/去重/软删)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v6→v7 createTable）
//
// §M5 资产版本历史：人物/道具/场景的视觉资产被重出或替换时，
// 先调用 recordVersion() 把「被替换的当前资产」追加一条版本记录，
// 再执行替换。版本只增不删；listVersions() 供 UI 展示历史时间线。

import 'package:drift/drift.dart' show Value;

import '../database/novel_content_database.dart';
import '../database/novel_content_daos/asset_version_dao.dart';
import '../logger/app_logger.dart';
import '../utils/random_id.dart';

final _log = AppLogger.forModule('AssetVersion');

/// 一次版本快照（供 UI 渲染时间线 / 测试断言）。
class AssetVersionEntry {
  const AssetVersionEntry({
    required this.id,
    required this.assetId,
    required this.version,
    required this.source,
    required this.snapshotName,
    required this.snapshotPath,
    required this.createdAt,
  });

  final String id;
  final String assetId;
  final int version;
  final String source;
  final String snapshotName;
  final String snapshotPath;
  final DateTime createdAt;
}

/// 资产版本历史服务。
class AssetVersionService {
  const AssetVersionService(this.db);

  final NovelContentDatabase db;

  AssetVersionDao get _dao => db.assetVersionDao;

  /// 覆盖资产前，把被替换的旧资产快照记一条版本（version 自动 +1）。
  ///
  /// 调用约定：先 [recordVersion] 再替换。若 [assetId] 尚无版本记录，
  /// 首条 version = 1。
  Future<AssetVersionRow> recordVersion({
    required String assetId,
    required String novelId,
    required String snapshotPath,
    required String snapshotSha256,
    required String snapshotName,
    String source = 'uploaded',
    String metadataJson = '{}',
  }) async {
    final nextVersion = (await _dao.currentVersion(assetId)) + 1;
    final id = buildRandomId('asset_ver');
    await _dao.upsert(
      AssetVersionsCompanion.insert(
        id: id,
        assetId: assetId,
        novelId: Value(novelId),
        version: Value(nextVersion),
        snapshotPath: Value(snapshotPath),
        snapshotSha256: Value(snapshotSha256),
        snapshotName: Value(snapshotName),
        source: Value(source),
        metadataJson: Value(metadataJson),
      ),
    );
    _log.info(
      '[AssetVersion] record assetId=$assetId v=$nextVersion '
      'source=$source '
      'sha=${snapshotSha256.length >= 8 ? snapshotSha256.substring(0, 8) : snapshotSha256}',
    );
    return (await _dao.getById(id))!;
  }

  /// 列出某逻辑资产的全部版本（新→旧），供 UI 时间线展示。
  Future<List<AssetVersionEntry>> listVersions(String assetId) async {
    final rows = await _dao.listByAsset(assetId);
    return rows.map(
      (r) => AssetVersionEntry(
        id: r.id,
        assetId: r.assetId,
        version: r.version,
        source: r.source,
        snapshotName: r.snapshotName,
        snapshotPath: r.snapshotPath,
        createdAt: r.createdAt,
      ),
    ).toList();
  }

  /// 取某版本快照（供「恢复到此版本」按钮使用）。
  Future<AssetVersionRow?> getVersion(String id) => _dao.getById(id);
}
