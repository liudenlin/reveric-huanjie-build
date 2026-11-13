// dart format width=80
// ignore_for_file: type=lint
part of 'asset_version_dao.dart';

mixin _$AssetVersionDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $AssetVersionsTable get assetVersions => attachedDatabase.assetVersions;
  AssetVersionDaoManager get managers => AssetVersionDaoManager(this);
}

class AssetVersionDaoManager {
  final _$AssetVersionDaoMixin _db;
  AssetVersionDaoManager(this._db);
  $$AssetVersionsTableTableManager get assetVersions =>
      $$AssetVersionsTableTableManager(_db.attachedDatabase, _db.assetVersions);
}
