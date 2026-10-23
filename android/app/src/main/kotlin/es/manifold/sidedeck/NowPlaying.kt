package es.manifold.sidedeck

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * "Now playing" controls at the top of the phone (notification shade and lock
 * screen): X (swap this track), play/pause and next. Presses go back to Dart.
 */
class NowPlaying(private val ctx: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "beatdeck/nowplaying")
    private val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val session = MediaSession(ctx, "BeatDeck")
    private val chanId = "beatdeck_now_playing"
    private val notifId = 4711
    private var shown = false
    private var art: android.graphics.Bitmap? = null
    private var lastTitle = ""
    private var lastArtist = ""
    private var lastPlaying = true

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val a = i?.action ?: return
            channel.invokeMethod("action", a.removePrefix("es.manifold.sidedeck.NP_"))
        }
    }

    init {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(chanId, "Now playing", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        val f = IntentFilter()
        for (n in listOf("PLAY", "PAUSE", "NEXT", "SWAP")) f.addAction("es.manifold.sidedeck.NP_$n")
        if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(receiver, f, Context.RECEIVER_NOT_EXPORTED)
        else ctx.registerReceiver(receiver, f)
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() { channel.invokeMethod("action", "PLAY") }
            override fun onPause() { channel.invokeMethod("action", "PAUSE") }
            override fun onSkipToNext() { channel.invokeMethod("action", "NEXT") }
        })
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    update(
                        call.argument<String>("title") ?: "",
                        call.argument<String>("artist") ?: "",
                        call.argument<Boolean>("playing") ?: true,
                    )
                    result.success(null)
                }
                "art" -> {
                    val bytes = call.arguments as? ByteArray
                    if (bytes != null && shown) {
                        art = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: art
                        update(lastTitle, lastArtist, lastPlaying)
                    }
                    result.success(null)
                }
                "hide" -> { hide(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun pi(name: String): PendingIntent =
        PendingIntent.getBroadcast(
            ctx, name.hashCode(),
            Intent("es.manifold.sidedeck.NP_$name").setPackage(ctx.packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun update(title: String, artist: String, playing: Boolean) {
        lastTitle = title
        lastArtist = artist
        lastPlaying = playing
        val md = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
        art?.let {
            md.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it)
            md.putBitmap(MediaMetadata.METADATA_KEY_ART, it)
        }
        session.setMetadata(md.build())
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT)
                .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, 0L, 1f)
                .build(),
        )
        session.isActive = true
        val open = PendingIntent.getActivity(
            ctx, 0, ctx.packageManager.getLaunchIntentForPackage(ctx.packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, chanId) else Notification.Builder(ctx)
        b.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(if (title.isEmpty()) "BeatDeck" else title)
            .setContentText(artist.ifEmpty { "Now playing" })
            .setContentIntent(open)
            .apply { art?.let { setLargeIcon(it) } }
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "Swap this track", pi("SWAP")).build())
            .addAction(
                if (playing) Notification.Action.Builder(android.R.drawable.ic_media_pause, "Pause", pi("PAUSE")).build()
                else Notification.Action.Builder(android.R.drawable.ic_media_play, "Play", pi("PLAY")).build(),
            )
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_next, "Next", pi("NEXT")).build())
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1, 2))
        try {
            nm.notify(notifId, b.build())
            shown = true
        } catch (_: Exception) {}
    }

    private fun hide() {
        if (shown) nm.cancel(notifId)
        shown = false
        art = null
        session.isActive = false
    }

    fun release() {
        hide()
        try { ctx.unregisterReceiver(receiver) } catch (_: Exception) {}
        session.release()
    }
}
