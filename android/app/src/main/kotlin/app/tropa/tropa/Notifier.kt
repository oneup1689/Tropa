package app.tropa.tropa

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/** Notification channels, the ongoing "recording" notification and the loud alerts. */
object Notifier {
    const val ALERT_CHANNEL_ID = "tropa_alert"
    private const val CHANNEL_ID = "tropa_tracking"
    const val NOTIFICATION_ID = 1001
    const val ALERT_ID = 1002
    const val ROUTE_ALERT_ID = 1003
    const val GOAL_ID = 1004
    const val MODE_HINT_ID = 1005

    private fun manager(c: Context) = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun builder(c: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, channel) else Notification.Builder(c)

    private fun openApp(c: Context, requestCode: Int): PendingIntent =
        PendingIntent.getActivity(
            c, requestCode, Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

    /** One channel per kind of event: its own sound and vibration (a channel's sound cannot change later). */
    private class Kind(val key: String, val title: String, val sound: String, val vibration: LongArray?, val importance: Int)

    private val kinds = listOf(
        Kind("gps", "GPS и разрешения", "gps_off", longArrayOf(0, 600, 300, 600, 300, 600), NotificationManager.IMPORTANCE_HIGH),
        Kind("route", "Сход с маршрута", "offroute", longArrayOf(0, 400, 200, 400), NotificationManager.IMPORTANCE_HIGH),
        Kind("goal", "Цель достигнута", "goal", longArrayOf(0, 200, 100, 200, 100, 400), NotificationManager.IMPORTANCE_HIGH),
        Kind("half", "Половина пути", "half", longArrayOf(0, 150, 100, 150), NotificationManager.IMPORTANCE_HIGH),
        Kind("hint", "Подсказки", "hint", null, NotificationManager.IMPORTANCE_DEFAULT),
    )
    private val modes = listOf("both", "sound", "vibe", "silent")

    /** Channel of a kind for the current "sound and vibration" mode; the mode is part of the id. */
    private fun channelId(c: Context, key: String) = "tropa_${key}_${Sounds.mode(c)}"

    fun ensureChannels(c: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = manager(c)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, Tr.t(c, "Запись маршрута"), NotificationManager.IMPORTANCE_LOW)
        )
        // Planner reminders keep the system default sound.
        nm.createNotificationChannel(
            NotificationChannel(ALERT_CHANNEL_ID, Tr.t(c, "Тревоги и напоминания"), NotificationManager.IMPORTANCE_HIGH).apply {
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
            }
        )
        val current = Sounds.mode(c)
        val attrs = android.media.AudioAttributes.Builder()
            .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        for (k in kinds) {
            for (m in modes) if (m != current) nm.deleteNotificationChannel("tropa_${k.key}_$m")
            val ch = NotificationChannel(channelId(c, k.key), Tr.t(c, k.title), k.importance)
            if (Sounds.soundOn(c)) {
                val res = c.resources.getIdentifier("snd_${k.sound}", "raw", c.packageName)
                ch.setSound(android.net.Uri.parse("android.resource://${c.packageName}/$res"), attrs)
            } else {
                ch.setSound(null, null)
            }
            if (Sounds.vibrationOn(c) && k.vibration != null) {
                ch.enableVibration(true)
                ch.vibrationPattern = k.vibration
            } else {
                ch.enableVibration(false)
            }
            nm.createNotificationChannel(ch)
        }
    }

    /** The permanent notification a foreground service must show. */
    fun ongoing(c: Context, text: String): Notification =
        builder(c, CHANNEL_ID).setContentTitle("Tropa")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_tropa)
            .setOngoing(true)
            .setContentIntent(openApp(c, 0))
            .build()

    fun updateOngoing(c: Context, text: String) = manager(c).notify(NOTIFICATION_ID, ongoing(c, text))

    fun postAlert(c: Context, id: Int, title: String, text: String, icon: String = "⚠️", kind: String = "gps") {
        val n = builder(c, channelId(c, kind)).setContentTitle("$icon $title")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_tropa)
            .setContentIntent(openApp(c, 1))
            .setAutoCancel(true)
            .build()
        manager(c).notify(id, n)
    }

    /** Suggestion with one action button: a soft "ping", it is a question, not an alarm. */
    fun postModeHint(c: Context, title: String, text: String, actionLabel: String, action: PendingIntent) {
        val b = builder(c, channelId(c, "hint")).setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_tropa)
            .setContentIntent(openApp(c, 2))
            .setAutoCancel(true)
            .addAction(Notification.Action.Builder(null, actionLabel, action).build())
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(10 * 60_000L)
        manager(c).notify(MODE_HINT_ID, b.build())
    }

    fun cancel(c: Context, id: Int) = manager(c).cancel(id)

    /** Replaces the GPS-off alert with a short "recording resumed" note that disappears by itself. */
    fun showResumed(c: Context) {
        val nm = manager(c)
        nm.cancel(ALERT_ID)
        val b = builder(c, CHANNEL_ID)
            .setContentTitle(Tr.t(c, "Запись возобновлена"))
            .setSmallIcon(R.drawable.ic_stat_tropa)
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(15_000)
        nm.notify(ALERT_ID, b.build())
    }
}
