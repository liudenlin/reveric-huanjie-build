// dart format width=80
// ignore_for_file: type=lint
part of 'content_lock_dao.dart';

mixin _$ContentLockDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $ContentLocksTable get contentLocks => attachedDatabase.contentLocks;
  ContentLockDaoManager get managers => ContentLockDaoManager(this);
}

class ContentLockDaoManager {
  final _$ContentLockDaoMixin _db;
  ContentLockDaoManager(this._db);
  $$ContentLocksTableTableManager get contentLocks =>
      $$ContentLocksTableTableManager(_db.attachedDatabase, _db.contentLocks);
}

mixin _$CanonEntryDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $CanonEntriesTable get canonEntries => attachedDatabase.canonEntries;
  CanonEntryDaoManager get managers => CanonEntryDaoManager(this);
}

class CanonEntryDaoManager {
  final _$CanonEntryDaoMixin _db;
  CanonEntryDaoManager(this._db);
  $$CanonEntriesTableTableManager get canonEntries =>
      $$CanonEntriesTableTableManager(_db.attachedDatabase, _db.canonEntries);
}
