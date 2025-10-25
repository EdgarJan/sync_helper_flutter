import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

enum LogLevel { debug, info, warn, error }

class Logger {
  static _CallerInfo? _getCallerInfo() {
    try {
      final trace = StackTrace.current.toString();
      final lines = trace.split('\n');

      // Skip the first few lines (this class's methods)
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];

        // Skip lines from this logger class
        if (line.contains('logger.dart')) continue;

        // Skip Flutter framework lines
        if (line.contains('package:flutter/')) continue;

        // Parse the line to extract file and line number
        // Format: #N      method (package:app/file.dart:line:column)
        final match = RegExp(r'\((.+?):(\d+):\d+\)').firstMatch(line);
        if (match != null) {
          String filePath = match.group(1)!;
          final lineNumber = match.group(2)!;

          // Extract just the filename from the path
          if (filePath.contains('/')) {
            filePath = filePath.split('/').last;
          }

          return _CallerInfo(filePath, lineNumber);
        }
      }
    } catch (e) {
      // Silently fail if we can't get caller info
    }
    return null;
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
    final callerInfo = _getCallerInfo();
    final contextStr = _formatContext(context);

    final buffer = StringBuffer();
    buffer.write('[$timestamp] [${level.name.toUpperCase()}] ');

    // Add file and line info if available
    if (callerInfo != null) {
      buffer.write('[${callerInfo.file}:${callerInfo.line}] ');
    }

    buffer.write(message);

    if (contextStr.isNotEmpty) {
      buffer.write(' $contextStr');
    }

    final logLine = buffer.toString();

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

/// Helper class to store caller information
class _CallerInfo {
  final String file;
  final String line;

  _CallerInfo(this.file, this.line);
}
