// 职责: 侧边栏 AI 会话列表头部 — 会话快照导出/导入入口（P2-2），供续写与迁移。
// 关联文件:
//   lib/shared/services/ai/session_snapshot_service.dart
//   lib/shared/providers/novel_providers.dart
//   lib/desktop/widgets/ai/chat/session_list.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/file-access.md
//   .agents/rules/error-handling.md

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/components/reveric_context_menu.dart';
import '../../../../shared/components/reveric_icon_button.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/logger/app_logger.dart';
import '../../../../shared/providers/novel_providers.dart';
import '../../../../shared/services/ai/session_snapshot_service.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/confirm_dialog.dart';

final _log = AppLogger.forModule('SessionSnapshotActions');

/// 会话快照操作的 "..." 入口。数据库路径或作品 ID 缺失时隐藏，避免点击后必败。
class SessionSnapshotActions extends ConsumerWidget {
  const SessionSnapshotActions({
    super.key,
    required this.novelId,
    required this.databasePath,
  });

  final String novelId;
  final String? databasePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbPath = databasePath;
    if (dbPath == null || dbPath.isEmpty || novelId.isEmpty) {
      return const SizedBox.shrink();
    }
    return Builder(
      builder: (buttonContext) => RevericIconButton(
        icon: RevericIcons.more_horiz,
        tooltip: context.t(LocaleKeys.commonMoreActions),
        onPressed: () {
          final box = buttonContext.findRenderObject()! as RenderBox;
          showRevericContextMenu(
            context: context,
            position: box.localToGlobal(Offset(0, box.size.height)),
            entries: [
              RevericMenuItem(
                icon: RevericIcons.download_simple,
                label: context.t(LocaleKeys.commonExport),
                onTap: () => _exportSnapshot(context, ref, novelId, dbPath),
              ),
              RevericMenuItem(
                icon: RevericIcons.upload,
                label: context.t(LocaleKeys.commonImport),
                onTap: () => _importSnapshot(context, ref, novelId, dbPath),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 导出：写为缩进 JSON 到用户选择位置。无会话时提示，不静默落空文件。
Future<void> _exportSnapshot(
  BuildContext context,
  WidgetRef ref,
  String novelId,
  String databasePath,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final emptyMessage = context.t(LocaleKeys.aiSessionSnapshotExportEmpty);
  final failedMessage = context.t(LocaleKeys.aiSessionSnapshotFailed);
  void show(String message) =>
      messenger.showSnackBar(SnackBar(content: Text(message)));

  try {
    final service = _buildService(ref, novelId, databasePath);
    final snapshot = await service.exportNovelSessions(novelId: novelId);
    final sessionCount = (snapshot['sessions'] as List).length;
    if (sessionCount == 0) {
      show(emptyMessage);
      return;
    }
    final location = await getSaveLocation(
      suggestedName: 'novel_sessions_$novelId.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) {
      return;
    }
    await File(location.path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(snapshot),
      flush: true,
    );
    if (context.mounted) {
      show(
        context.t(
          LocaleKeys.aiSessionSnapshotExportDone,
          namedArgs: {'count': '$sessionCount'},
        ),
      );
    }
  } catch (error, stackTrace) {
    _log.error(
      '[SessionSnapshot] export failed novelId=$novelId',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      show(failedMessage);
    }
  }
}

/// 导入：选择 JSON，确认后合并导入；结果摘要反馈给用户。
Future<void> _importSnapshot(
  BuildContext context,
  WidgetRef ref,
  String novelId,
  String databasePath,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final invalidMessage = context.t(LocaleKeys.aiSessionSnapshotInvalidFile);
  final failedMessage = context.t(LocaleKeys.aiSessionSnapshotFailed);
  final confirmTitle =
      context.t(LocaleKeys.aiSessionSnapshotImportConfirmTitle);
  final confirmBody =
      context.t(LocaleKeys.aiSessionSnapshotImportConfirmBody);
  void show(String message) =>
      messenger.showSnackBar(SnackBar(content: Text(message)));

  try {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (file == null) {
      return;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      show(invalidMessage);
      return;
    }
    if (!context.mounted) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: confirmTitle,
      message: confirmBody,
    );
    if (!confirmed) {
      return;
    }
    final service = _buildService(ref, novelId, databasePath);
    final result = await service.importNovelSessions(
      snapshot: Map<String, dynamic>.from(decoded),
      targetNovelId: novelId,
    );
    if (context.mounted) {
      show(
        context.t(
          LocaleKeys.aiSessionSnapshotImportDone,
          namedArgs: {
            'sessions': '${result.importedSessions}',
            'messages': '${result.importedMessages}',
          },
        ),
      );
    }
  } catch (error, stackTrace) {
    _log.error(
      '[SessionSnapshot] import failed novelId=$novelId',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      show(failedMessage);
    }
  }
}

/// 组装快照服务：app 库承载会话行，作品内容库承载消息行。
SessionSnapshotService _buildService(
  WidgetRef ref,
  String novelId,
  String databasePath,
) {
  return SessionSnapshotService(
    appDatabase: ref.read(appDatabaseProvider),
    novelContentDatabase: ref.read(novelContentDatabaseProvider(databasePath)),
    novelId: novelId,
  );
}
