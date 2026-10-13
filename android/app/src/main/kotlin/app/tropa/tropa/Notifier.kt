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

    private fun manager(c: Context) = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun builder(c: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, channel) else Notification.Builder(c)

    private fun openApp(c: Context, requestCode: Int): PendingIntent =
        PendingIntent.getActivity(
            c, requestCode, Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

    fun ensureChannels(c: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = manager(c)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, Tr.t(c, "Запись маршрута"), NotificationManager.IMPORTANCE_LOW)
        )
        nm.createNotificationChannel(
            NotificationChannel(ALERT_CHANNEL_ID, Tr.t(c, "Тревоги и напоминания"), NotificationManager.IMPORTANCE_HIGH).apply {
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
            }
        )
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

    fun postAlert(c: Context, id: Int, title: String, text: String, icon: String = "⚠️") {
        val n = builder(c, ALERT_CHANNEL_ID).setContentTitle("$icon $title")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_tropa)
            .setContentIntent(openApp(c, 1))
            .setAutoCancel(true)
            .build()
        manager(c).notify(id, n)
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
