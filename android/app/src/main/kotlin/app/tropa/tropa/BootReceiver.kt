package app.tropa.tropa

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/** Resumes an interrupted recording after the phone reboots. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val session = context.getSharedPreferences(TrackingService.PREFS, Context.MODE_PRIVATE)
            .getLong(TrackingService.KEY_SESSION, 0L)
        if (session <= 0) return
        TrackingService.log(context, "SVC", "boot completed, resuming session=$session")
        try {
            val svc = Intent(context, TrackingService::class.java).setAction(TrackingService.ACTION_START)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(svc) else context.startService(svc)
        } catch (e: Exception) {
            TrackingService.log(context, "SVC", "could not resume after boot: $e")
        }
    }
}
