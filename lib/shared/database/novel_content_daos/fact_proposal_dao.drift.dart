// dart format width=80
// ignore_for_file: type=lint
part of 'fact_proposal_dao.dart';

mixin _$FactProposalDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $FactProposalsTable get factProposals => attachedDatabase.factProposals;
  FactProposalDaoManager get managers => FactProposalDaoManager(this);
}

class FactProposalDaoManager {
  final _$FactProposalDaoMixin _db;
  FactProposalDaoManager(this._db);
  $$FactProposalsTableTableManager get factProposals =>
      $$FactProposalsTableTableManager(_db.attachedDatabase, _db.factProposals);
}
