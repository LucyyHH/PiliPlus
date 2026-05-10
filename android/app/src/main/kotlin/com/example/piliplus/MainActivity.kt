package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "PiliPlus")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startDownloadService" -> {
                        val intent = Intent(this, DownloadForegroundService::class.java).apply {
                            action = DownloadForegroundService.ACTION_START
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }

                    "updateDownloadProgress" -> {
                        val intent = Intent(this, DownloadForegroundService::class.java).apply {
                            action = DownloadForegroundService.ACTION_UPDATE
                            putExtra(
                                DownloadForegroundService.EXTRA_TITLE,
                                call.argument<String>("title") ?: "正在下载..."
                            )
                            putExtra(
                                DownloadForegroundService.EXTRA_PROGRESS,
                                (call.argument<Number>("progress") ?: 0).toLong()
                            )
                            putExtra(
                                DownloadForegroundService.EXTRA_TOTAL,
                                (call.argument<Number>("total") ?: 0).toLong()
                            )
                        }
                        startService(intent)
                        result.success(null)
                    }

                    "stopDownloadService" -> {
                        if (DownloadForegroundService.isRunning) {
                            val intent = Intent(this, DownloadForegroundService::class.java).apply {
                                action = DownloadForegroundService.ACTION_STOP
                            }
                            startService(intent)
                        }
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
