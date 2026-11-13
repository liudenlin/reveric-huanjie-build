// 职责: R-43 资产生命周期服务 — 读取/推进资产生命状态（metadataJson.lifecycle）。
// 关联文件:
//   lib/shared/models/asset_lifecycle.dart (状态常量与推进规则)
//   lib/shared/database/app_database.dart (Assets.metadataJson)
//   lib/shared/database/daos/image_asset_dao.dart (updateMetadata/getAsset)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（状态字段放 metadataJson，不动表结构）
//
// 验收（R-43）：CANDIDATE→REVIEWED→APPROVED→LOCKED 单向推进；
//   LOCKED 展示时提示需解锁才能修改；DEPRECATED 保留旧版本供历史引用。

import '../database/app_database.dart';
import '../logger/app_logger.dart';
import '../models/asset_lifecycle.dart';

final _log = AppLogger.forModule('AssetLifecycle');

/// 资产生命周期读取/推进的轻量服务。
///
/// 状态实际存在 `Assets.metadataJson['lifecycle']`（不动表结构）；
/// 旧资产没有该键时按来源回退（uploaded/generated）。更新走 merge，
/// 保留 metadataJson 里其它键（提示词/识别快照等）。
class AssetLifecycleService {
  const AssetLifecycleService(this._database);

  final AppDatabase _database;

  /// 未锁定的资产允许推进到的档位（供 UI 菜单渲染）。
  static List<String> nextOptions(String current) =>
      nextAssetLifecycles(current);

  /// 读取资产当前生命周期；资产不存在返回 null。
  Future<String?> lifecycleOf(String assetId) async {
    final asset = await _database.imageAssetDao.getAsset(assetId);
    if (asset == null) {
      return null;
    }
    final metadata = asset.metadataJson ?? const <String, dynamic>{};
    return normalizeAssetLifecycle(
      metadata['lifecycle'] as String?,
      source: asset.source,
    );
  }

  /// 推进资产生命周期。
  ///
  /// [allowUnlock] 仅对 LOCKED → REVIEWED（解锁）生效，且必须提供非空
  /// [unlockReason]；其余推进非法直接抛 [StateError]。DEPRECATED 终态不可回退。
  Future<void> updateLifecycle(
    String assetId,
    String newStatus, {
    bool allowUnlock = false,
    String unlockReason = '',
  }) async {
    final asset = await _database.imageAssetDao.getAsset(assetId);
    if (asset == null) {
      throw StateError('asset not found: $assetId');
    }
    final metadata = asset.metadataJson ?? const <String, dynamic>{};
    final current = normalizeAssetLifecycle(
      metadata['lifecycle'] as String?,
      source: asset.source,
    );
    if (!canAdvanceAssetLifecycle(
      current,
      newStatus,
      allowUnlock: allowUnlock,
      unlockReason: unlockReason,
    )) {
      throw StateError(
        'illegal lifecycle transition: $current -> $newStatus'
        '${current == assetLifecycleLocked && newStatus != assetLifecycleDeprecated ? '（锁定资产需显式解锁并记录原因）' : ''}',
      );
    }
    final nextMetadata = Map<String, dynamic>.from(metadata);
    nextMetadata['lifecycle'] = newStatus;
    await _database.imageAssetDao.updateMetadata(assetId, nextMetadata);
    _log.info('[AssetLifecycle] $assetId: $current -> $newStatus');
  }
}