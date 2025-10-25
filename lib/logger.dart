import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

enum LogLevel { debug, info, warn, error }

class Logger {
  static String _getCallerInfo() {
    try {
      final stack = StackTrace.current.toString();
      final lines = stack.split('\n');

      // Skip first 3 lines: current, _getCallerInfo, log/debug/info/warn/error method
      if (lines.length > 3) {
        final callerLine = lines[3];

        // Extract file:line from stack trace
        // Format: "#3      ClassName.methodName (package:app/file.dart:123:45)"
        final match = RegExp(r'\(([^:]+):(\d+):\d+\)').firstMatch(callerLine);
        if (match != null) {
          final fullPath = match.group(1) ?? '';
          final line = match.group(2) ?? '?';

          // Extract just filename from package path
          final filename = fullPath.split('/').last;

          return '$filename:$line';
        }
      }
    } catch (e) {
      // Silently fail if stack trace parsing fails
    }

    return 'unknown';
  }

  static String _formatTimestamp() {
    return DateTime.now().toUtc().toIso8601String();
  }

  static String _formatContext(Map<String, dynamic>? context) {
    if (context == null || context.isEmpty) return '';

    final entries = context.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    return '{$entries}';
  }

  static void _log(LogLevel level, String message, {Map<String, dynamic>? context}) {
    final timestamp = _formatTimestamp();
    final caller = _getCallerInfo();
    final contextStr = _formatContext(context);

    final logLine = contextStr.isNotEmpty
        ? '[$timestamp] [${level.name.toUpperCase()}] [$caller] $message $contextStr'
        : '[$timestamp] [${level.name.toUpperCase()}] [$caller] $message';

    // Send to Sentry
    switch (level) {
      case LogLevel.debug:
        Sentry.logger.debug(logLine);
        break;
      case LogLevel.info:
        Sentry.logger.info(logLine);
        break;
      case LogLevel.warn:
        Sentry.logger.warn(logLine);
        break;
      case LogLevel.error:
        Sentry.logger.error(logLine);
        break;
    }

    // Print to console in debug mode
    if (kDebugMode) {
      // ignore: avoid_print
      print(logLine);
    }
  }

  static void debug(String message, {Map<String, dynamic>? context}) {
    _log(LogLevel.debug, message, context: context);
  }

  static void info(String message, {Map<String, dynamic>? context}) {
    _log(LogLevel.info, message, context: context);
  }

  static void warn(String message, {Map<String, dynamic>? context}) {
    _log(LogLevel.warn, message, context: context);
  }

  static void error(String message, {Map<String, dynamic>? context, Object? error, StackTrace? stackTrace}) {
    _log(LogLevel.error, message, context: context);

    if (error != null) {
      Sentry.captureException(error, stackTrace: stackTrace);
      if (kDebugMode) {
        // ignore: avoid_print
        print('Error: $error');
        if (stackTrace != null) {
          // ignore: avoid_print
          print('StackTrace: $stackTrace');
        }
      }
    }
  }
}
