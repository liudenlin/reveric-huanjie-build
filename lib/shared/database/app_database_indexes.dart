// 职责: 创建应用数据库首次建库所需的索引。
// 关联文件:
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/db-index-naming.md
import 'package:drift/drift.dart';

Future<void> createAppDatabaseIndexes(GeneratedDatabase database) async {
  await createPluginTaskIndexes(database);
  await createRemoteAuthorizationIndexes(database);
  await createRemoteAuthorizationAuditIndexes(database);
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS provider_assets_by_asset_id_provider_id '
    'ON provider_assets (asset_id, provider_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS provider_assets_by_status '
    'ON provider_assets (status)',
  );
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS tool_permission_rules_by_scope_type_work_id_scope_id_action_u ON tool_permission_rules(scope_type, work_id, scope_id, action)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS generation_tasks_by_draft_task_id_deleted_at '
    'ON generation_tasks (draft_task_id, deleted_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS generation_tasks_by_novel_id_source_type_source_id_deleted_at '
    'ON generation_tasks (novel_id, source_type, source_id, deleted_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS generation_tasks_by_kind_status_next_poll_at '
    'ON generation_tasks (kind, status, next_poll_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS novel_collection_members_by_novel_id '
    'ON novel_collection_members (novel_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS anonymous_outbox_events_by_next_retry_at_priority_id '
    'ON anonymous_outbox_events (next_retry_at, priority, id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS anonymous_outbox_events_by_endpoint_product_code_device_id_next_retry_at_id '
    'ON anonymous_outbox_events '
    '(endpoint, product_code, device_id, next_retry_at, id)',
  );
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS novel_agent_skills_by_name_u '
    'ON novel_agent_skills (name)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS novel_agent_skills_by_source_listing_public_id '
    'ON novel_agent_skills (source_listing_public_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS novel_agent_skills_by_sort_order '
    'ON novel_agent_skills (sort_order)',
  );
  await database.customStatement('''
CREATE UNIQUE INDEX novels_shelf_title_u
ON novels (title)
WHERE deleted_at = 0 AND draft = 0
''');
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS ai_usages_by_created_at '
    'ON ai_usages (created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS ai_usages_by_session_id_created_at '
    'ON ai_usages (session_id, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS ai_usages_by_source_created_at '
    'ON ai_usages (source, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS '
    'novel_agent_skill_revisions_by_skill_id_created_at '
    'ON novel_agent_skill_revisions (skill_id, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS '
    'novel_agent_skill_revisions_by_skill_id_turn_id '
    'ON novel_agent_skill_revisions (skill_id, turn_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS '
    'novel_agent_skill_revision_files_by_sha256 '
    'ON novel_agent_skill_revision_files (sha256)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assets_by_novel_purpose_deleted_created_id '
    'ON assets (novel_id, purpose, deleted_at, created_at, id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assets_by_sha256 ON assets (sha256)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assets_by_batch ON assets (batch_id)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assets_by_type_novel_id_deleted_at_created_at '
    'ON assets (type, novel_id, deleted_at, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS image_asset_references_by_asset_ordinal '
    'ON image_asset_references (asset_id, ordinal)',
  );
  // 一个批次的同一个序号只能有一个格子：重出是就地替换，不是追加一行。
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS image_batch_slots_by_batch_id_ordinal_u '
    'ON image_batch_slots (batch_id, ordinal)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assistant_messages_by_session_created '
    'ON assistant_messages (session_id, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS assistant_inbox_by_session_created '
    'ON assistant_inbox (assistant_session_id, created_at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS novels_by_source_novel_id '
    'ON novels (source_novel_id)',
  );
}

Future<void> createPluginTaskIndexes(
  GeneratedDatabase database,
) => database.customStatement(
  'CREATE INDEX IF NOT EXISTS plugin_tasks_by_enabled_next_due_at ON plugin_tasks(enabled, next_due_at)',
);

/// 远程授权表的唯一性**部分**索引（P0-B B1）。
///
/// SQLite 的 UNIQUE 约束对 NULL 不生效（NULL 彼此不同），若用表级
/// `UNIQUE(channel_type, chat_id, user_id)` 会允许同一渠道会话插入多条
/// user_id 为 NULL 的会话级记录。故拆成两个部分唯一索引（命名遵循
/// `{table}_by_{columns}_u` 规则）：
/// - 会话级（user_id IS NULL）：每个 (channel_type, chat_id) 至多一条；
/// - 用户绑定（user_id IS NOT NULL）：每个 (channel_type, chat_id, user_id)
///   至多一条。
/// 两条记录可并存（会话级 + 具体用户），与授权服务 `matches` 语义一致。
Future<void> createRemoteAuthorizationIndexes(
  GeneratedDatabase database,
) async {
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS '
    'remote_authorizations_by_channel_type_chat_id_u '
    'ON remote_authorizations (channel_type, chat_id) '
    'WHERE user_id IS NULL',
  );
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS '
    'remote_authorizations_by_channel_type_chat_id_user_id_u '
    'ON remote_authorizations (channel_type, chat_id, user_id) '
    'WHERE user_id IS NOT NULL',
  );
}

/// 远程授权审计表的查询索引（P0-B B3）。
///
/// 审计表追加式、按时间范围 / 渠道 / Job 查询与保留期限清理：
/// - `at` 索引服务时间范围查询与清理（cleanupBefore 按 at 删除）；
/// - `(channel_type, at)` 服务按渠道 + 时间过滤。
/// 命名遵循 `{table}_by_{columns}` 规则（非唯一，故无 `_u` 后缀）。
Future<void> createRemoteAuthorizationAuditIndexes(
  GeneratedDatabase database,
) async {
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS remote_authorization_audit_by_at '
    'ON remote_authorization_audit (at)',
  );
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS remote_authorization_audit_by_channel_type_at '
    'ON remote_authorization_audit (channel_type, at)',
  );
}
