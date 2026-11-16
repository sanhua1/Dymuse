package app.dymuse.allinone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL

/// Dart 端当前播放的歌曲；封面是公开的 https 图片，由服务自己下载。
data class NowPlayingState(
    val title: String,
    val artist: String,
    val album: String,
    val durationMs: Long,
    val positionMs: Long,
    val playing: Boolean,
    /// 切歌装载中、马上要继续播放（自动连播的间隙）。
    val loading: Boolean,
    val artwork: String?,
) {
    /// 正在播放或正要播放：保持唤醒，媒体会话不显示为暂停。
    val active get() = playing || loading
}

object NowPlayingBridge {
    @Volatile var channel: MethodChannel? = null
    @Volatile var state: NowPlayingState? = null
    private val main = Handler(Looper.getMainLooper())

    fun update(context: Context, args: Map<*, *>?) {
        if (args == null) {
            state = null
            MediaPlaybackService.instance?.stopPlayback()
            return
        }
        state = NowPlayingState(
            title = args["title"] as? String ?: "",
            artist = args["artist"] as? String ?: "",
            album = args["album"] as? String ?: "",
            durationMs = (args["durationMs"] as? Number)?.toLong() ?: 0L,
            positionMs = (args["positionMs"] as? Number)?.toLong() ?: 0L,
            playing = args["playing"] as? Boolean ?: false,
            loading = args["loading"] as? Boolean ?: false,
            artwork = args["artwork"] as? String,
        )
        val running = MediaPlaybackService.instance
        if (running != null) {
            running.refresh()
            return
        }
        // 只有应用在前台时才允许启动前台服务；后台里被拒绝就先不显示通知。
        try {
            val intent = Intent(context, MediaPlaybackService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
        } catch (_: Exception) {
        }
    }

    fun send(method: String, argument: Any? = null) {
        main.post { channel?.invokeMethod(method, argument) }
    }
}

class MediaPlaybackService : Service() {
    companion object {
        @Volatile var instance: MediaPlaybackService? = null
        private const val CHANNEL_ID = "dymuse_playback"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_PREVIOUS = "app.dymuse.allinone.PREVIOUS"
        private const val ACTION_TOGGLE = "app.dymuse.allinone.TOGGLE"
        private const val ACTION_NEXT = "app.dymuse.allinone.NEXT"
    }

    private lateinit var session: MediaSession
    private val main = Handler(Looper.getMainLooper())
    private var artworkUrl: String? = null
    private var artwork: Bitmap? = null

    /// 播放和切歌期间持有。正在出声时系统音频会让 CPU 保持清醒，但自动连播切歌的
    /// 几百毫秒里没有声音，锁屏后 CPU 与 Wi-Fi 可能随即休眠：读缓存的本机代理停住、
    /// 网络取流超时，下一首要等亮屏才开始或直接报“音频无法播放”。
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        wakeLock = getSystemService(PowerManager::class.java)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Dymuse:playback")
            ?.apply { setReferenceCounted(false) }
        @Suppress("DEPRECATION")
        wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
            ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Dymuse:playback")
            ?.apply { setReferenceCounted(false) }
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "正在播放", NotificationManager.IMPORTANCE_LOW).apply {
                    setShowBadge(false)
                }
            )
        }
        session = MediaSession(this, "Dymuse").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = NowPlayingBridge.send("play")
                override fun onPause() = NowPlayingBridge.send("pause")
                override fun onSkipToNext() = NowPlayingBridge.send("next")
                override fun onSkipToPrevious() = NowPlayingBridge.send("previous")
                override fun onSeekTo(pos: Long) = NowPlayingBridge.send("seek", pos)
                override fun onStop() = NowPlayingBridge.send("pause")
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PREVIOUS -> NowPlayingBridge.send("previous")
            ACTION_TOGGLE -> NowPlayingBridge.send("toggle")
            ACTION_NEXT -> NowPlayingBridge.send("next")
        }
        refresh()
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /// 从最近任务划掉应用后 Flutter 引擎随之销毁，没有人能响应通知按钮，直接收起通知。
    override fun onTaskRemoved(rootIntent: Intent?) {
        NowPlayingBridge.state = null
        stopPlayback()
    }

    override fun onDestroy() {
        instance = null
        hold(false)
        session.release()
        super.onDestroy()
    }

    fun stopPlayback() {
        main.post {
            hold(false)
            stopForeground(true)
            session.isActive = false
            stopSelf()
        }
    }

    fun refresh() {
        main.post { apply() }
    }

    private fun apply() {
        val state = NowPlayingBridge.state
        if (state == null) {
            stopPlayback()
            return
        }
        if (state.artwork != artworkUrl) {
            artworkUrl = state.artwork
            artwork = null
            loadArtwork(state.artwork)
        }
        hold(state.active)
        session.isActive = true
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, state.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, state.artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, state.album)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, state.durationMs)
                .apply { artwork?.let { putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) } }
                .build()
        )
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SEEK_TO or
                        PlaybackState.ACTION_STOP
                )
                .setState(
                    when {
                        state.playing -> PlaybackState.STATE_PLAYING
                        state.loading -> PlaybackState.STATE_BUFFERING
                        else -> PlaybackState.STATE_PAUSED
                    },
                    state.positionMs,
                    if (state.playing) 1f else 0f,
                )
                .build()
        )
        val notification = notification(state)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // 后台里不允许新启动的前台服务；会话仍然有效，锁屏与耳机按键照常工作。
        }
    }

    /// 取得或释放唤醒锁与 Wi-Fi 锁；用户暂停、停止或出错停下时释放，不额外耗电。
    private fun hold(active: Boolean) {
        try {
            if (active) {
                if (wakeLock?.isHeld == false) wakeLock?.acquire()
                if (wifiLock?.isHeld == false) wifiLock?.acquire()
            } else {
                if (wakeLock?.isHeld == true) wakeLock?.release()
                if (wifiLock?.isHeld == true) wifiLock?.release()
            }
        } catch (_: Exception) {
        }
    }

    private fun action(icon: Int, title: String, action: String, code: Int): Notification.Action {
        val intent = Intent(this, MediaPlaybackService::class.java).setAction(action)
        val pending = PendingIntent.getService(
            this, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Action.Builder(Icon.createWithResource(this, icon), title, pending).build()
    }

    private fun notification(state: NowPlayingState): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(state.title)
            .setContentText(state.artist)
            .setSubText(state.album.ifEmpty { null })
            .setLargeIcon(artwork)
            .setContentIntent(open)
            .setOngoing(state.active)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(action(android.R.drawable.ic_media_previous, "上一首", ACTION_PREVIOUS, 1))
            .addAction(
                if (state.active) action(android.R.drawable.ic_media_pause, "暂停", ACTION_TOGGLE, 2)
                else action(android.R.drawable.ic_media_play, "播放", ACTION_TOGGLE, 2)
            )
            .addAction(action(android.R.drawable.ic_media_next, "下一首", ACTION_NEXT, 3))
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .build()
    }

    /// 在后台线程下载封面并缩小；下载期间歌曲已变就丢弃。
    private fun loadArtwork(url: String?) {
        if (url == null) return
        Thread {
            val bitmap = try {
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.connectTimeout = 8000
                connection.readTimeout = 8000
                val bytes = connection.inputStream.use { it.readBytes() }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                var sample = 1
                while (bounds.outWidth / (sample * 2) >= 512) sample *= 2
                BitmapFactory.decodeByteArray(
                    bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }
                )
            } catch (_: Exception) {
                null
            }
            main.post {
                if (bitmap != null && artworkUrl == url) {
                    artwork = bitmap
                    apply()
                }
            }
        }.start()
    }
}
