import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

enum LogLevel { debug, info, warn, error }

class Logger {
  static String _getCallerInfo() {
    try {
      final stack = StackTrace.current.toString();
      final lines = stack.split('\n');

      // Pattern to match stack trace line with file location
      // Matches both: "(package:app/file.dart:123:45)" and "(file:///path/file.dart:123:45)"
      final pattern = RegExp(r'\(([^:]+):(\d+):\d+\)');

      // Skip lines until we find a caller that's not from logger.dart itself
      for (int i = 0; i < lines.length; i++) {
        final match = pattern.firstMatch(lines[i]);
        if (match != null) {
          final fullPath = match.group(1) ?? '';
          final line = match.group(2) ?? '?';

          // Extract just filename from package path or file path
          final filename = fullPath.split('/').last.split('\\').last;

          // Skip if this is the logger.dart file itself
          if (filename == 'logger.dart') {
            continue;
          }

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
