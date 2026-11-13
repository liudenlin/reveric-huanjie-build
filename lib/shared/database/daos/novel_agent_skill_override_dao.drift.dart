// dart format width=80
// ignore_for_file: type=lint
part of 'novel_agent_skill_override_dao.dart';

mixin _$NovelAgentSkillOverrideDaoMixin on DatabaseAccessor<AppDatabase> {
  $NovelAgentSkillOverridesTable get novelAgentSkillOverrides =>
      attachedDatabase.novelAgentSkillOverrides;
  $NovelAgentSkillOverrideReferencesTable
  get novelAgentSkillOverrideReferences =>
      attachedDatabase.novelAgentSkillOverrideReferences;
  NovelAgentSkillOverrideDaoManager get managers =>
      NovelAgentSkillOverrideDaoManager(this);
}

class NovelAgentSkillOverrideDaoManager {
  final _$NovelAgentSkillOverrideDaoMixin _db;
  NovelAgentSkillOverrideDaoManager(this._db);
  $$NovelAgentSkillOverridesTableTableManager get novelAgentSkillOverrides =>
      $$NovelAgentSkillOverridesTableTableManager(
        _db.attachedDatabase,
        _db.novelAgentSkillOverrides,
      );
  $$NovelAgentSkillOverrideReferencesTableTableManager
  get novelAgentSkillOverrideReferences =>
      $$NovelAgentSkillOverrideReferencesTableTableManager(
        _db.attachedDatabase,
        _db.novelAgentSkillOverrideReferences,
      );
}
