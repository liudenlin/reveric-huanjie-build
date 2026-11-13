// 职责: M5 AssetVersionDao — 资产版本历史（覆盖前快照留存）数据访问。
// 关联文件:
//   lib/shared/database/novel_content_database.dart (AssetVersions 表)
//   lib/shared/services/asset_version_service.dart (版本化服务)
// 遵循的 Rules:
//   .agents/rules/db-migration.md（v6→v7 createTable，保旧数据）
//
// §M5 资产版本历史：人物/道具/场景视觉资产被覆盖（重出/换图）前，
// 把被替换的当前资产快照追加一条记录，保证「历史保留、引用不丢」。

import 'package:drift/drift.dart' hide Column;

import '../novel_content_database.dart';

part 'asset_version_dao.drift.dart';

/// 资产版本历史 DAO。
@DriftAccessor(tables: [AssetVersions])
class AssetVersionDao extends DatabaseAccessor<NovelContentDatabase>
    with _$AssetVersionDaoMixin {
  AssetVersionDao(super.db);

  /// 列出某逻辑资产的全部版本（新→旧）。
  Future<List<AssetVersionRow>> listByAsset(String assetId) {
    return (select(assetVersions)
          ..where(
            (t) =>
                t.assetId.equals(assetId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.version,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  /// 流式观察某逻辑资产的版本列表（UI 实时刷新）。
  Stream<List<AssetVersionRow>> watchByAsset(String assetId) {
    return (select(assetVersions)
          ..where(
            (t) =>
                t.assetId.equals(assetId) &
                t.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.version,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// 取某逻辑资产的当前最大版本号（0 = 尚无版本记录）。
  Future<int> currentVersion(String assetId) async {
    final row = await (selectOnly(assetVersions)
          ..addColumns([
            assetVersions.version.max(),
          ])
          ..where(
            assetVersions.assetId.equals(assetId) &
                assetVersions.deletedAt.equals(notDeletedSentinel),
          ))
        .getSingle();
    return row.read(assetVersions.version.max()) ?? 0;
  }

  Future<AssetVersionRow?> getById(String id) {
    return (select(assetVersions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 幂等写入（同 id 覆盖）。
  Future<void> upsert(AssetVersionsCompanion entry) {
    return into(assetVersions).insertOnConflictUpdate(entry);
  }

  /// 软删除（版本历史一般不删，仅异常时用）。
  Future<void> softDelete(String id) {
    return (update(assetVersions)..where((t) => t.id.equals(id))).write(
      AssetVersionsCompanion(
        deletedAt: Value(DateTime.now()),
      ),
    );
  }
}