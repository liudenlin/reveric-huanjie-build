// dart format width=80
// ignore_for_file: type=lint
part of 'embedding_document_dao.dart';

mixin _$EmbeddingDocumentDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $AiEmbeddingDocumentsTable get aiEmbeddingDocuments =>
      attachedDatabase.aiEmbeddingDocuments;
  EmbeddingDocumentDaoManager get managers => EmbeddingDocumentDaoManager(this);
}

class EmbeddingDocumentDaoManager {
  final _$EmbeddingDocumentDaoMixin _db;
  EmbeddingDocumentDaoManager(this._db);
  $$AiEmbeddingDocumentsTableTableManager get aiEmbeddingDocuments =>
      $$AiEmbeddingDocumentsTableTableManager(
        _db.attachedDatabase,
        _db.aiEmbeddingDocuments,
      );
}
