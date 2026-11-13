// dart format width=80
// ignore_for_file: type=lint
part of 'chapter_paragraph_dao.dart';

mixin _$ChapterParagraphDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $ChapterParagraphsTable get chapterParagraphs =>
      attachedDatabase.chapterParagraphs;
  ChapterParagraphDaoManager get managers => ChapterParagraphDaoManager(this);
}

class ChapterParagraphDaoManager {
  final _$ChapterParagraphDaoMixin _db;
  ChapterParagraphDaoManager(this._db);
  $$ChapterParagraphsTableTableManager get chapterParagraphs =>
      $$ChapterParagraphsTableTableManager(
        _db.attachedDatabase,
        _db.chapterParagraphs,
      );
}
