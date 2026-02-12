import 'dart:io' show Platform;

import 'package:PiliPlus/utils/utils.dart';

abstract final class DownloadForegroundService {
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await Utils.channel.invokeMethod('startDownloadService');
    } catch (_) {}
  }

  static Future<void> updateProgress({
    required String title,
    required int progress,
    required int total,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await Utils.channel.invokeMethod('updateDownloadProgress', {
        'title': title,
        'progress': progress,
        'total': total,
      });
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await Utils.channel.invokeMethod('stopDownloadService');
    } catch (_) {}
  }
}
