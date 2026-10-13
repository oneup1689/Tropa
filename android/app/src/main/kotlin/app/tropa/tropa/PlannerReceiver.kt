package app.tropa.tropa

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * Trip planner: an alarm shows a reminder and, if the user asked for it, starts the recording.
 * Plans are kept in SharedPreferences so they survive a reboot (see [BootReceiver]).
 */
class PlannerReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "app.tropa.tropa.PLANNER"
        private const val PREFS_PLAN = "tropa_planner"
        private const val KEY_PLANS = "plans"

        private fun load(ctx: Context): JSONArray =
            try {
                JSONArray(ctx.getSharedPreferences(PREFS_PLAN, Context.MODE_PRIVATE).getString(KEY_PLANS, "[]"))
            } catch (_: Exception) {
                JSONArray()
            }

        private fun save(ctx: Context, arr: JSONArray) {
            ctx.getSharedPreferences(PREFS_PLAN, Context.MODE_PRIVATE).edit().putString(KEY_PLANS, arr.toString()).apply()
        }

        private fun pending(ctx: Context, id: Int, extras: JSONObject?): PendingIntent {
            val i = Intent(ctx, PlannerReceiver::class.java).setAction(ACTION)
            if (extras != null) {
                i.putExtra("id", id)
                i.putExtra("title", extras.optString("title"))
                i.putExtra("autoStart", extras.optBoolean("autoStart"))
                i.putExtra("mode", extras.optString("mode", "mixed"))
            }
            return PendingIntent.getBroadcast(ctx, id, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        private fun setAlarm(ctx: Context, plan: JSONObject) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val id = plan.getInt("id")
            val at = plan.getLong("atMs")
            val pi = pending(ctx, id, plan)
            try {
                if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                } else {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                }
            } catch (e: SecurityException) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        }

        fun schedule(ctx: Context, id: Int, atMs: Long, title: String, autoStart: Boolean, mode: String) {
            val arr = load(ctx)
            val out = JSONArray()
            for (i in 0 until arr.length()) if (arr.getJSONObject(i).optInt("id") != id) out.put(arr.getJSONObject(i))
            val plan = JSONObject()
                .put("id", id).put("atMs", atMs).put("title", title).put("autoStart", autoStart).put("mode", mode)
            out.put(plan)
            save(ctx, out)
            setAlarm(ctx, plan)
            TrackingService.log(ctx, "PLAN", "scheduled #$id at $atMs autoStart=$autoStart mode=$mode")
        }

        fun cancel(ctx: Context, id: Int) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(pending(ctx, id, null))
            val arr = load(ctx)
            val out = JSONArray()
            for (i in 0 until arr.length()) if (arr.getJSONObject(i).optInt("id") != id) out.put(arr.getJSONObject(i))
            save(ctx, out)
        }

        fun rescheduleAll(ctx: Context) {
            val arr = load(ctx)
            val now = System.currentTimeMillis()
            for (i in 0 until arr.length()) {
                val p = arr.getJSONObject(i)
                if (p.optLong("atMs") > now) setAlarm(ctx, p)
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val id = intent.getIntExtra("id", 0)
        val title = intent.getStringExtra("title")?.takeIf { it.isNotBlank() } ?: Tr.t(context, "Запланированная прогулка")
        val auto = intent.getBooleanExtra("autoStart", false)
        val mode = intent.getStringExtra("mode") ?: "mixed"
        TrackingService.log(context, "PLAN", "alarm #$id fired, autoStart=$auto")

        var started = false
        if (auto) {
            try {
                val svc = Intent(context, TrackingService::class.java)
                    .setAction(TrackingService.ACTION_START)
                    .putExtra(TrackingService.EXTRA_MODE, mode)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(svc) else context.startService(svc)
                started = true
            } catch (e: Exception) {
                TrackingService.log(context, "PLAN", "auto start refused by the system: $e")
            }
        }

        Notifier.ensureChannels(context)
        val open = PendingIntent.getActivity(
            context, id, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, Notifier.ALERT_CHANNEL_ID) else Notification.Builder(context)
        val text = if (started) Tr.t(context, "Запись маршрута запущена автоматически.") else Tr.t(context, "Не забудьте включить запись трека.")
        val n = b.setContentTitle("🥾 $title").setContentText(text).setSmallIcon(R.drawable.ic_stat_tropa)
            .setContentIntent(open).setAutoCancel(true).build()
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(2000 + id, n)

        // The plan has been used: drop it from the stored list.
        val arr = load(context)
        val out = JSONArray()
        for (i in 0 until arr.length()) if (arr.getJSONObject(i).optInt("id") != id) out.put(arr.getJSONObject(i))
        save(context, out)
    }
}
