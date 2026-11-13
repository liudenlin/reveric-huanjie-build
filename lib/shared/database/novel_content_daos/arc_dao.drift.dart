// dart format width=80
// ignore_for_file: type=lint
part of 'arc_dao.dart';

mixin _$ArcDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $ArcsTable get arcs => attachedDatabase.arcs;
  ArcDaoManager get managers => ArcDaoManager(this);
}

class ArcDaoManager {
  final _$ArcDaoMixin _db;
  ArcDaoManager(this._db);
  $$ArcsTableTableManager get arcs =>
      $$ArcsTableTableManager(_db.attachedDatabase, _db.arcs);
}
