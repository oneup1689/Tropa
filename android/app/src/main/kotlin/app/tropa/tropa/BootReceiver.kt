package app.tropa.tropa

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/** After a reboot: resume an interrupted recording, restart 24/7 watching, and restore planned trips. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        try {
            PlannerReceiver.rescheduleAll(context)
        } catch (e: Exception) {
            TrackingService.log(context, "PLAN", "could not restore plans after boot: $e")
        }
        val prefs = context.getSharedPreferences(TrackingService.PREFS, Context.MODE_PRIVATE)
        val session = prefs.getLong(TrackingService.KEY_SESSION, 0L)
        val auto = prefs.getBoolean(TrackingService.KEY_AUTO, false)
        if (session <= 0 && !auto) return
        TrackingService.log(context, "SVC", "boot completed, resuming (session=$session, 24/7=$auto)")
        try {
            // No action and no extras: the service treats this like a system restart and reuses saved settings.
            val svc = Intent(context, TrackingService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(svc) else context.startService(svc)
        } catch (e: Exception) {
            TrackingService.log(context, "SVC", "could not resume after boot: $e")
        }
    }
}
