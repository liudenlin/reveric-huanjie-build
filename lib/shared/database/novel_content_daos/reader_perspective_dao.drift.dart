// dart format width=80
// ignore_for_file: type=lint
part of 'reader_perspective_dao.dart';

mixin _$ReaderPerspectiveDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $ReaderPerspectivesTable get readerPerspectives =>
      attachedDatabase.readerPerspectives;
  ReaderPerspectiveDaoManager get managers => ReaderPerspectiveDaoManager(this);
}

class ReaderPerspectiveDaoManager {
  final _$ReaderPerspectiveDaoMixin _db;
  ReaderPerspectiveDaoManager(this._db);
  $$ReaderPerspectivesTableTableManager get readerPerspectives =>
      $$ReaderPerspectivesTableTableManager(
        _db.attachedDatabase,
        _db.readerPerspectives,
      );
}
