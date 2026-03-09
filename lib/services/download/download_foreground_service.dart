import 'dart:io' show Platform;

import 'package:PiliPlus/utils/utils.dart';

abstract final class DownloadForegroundService {
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
  }) {
    if (!Platform.isAndroid) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyTime < 2000) return;
    _lastNotifyTime = now;
    Utils.channel.invokeMethod('updateDownloadProgress', {
      'title': title,
      'progress': progress,
      'total': total,
    });
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _lastNotifyTime = 0;
    try {
      await Utils.channel.invokeMethod('stopDownloadService');
    } catch (_) {}
  }
}
