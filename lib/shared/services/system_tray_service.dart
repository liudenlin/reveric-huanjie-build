// 职责: 系统托盘服务 — 管理托盘图标、菜单与关闭到托盘行为
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/widgets/confirm_dialog.dart
//   lib/main.dart
//   lib/shared/services/window_state_service.dart
//   lib/desktop/widgets/novel_form_dialog.dart
//   lib/desktop/pages/workspace_editor_page.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//
// P0 崩溃根治：tray_manager 0.8.x 依赖 nativeapi（运行时加载 cnativeapi.dll
// 即触发 0xC0000005 崩溃，且 nativeapi 0.5.10 的 Isolate.create 与 Flutter
// master 不兼容导致构建失败）。此处改用 tray_manager 0.5.3 旧式 API
// （TrayManager.instance / setIcon / setContextMenu / TrayListener），
// 完全移除 nativeapi 运行时依赖。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart' as tray;

import '../components/dialog_feedback.dart';
import '../database/app_database.dart';
import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import '../logger/startup_failure_reporter.dart';
import 'crash_reporting/crash_sentinel.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'single_instance_service.dart';
import '../../desktop/widgets/novel_form_dialog.dart';
import '../providers/novel_providers.dart';
import '../../desktop/pages/workspace_editor_page.dart';
import '../components/reveric_dialog.dart';
import '../widgets/confirm_dialog.dart';
import '../components/reveric_button.dart';

final _log = AppLogger.forModule('SystemTray');

class SystemTrayService {
  final List<Future<bool> Function()> _exitGuards = [];
  VoidCallback registerExitGuard(Future<bool> Function() guard) {
    _exitGuards.add(guard);
    return () => _exitGuards.remove(guard);
  }

  static String get _iconPath {
    if (Platform.isWindows) {
      return 'assets/logo/reveric_mark_32.ico';
    }
    return 'assets/logo/reveric_mark_32.png';
  }

  static final SystemTrayService _instance = SystemTrayService._internal();
  factory SystemTrayService() => _instance;
  SystemTrayService._internal();

  @visibleForTesting
  SystemTrayService.forTesting();

  // tray_manager 0.5.3：无 TrayIcon/Menu 句柄对象，仅持有监听器与菜单引用。
  tray.TrayListener? _trayListener;
  tray.Menu? _menu;

  GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) {
      return;
    }

    try {
      // 0.5.3 的 setIcon 在 Windows 下解析到
      // <exe>/data/flutter_assets/<iconPath>（即 assets/logo/...，与打包一致）。
      await tray.trayManager.setIcon(_iconPath, isTemplate: true);
      await tray.trayManager.setToolTip('创作台');
      final menu = _buildMenu();
      _menu = menu;
      await tray.trayManager.setContextMenu(menu);

      final listener = _SystemTrayEventListener(this);
      _trayListener = listener;
      tray.trayManager.addListener(listener);

      await windowManager.setPreventClose(true);
      windowManager.addListener(_WindowCloseListener());

      _initialized = true;
      _log.info('System tray initialized');
    } catch (error, stackTrace) {
      _disposeTray();
      _log.warning('Failed to initialize system tray: $error\n$stackTrace');
    }
  }

  tray.Menu _buildMenu() {
    return tray.Menu(
      items: [
        tray.MenuItem(
          label: '新建小说',
          onClick: (_) => unawaited(_newNovel()),
        ),
        tray.MenuItem(
          label: '关于 Reveric',
          onClick: (_) => unawaited(_about()),
        ),
        tray.MenuItem.separator(),
        tray.MenuItem(
          label: '隐藏',
          onClick: (_) => unawaited(_hideWindow()),
        ),
        tray.MenuItem(
          label: '显示',
          onClick: (_) => unawaited(showMainWindow()),
        ),
        tray.MenuItem.separator(),
        tray.MenuItem(
          label: '退出',
          onClick: (_) => unawaited(_quit()),
        ),
      ],
    );
  }

  void _disposeTray() {
    final listener = _trayListener;
    if (listener != null) {
      tray.trayManager.removeListener(listener);
    }
    _trayListener = null;
    _menu = null;
    // 0.5.3 的 destroy() 走 MethodChannel（异步等待原生回包）。
    // 进程退出时 OS 会回收托盘图标，无需阻塞退出流程；若原生回包
    // 拖慢甚至停止宿主消息循环，await 会让 exit 卡住（0.8.x 亦为此
    // 注释过"无需等待 channel 回包"）。故 fire-and-forget。
    unawaited(tray.trayManager.destroy().catchError((Object _) {}));
  }

  /// 唤起主窗口：托盘点击、托盘菜单与第二实例激活请求共用。
  Future<void> showMainWindow() async {
    _log.checkpoint('showing main window (native)');
    await windowManager.show();
    await windowManager.focus();
    final visible = await windowManager.isVisible();
    final minimized = await windowManager.isMinimized();
    _log.checkpoint(
      'main window activation result visible=$visible minimized=$minimized',
    );
    if (!visible || minimized) {
      throw StateError('Window did not become visible after activation');
    }
    _log.checkpoint('main window activation verified (native)');
  }

  Future<void> _hideWindow() async {
    _log.checkpoint('hiding main window (native)');
    await windowManager.hide();
  }

  Future<void> _newNovel() async {
    await showMainWindow();
    final context = navigatorKey.currentState?.context;
    if (context == null || !context.mounted) {
      return;
    }
    showRevericDialog(
      context: context,
      builder: (ctx) => DialogFeedback.scope(
        builder: (ctx) => NovelFormDialog.create(
          onSubmit:
              ({
                required String title,
                required String authorName,
                required String description,
                required String category,
                required String type,
                required String contentKind,
                required int? plannedEpisodeCount,
                required String? sourceNovelId,
                required String? coverSourcePath,
                required bool removeCover,
                required List<String> tags,
              }) async {
                final container = ProviderScope.containerOf(ctx);
                final actions = container.read(novelActionsProvider);
                try {
                  final novelId = await actions.createNovel(
                    title: title,
                    authorName: authorName,
                    description: description,
                    category: category,
                    type: type,
                    contentKind: contentKind,
                    plannedEpisodeCount: plannedEpisodeCount,
                    sourceNovelId: sourceNovelId,
                    coverSourcePath: coverSourcePath,
                    tags: tags,
                  );
                  if (!ctx.mounted) return false;
                  final navigator = Navigator.of(ctx);
                  Navigator.of(ctx, rootNavigator: true).pop();
                  navigator.push(
                    MaterialPageRoute(
                      builder: (_) => WorkspaceEditorPage(novelId: novelId),
                    ),
                  );
                  return true;
                } catch (e) {
                  if (!ctx.mounted) return false;
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(const SnackBar(content: Text('创建小说失败')));
                  return false;
                }
              },
        ),
      ),
    );
  }

  Future<void> _about() async {
    await showMainWindow();
    final context = navigatorKey.currentState?.context;
    if (context == null || !context.mounted) {
      return;
    }
    showRevericDialog(
      context: context,
      builder: (ctx) {
        return RevericDialog(
          title: '创作台',
          content: Text('版本 1.0.0\nAI 辅助写作工具'),
          actions: [
            RevericButton.secondary(
              label: '关闭',
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        );
      },
    );
  }

  Future<void> _quit() async {
    var phase = 'activate_window';
    _log.checkpoint('tray quit selected');
    try {
      await showMainWindow();

      final ctx = navigatorKey.currentState?.context;
      if (ctx == null || !ctx.mounted) {
        phase = 'exit_without_navigator';
        _log.checkpoint('tray quit without mounted navigator');
        await _exitApplication();
        return;
      }

      phase = 'confirm_exit';
      _log.checkpoint('tray quit opening confirmation');
      final confirmed = await showConfirmDialog(
        ctx,
        title: '确认退出',
        message: '确定要退出吗？',
        confirmLabel: '退出',
        cancelLabel: '取消',
        variant: ConfirmDialogVariant.warning,
      );
      _log.checkpoint('tray quit confirmation result=$confirmed');

      if (confirmed == true) {
        phase = 'exit_application';
        await _exitApplication();
      }
    } catch (error, stackTrace) {
      _log.error(
        'Tray quit failed phase=$phase',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _exitApplication({
    void Function(int)? terminate,
    FutureOr<void> Function()? unlock,
    Future<void> Function()? cleanExit,
    StartupFailureReporter? failureReporter,
  }) async {
    final guards = List<Future<bool> Function()>.of(_exitGuards.reversed);
    for (var index = 0; index < guards.length; index++) {
      _log.checkpoint(
        'tray exit guard started index=$index count=${guards.length}',
      );
      final allowed = await guards[index]();
      _log.checkpoint(
        'tray exit guard completed index=$index allowed=$allowed',
      );
      if (!allowed) {
        return;
      }
    }
    _log.info('[EXIT] requested');
    _log.checkpoint('application exit requested (tray)');
    CrashSentinel.markActiveExitProgressSync(
      source: 'tray',
      phase: 'requested',
    );
    await windowManager.setPreventClose(false);

    // Close content databases first. Their normal close path can wait for
    // paused query streams; the process-exit path bypasses those listeners.
    CrashSentinel.markActiveExitProgressSync(
      source: 'tray',
      phase: 'closing_content_databases',
    );
    _log.info('[EXIT] closing content databases');
    try {
      await NovelContentDatabase.closeAllCachedForProcessExit();
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=novel_content_databases operation=CLOSE_ALL '
        'error=$error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    _log.info('[EXIT] content databases closed');

    // Close databases before terminating to prevent NativeFinalizer SIGSEGV
    // during Dart isolate shutdown. The process-exit variant bypasses paused
    // Drift stream listeners while still awaiting the SQLite executor.
    CrashSentinel.markActiveExitProgressSync(
      source: 'tray',
      phase: 'closing_app_database',
    );
    _log.info('[EXIT] closing app database');
    try {
      await AppDatabase.closeCachedForProcessExit();
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=app_database operation=CLOSE_FOR_PROCESS_EXIT '
        'error=$error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    _log.info('[EXIT] app database closed');

    // 正常退出：只清除当前会话 marker，待重试崩溃证据由 CrashSentinel 保留。
    // 必须在释放单实例锁之前完成，避免新进程看到旧 marker 或被旧进程删除。
    if (cleanExit != null) {
      await cleanExit();
    } else {
      CrashSentinel.markActiveSessionCleanExitSync();
    }
    // await 锁释放：确保激活 server 关闭、端口文件删除后再退出，
    // 避免残留端口文件误导下一次启动的第二实例。
    try {
      await Future<void>.sync(
        unlock ?? SingleInstanceService.unlock,
      ).timeout(const Duration(seconds: 3));
    } catch (error, stack) {
      _log.error(
        'Tray exit instance cleanup failed',
        error: error,
        stackTrace: stack,
      );
      try {
        await (failureReporter ?? StartupFailureReporter())
            .reportLifecycleFailure(
              phase: 'tray_exit',
              reason: error is TimeoutException
                  ? 'release_instance_timeout'
                  : 'release_instance_failed',
              error: error,
              stackTrace: stack,
            )
            .timeout(const Duration(seconds: 5));
      } catch (reportError) {
        _log.warning('Tray exit report did not finish: $reportError');
      }
    }

    _log.info('[EXIT] destroying tray');
    try {
      _disposeTray();
    } catch (error, stackTrace) {
      _log.warning('tray dispose failed error=$error\n$stackTrace');
    }
    // close() only posts the native close request. Awaiting its MethodChannel
    // reply can strand exit if native window teardown stops the host loop.
    unawaited(
      windowManager.close().catchError((error, stackTrace) {
        _log.warning('window close request failed error=$error\n$stackTrace');
      }),
    );
    _log.info('[EXIT] terminating');
    (terminate ?? exit)(0);
  }

  @visibleForTesting
  Future<void> exitApplicationForTesting(
    void Function(int) terminate, {
    FutureOr<void> Function()? unlock,
    Future<void> Function()? cleanExit,
    StartupFailureReporter? failureReporter,
  }) {
    return _exitApplication(
      terminate: terminate,
      unlock: unlock,
      cleanExit: cleanExit,
      failureReporter: failureReporter,
    );
  }
}

/// 0.5.3 的事件监听：左键单击托盘图标唤起主窗口。
/// 菜单项动作由 [MenuItem.onClick] 直接绑定（无需 onTrayMenuItemClick）。
class _SystemTrayEventListener with tray.TrayListener {
  _SystemTrayEventListener(this._service);

  final SystemTrayService _service;

  @override
  void onTrayIconMouseDown() {
    unawaited(_service.showMainWindow());
  }
}

class _WindowCloseListener extends WindowListener {
  @override
  void onWindowClose() {
    // 区分"关窗最小化到托盘"与真正退出：关窗不退出进程，不应清除崩溃哨兵。
    _log.checkpoint('main window close intercepted; hiding to tray');
    Future.microtask(() async {
      await windowManager.hide();
    });
  }
}
