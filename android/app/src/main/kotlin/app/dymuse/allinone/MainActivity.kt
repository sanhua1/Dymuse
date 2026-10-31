package app.dymuse.allinone

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// 与 Dart 端 `NowPlaying` 共用 dymuse/now_playing 通道：update 把当前歌曲交给前台服务，
/// 媒体键与通知按钮的命令由服务经同一通道发回。
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dymuse/now_playing")
        NowPlayingBridge.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    NowPlayingBridge.update(applicationContext, call.arguments as? Map<*, *>)
                    result.success(null)
                }
                // 返回键在根页面时只把应用放到后台；结束 Activity 会连同音乐一起停掉。
                "moveToBack" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        NowPlayingBridge.channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
