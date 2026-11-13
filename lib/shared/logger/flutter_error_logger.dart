// 职责: Flutter 错误日志桥接 — 保留框架默认错误展示，并同步写入 AppLogger。
// 关联文件:
//   lib/main.dart
//   lib/shared/logger/app_logger.dart
//   lib/shared/logger/startup_failure_reporter.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_logger.dart';

final _log = AppLogger.forModule('FlutterError');

typedef FlutterErrorLogSink =
    void Function(String message, {Object? error, StackTrace? stackTrace});
typedef FlutterErrorReportSink =
    Future<void> Function(Object error, StackTrace stackTrace);

void installFlutterErrorLogger({
  FlutterExceptionHandler? presentErrorOverride,
  FlutterErrorLogSink? logErrorOverride,
  FlutterErrorReportSink? reportErrorOverride,
}) {
  FlutterError.onError = (details) {
    (presentErrorOverride ?? FlutterError.presentError)(details);
    (logErrorOverride ?? _log.error)(
      details.exceptionAsString(),
      error: details.exception,
      stackTrace: details.stack,
    );
    if (reportErrorOverride != null) {
      unawaited(
        reportErrorOverride(
          details.exception,
          details.stack ?? StackTrace.current,
        ),
      );
    }
  };
}
