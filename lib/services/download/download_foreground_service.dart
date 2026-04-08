import 'dart:io' show Platform;

import 'package:PiliPlus/utils/utils.dart';

abstract final class DownloadForegroundService {
  static const _notifyIntervalMs = 2000;
  static int _lastNotifyTime = 0;

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await Utils.channel.invokeMethod('startDownloadService');
    } catch (_) {}
  }

  static void updateProgress({
    required String title,
    required int progress,
    required int total,
    bool force = false,
  }) {
    if (!Platform.isAndroid) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastNotifyTime < _notifyIntervalMs) return;
    _lastNotifyTime = now;
    _invokeUpdateProgress(title: title, progress: progress, total: total);
  }

  static Future<void> stop({
    String? title,
    int? progress,
    int? total,
  }) async {
    if (!Platform.isAndroid) return;
    if (title != null && progress != null && total != null) {
      await _invokeUpdateProgress(
        title: title,
        progress: progress,
        total: total,
      );
    }
    _lastNotifyTime = 0;
    try {
      await Utils.channel.invokeMethod('stopDownloadService');
    } catch (_) {}
  }

  static Future<void> _invokeUpdateProgress({
    required String title,
    required int progress,
    required int total,
  }) async {
    try {
      await Utils.channel.invokeMethod('updateDownloadProgress', {
        'title': title,
        'progress': progress,
        'total': total,
      });
    } catch (_) {}
  }
}
