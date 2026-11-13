// dart format width=80
// ignore_for_file: type=lint
part of 'impact_audit_dao.dart';

mixin _$ImpactAuditDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $ImpactAuditsTable get impactAudits => attachedDatabase.impactAudits;
  ImpactAuditDaoManager get managers => ImpactAuditDaoManager(this);
}

class ImpactAuditDaoManager {
  final _$ImpactAuditDaoMixin _db;
  ImpactAuditDaoManager(this._db);
  $$ImpactAuditsTableTableManager get impactAudits =>
      $$ImpactAuditsTableTableManager(_db.attachedDatabase, _db.impactAudits);
}
