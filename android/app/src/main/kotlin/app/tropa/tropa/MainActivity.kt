package app.tropa.tropa

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
                    "moveToBack" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    "startTracking" -> {
                        val session = (call.argument<Number>("session"))?.toLong() ?: 0L
                        val intent = Intent(this, TrackingService::class.java)
                            .setAction(TrackingService.ACTION_START)
                            .putExtra(TrackingService.EXTRA_SESSION, session)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        result.success(null)
                    }
                    "stopTracking" -> {
                        startService(Intent(this, TrackingService::class.java).setAction(TrackingService.ACTION_STOP))
                        result.success(null)
                    }
                    "trackingStatus" -> result.success(TrackingService.status())
                    else -> result.notImplemented()
                }
            }
    }
}
