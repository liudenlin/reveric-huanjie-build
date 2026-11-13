// dart format width=80
// ignore_for_file: type=lint
part of 'decision_log_dao.dart';

mixin _$DecisionLogDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $DecisionLogsTable get decisionLogs => attachedDatabase.decisionLogs;
  DecisionLogDaoManager get managers => DecisionLogDaoManager(this);
}

class DecisionLogDaoManager {
  final _$DecisionLogDaoMixin _db;
  DecisionLogDaoManager(this._db);
  $$DecisionLogsTableTableManager get decisionLogs =>
      $$DecisionLogsTableTableManager(_db.attachedDatabase, _db.decisionLogs);
}
