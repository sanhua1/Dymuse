package app.dymuse.allinone

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
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
        // 应用内更新：Dart 下载并校验好安装包后，用系统安装器安装。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dymuse/update")
            .setMethodCallHandler { call, result ->
                if (call.method == "install") {
                    result.success(installApk(call.arguments as? String))
                } else {
                    result.notImplemented()
                }
            }
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

    /// 返回 "started"（已唤起安装器）、"needPermission"（已打开系统授权页）或以 "failed" 开头的失败原因。
    private fun installApk(path: String?): String {
        if (path == null) return "failed"
        if (!packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
            )
            return "needPermission"
        }
        return try {
            // 复制进 FileProvider 共享的缓存目录再交给安装器，不依赖 Dart 把文件下载到了哪里。
            val source = File(path)
            val shared = File(File(cacheDir, "updates").apply { mkdirs() }, "update.apk")
            source.copyTo(shared, overwrite = true)
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", shared)
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            )
            "started"
        } catch (e: Exception) {
            "failed: ${e.javaClass.simpleName} ${e.message}"
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        NowPlayingBridge.channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
