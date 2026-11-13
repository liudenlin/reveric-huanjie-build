// dart format width=80
// ignore_for_file: type=lint
part of 'research_task_dao.dart';

mixin _$ResearchTaskDaoMixin on DatabaseAccessor<NovelContentDatabase> {
  $ResearchTasksTable get researchTasks => attachedDatabase.researchTasks;
  ResearchTaskDaoManager get managers => ResearchTaskDaoManager(this);
}

class ResearchTaskDaoManager {
  final _$ResearchTaskDaoMixin _db;
  ResearchTaskDaoManager(this._db);
  $$ResearchTasksTableTableManager get researchTasks =>
      $$ResearchTasksTableTableManager(_db.attachedDatabase, _db.researchTasks);
}
