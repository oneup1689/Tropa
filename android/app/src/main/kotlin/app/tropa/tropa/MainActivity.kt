package app.tropa.tropa

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    /** Builds the intent for the tracking service with every parameter the UI passes. */
    private fun serviceIntent(call: MethodCall, action: String): Intent =
        Intent(this, TrackingService::class.java)
            .setAction(action)
            .putExtra(TrackingService.EXTRA_SESSION, (call.argument<Number>("session"))?.toLong() ?: 0L)
            .putExtra(TrackingService.EXTRA_MAX_ACC, (call.argument<Number>("maxAccuracy"))?.toFloat() ?: 50f)
            .putExtra(TrackingService.EXTRA_INTERVAL, (call.argument<Number>("intervalMs"))?.toLong() ?: 2000L)
            .putExtra(TrackingService.EXTRA_MODE, call.argument<String>("mode") ?: "mixed")
            .putExtra(TrackingService.EXTRA_JUMP, (call.argument<Number>("jumpSpeed"))?.toDouble() ?: 70.0)
            .putExtra(TrackingService.EXTRA_MOVING, (call.argument<Number>("movingSpeed"))?.toDouble() ?: 0.5)
            .putExtra(TrackingService.EXTRA_AUTOPAUSE, call.argument<Boolean>("autoPause") ?: true)
            .putExtra(TrackingService.EXTRA_SPLIT_MIDNIGHT, call.argument<Boolean>("splitMidnight") ?: false)
            .putExtra(TrackingService.EXTRA_IDLE_MIN, (call.argument<Number>("idleMinutes"))?.toInt() ?: 5)
            .putExtra(TrackingService.EXTRA_OFFROUTE_M, (call.argument<Number>("offRouteM"))?.toFloat() ?: 40f)
            .putExtra(TrackingService.EXTRA_ROUTE, (call.argument<Number>("routeId"))?.toLong() ?: 0L)
            .putExtra("lang", call.argument<String>("lang") ?: "ru")
            .putExtra(TrackingService.EXTRA_GOAL_M, (call.argument<Number>("goalM"))?.toDouble() ?: 0.0)
            .putExtra(TrackingService.EXTRA_GOAL_ROUND, call.argument<Boolean>("goalRound") ?: false)
            .putExtra(TrackingService.EXTRA_GOAL_LABEL, call.argument<String>("goalLabel") ?: "")
            .putExtra(TrackingService.EXTRA_GOAL_HALF_LABEL, call.argument<String>("goalHalfLabel") ?: "")

    private fun launch(intent: Intent) {
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tropa/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "state" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        val airplane = Settings.Global.getInt(contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
                        result.success(
                            mapOf(
                                "airplane" to airplane,
                                "powerSave" to pm.isPowerSaveMode,
                                "doze" to pm.isDeviceIdleMode,
                                "interactive" to pm.isInteractive,
                                "ignoringBatteryOpt" to pm.isIgnoringBatteryOptimizations(packageName)
                            )
                        )
                    }
                    "setLanguage" -> {
                        Tr.setLanguage(this, call.argument<String>("code") ?: "ru")
                        result.success(null)
                    }
                    "keepScreenOn" -> {
                        // A long map download must not be interrupted by the screen going off.
                        val on = call.argument<Boolean>("on") ?: false
                        runOnUiThread {
                            if (on) window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            else window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "network" -> {
                        // Used before big downloads: warn when the phone is not on Wi-Fi.
                        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
                        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                        val online = caps?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
                        val wifi = caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true ||
                            caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) == true
                        result.success(mapOf("online" to online, "wifi" to wifi))
                    }
                    "freeBytes" -> {
                        // Free space where the maps are stored (the app's external folder).
                        val dir = getExternalFilesDir(null) ?: filesDir
                        result.success(android.os.StatFs(dir.path).availableBytes)
                    }
                    "moveToBack" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    "startTracking" -> {
                        launch(serviceIntent(call, TrackingService.ACTION_START))
                        result.success(null)
                    }
                    "stopTracking" -> {
                        startService(Intent(this, TrackingService::class.java).setAction(TrackingService.ACTION_STOP))
                        result.success(null)
                    }
                    "pauseTracking" -> {
                        startService(Intent(this, TrackingService::class.java).setAction(TrackingService.ACTION_PAUSE))
                        result.success(null)
                    }
                    "setGoal" -> {
                        startService(serviceIntent(call, TrackingService.ACTION_GOAL))
                        result.success(null)
                    }
                    "resumeTracking" -> {
                        startService(Intent(this, TrackingService::class.java).setAction(TrackingService.ACTION_RESUME))
                        result.success(null)
                    }
                    "watch" -> {
                        launch(serviceIntent(call, TrackingService.ACTION_WATCH))
                        result.success(null)
                    }
                    "unwatch" -> {
                        startService(Intent(this, TrackingService::class.java).setAction(TrackingService.ACTION_UNWATCH))
                        result.success(null)
                    }
                    "autoModeEnabled" -> result.success(
                        getSharedPreferences(TrackingService.PREFS, Context.MODE_PRIVATE).getBoolean(TrackingService.KEY_AUTO, false)
                    )
                    "trackingStatus" -> result.success(TrackingService.status())
                    "scheduleTrip" -> {
                        PlannerReceiver.schedule(
                            this,
                            (call.argument<Number>("id"))?.toInt() ?: 0,
                            (call.argument<Number>("atMs"))?.toLong() ?: 0L,
                            call.argument<String>("title") ?: "",
                            call.argument<Boolean>("autoStart") ?: false,
                            call.argument<String>("mode") ?: "mixed"
                        )
                        result.success(null)
                    }
                    "cancelTrip" -> {
                        PlannerReceiver.cancel(this, (call.argument<Number>("id"))?.toInt() ?: 0)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
