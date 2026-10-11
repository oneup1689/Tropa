package app.tropa.tropa

import android.content.Context
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
                if (call.method == "state") {
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
                } else if (call.method == "moveToBack") {
                    moveTaskToBack(true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
