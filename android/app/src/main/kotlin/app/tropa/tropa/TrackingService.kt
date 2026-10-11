package app.tropa.tropa

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Records GPS fixes independently of the Flutter UI, so closing or swiping the
 * app does not stop the recording. Owns all writes of points to tropa.db.
 */
class TrackingService : Service(), LocationListener {

    companion object {
        const val ACTION_START = "app.tropa.tropa.START"
        const val ACTION_STOP = "app.tropa.tropa.STOP"
        const val EXTRA_SESSION = "session"
        const val PREFS = "tropa_tracking"
        const val KEY_SESSION = "session"
        private const val CHANNEL_ID = "tropa_tracking"
        private const val NOTIFICATION_ID = 1001
        private const val ALERT_CHANNEL_ID = "tropa_alert"
        private const val ALERT_ID = 1002
        private const val HEARTBEAT_MS = 10_000L // check cadence; full log line every 3rd tick
        private const val NO_SIGNAL_MS = 45_000L // no fixes this long -> alert
        private const val WATCHDOG_MS = 90_000L
        private const val STATIONARY_STORE_MS = 15_000L
        private const val GAP_MS = 30_000L

        @Volatile var running = false
        @Volatile var sessionId = 0L
        @Volatile var points = 0
        @Volatile var distanceM = 0.0
        @Volatile var lastAcc = 0f
        @Volatile var startMs = 0L
        @Volatile var lastFixAt = 0L

        fun status(): Map<String, Any> = mapOf(
            "running" to running,
            "session" to sessionId,
            "points" to points,
            "distance" to distanceM,
            "accuracy" to lastAcc.toDouble(),
            "startMs" to startMs,
            "sinceFix" to (if (running && lastFixAt > 0) (System.currentTimeMillis() - lastFixAt) / 1000 else 0L)
        )

        fun openDb(context: Context): SQLiteDatabase {
            val path = context.getDatabasePath("tropa.db")
            path.parentFile?.mkdirs()
            val db = SQLiteDatabase.openDatabase(
                path.path, null, SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY
            )
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                    "start_ms INTEGER NOT NULL, end_ms INTEGER, status TEXT NOT NULL)"
            )
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS points(id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                    "session_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL, lat REAL NOT NULL, " +
                    "lon REAL NOT NULL, acc REAL, alt REAL, speed REAL)"
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_points_session ON points(session_id, ts_ms)")
            if (db.version == 0) db.version = 1 // lets sqflite open the same file without re-creating
            return db
        }

        fun log(context: Context, tag: String, message: String) {
            try {
                val dir = File(context.applicationInfo.dataDir, "app_flutter")
                dir.mkdirs()
                val ts = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())
                File(dir, "tropa_debug_log.txt").appendText("$ts [$tag] $message\n")
            } catch (_: Exception) {
                // logging must never break recording
            }
        }
    }

    private var db: SQLiteDatabase? = null
    private var lm: LocationManager? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())

    private var lastStored: Location? = null
    private var lastStoredWall = 0L
    private var lastFixWall = 0L
    private var stopRequested = false
    private var alertActive = false
    private var signalLost = false
    private var beatCount = 0
    private val gpsOffCheck = Runnable {
        // Debounce: alert only if GPS is still off 10 s after it was switched off.
        if (lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) == false) {
            raiseAlert("GPS выключен — маршрут не пишется", "Включите геолокацию, запись продолжится сама.")
        }
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            beat()
            handler.postDelayed(this, HEARTBEAT_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        try {
            handleStart(intent)
        } catch (e: Throwable) {
            // Never let a service error kill the whole app: write the reason to the debug log instead.
            log(this, "SVC", "FATAL in onStartCommand: $e | ${e.stackTraceToString().take(1200)}")
            running = false
            stopSelf()
            START_NOT_STICKY
        }

    private fun handleStart(intent: Intent?): Int {
        if (intent?.action == ACTION_STOP) {
            stopRequested = true
            finishSession("finished")
            return START_NOT_STICKY
        }
        startInForeground()
        if (running) return START_STICKY

        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        val database = openDb(this)
        db = database

        val requested = intent?.getLongExtra(EXTRA_SESSION, 0L) ?: 0L
        val saved = prefs.getLong(KEY_SESSION, 0L)
        val resumeId = if (requested > 0) requested else saved
        if (resumeId > 0) {
            sessionId = resumeId
            database.execSQL("UPDATE sessions SET status='active', end_ms=NULL WHERE id=?", arrayOf(resumeId))
            loadSessionStats(database, resumeId)
            log(this, "SVC", "resumed session=$resumeId points=$points restartedBySystem=${intent == null}")
            if (intent == null) raiseAlert("Запись перезапущена системой", "В маршруте мог появиться пропуск.")
        } else {
            val cv = ContentValues().apply {
                put("start_ms", System.currentTimeMillis())
                put("status", "active")
            }
            sessionId = database.insert("sessions", null, cv)
            points = 0
            distanceM = 0.0
            startMs = System.currentTimeMillis()
            log(this, "SVC", "started session=$sessionId")
        }
        prefs.edit().putLong(KEY_SESSION, sessionId).apply()

        acquireWakeLock()
        lastFixWall = System.currentTimeMillis()
        lastFixAt = lastFixWall
        running = true
        requestUpdates()
        handler.postDelayed(heartbeat, HEARTBEAT_MS)
        return START_STICKY
    }

    private fun loadSessionStats(database: SQLiteDatabase, id: Long) {
        distanceM = 0.0
        points = 0
        lastStored = null
        database.rawQuery("SELECT ts_ms, lat, lon, acc FROM points WHERE session_id=? ORDER BY ts_ms", arrayOf(id.toString()))
            .use { c ->
                var prev: Location? = null
                var prevTs = 0L
                while (c.moveToNext()) {
                    val ts = c.getLong(0)
                    val l = Location("db").apply { latitude = c.getDouble(1); longitude = c.getDouble(2) }
                    if (prev != null && ts - prevTs <= GAP_MS) distanceM += prev.distanceTo(l)
                    prev = l
                    prevTs = ts
                    points++
                }
            }
        database.rawQuery("SELECT start_ms FROM sessions WHERE id=?", arrayOf(id.toString())).use { c ->
            startMs = if (c.moveToFirst()) c.getLong(0) else System.currentTimeMillis()
        }
    }

    private fun startInForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Запись маршрута", NotificationManager.IMPORTANCE_LOW)
            )
            nm.createNotificationChannel(
                NotificationChannel(ALERT_CHANNEL_ID, "Тревога: запись прервана", NotificationManager.IMPORTANCE_HIGH).apply {
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
                }
            )
        }
        val n = buildNotification("Идёт запись маршрута")
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        return b.setContentTitle("Tropa записывает маршрут")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tropa:tracking").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun requestUpdates() {
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        lm = manager
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            log(this, "SVC", "no location permission, cannot record")
            return
        }
        try {
            manager.removeUpdates(this)
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 2000L, 0f, this, Looper.getMainLooper())
            log(this, "SVC", "GPS updates requested, gpsEnabled=${manager.isProviderEnabled(LocationManager.GPS_PROVIDER)}")
        } catch (e: Exception) {
            log(this, "SVC", "requestLocationUpdates failed: $e")
        }
    }

    override fun onLocationChanged(loc: Location) {
        val now = System.currentTimeMillis()
        lastFixWall = now
        lastFixAt = now
        clearAlert()
        val acc = if (loc.hasAccuracy()) loc.accuracy else 99f
        lastAcc = acc
        val prev = lastStored
        var skip: String? = null
        var dist = 0f
        var dtSec = 0.0

        if (acc > 50f) {
            skip = "acc>50"
        } else if (prev != null) {
            dtSec = (loc.time - prev.time) / 1000.0
            dist = prev.distanceTo(loc)
            if (dtSec > 20 && acc > 20f) {
                skip = "poor first fix after gap (acc=${"%.1f".format(acc)})"
            } else if (dtSec > 0 && dist / dtSec > 25.0 && acc > 8f) {
                skip = "speed jump ${"%.1f".format(dist / dtSec * 3.6)} km/h"
            }
        }
        if (skip != null) {
            log(this, "FIX", "${"%.6f".format(loc.latitude)},${"%.6f".format(loc.longitude)} acc=${"%.1f".format(acc)} SKIPPED ($skip)")
            return
        }

        val moving = prev == null || dist >= maxOf(2f, acc * 0.7f)
        val heartbeatDue = now - lastStoredWall >= STATIONARY_STORE_MS
        if (!moving && !heartbeatDue) return

        // Standing still: pin the previous position instead of storing GPS jitter.
        val lat = if (moving) loc.latitude else prev!!.latitude
        val lon = if (moving) loc.longitude else prev!!.longitude
        val speed = if (moving && prev != null && dtSec > 0) dist / dtSec else 0.0

        if (moving && prev != null && dtSec * 1000 <= GAP_MS) distanceM += dist
        val cv = ContentValues().apply {
            put("session_id", sessionId)
            put("ts_ms", loc.time)
            put("lat", lat)
            put("lon", lon)
            put("acc", acc.toDouble())
            put("alt", if (loc.hasAltitude()) loc.altitude else 0.0)
            put("speed", speed)
        }
        try {
            db?.insert("points", null, cv)
        } catch (e: Exception) {
            log(this, "SVC", "db insert failed: $e")
            return
        }
        points++
        lastStoredWall = now
        if (moving) lastStored = loc.also { it.latitude = lat; it.longitude = lon } else lastStored = Location(prev).also { it.time = loc.time }
        log(
            this, "FIX",
            "${"%.6f".format(lat)},${"%.6f".format(lon)} acc=${"%.1f".format(acc)} spd=${"%.2f".format(speed)} " +
                (if (moving) "stored" else "stored(still)")
        )
    }

    private fun beat() {
        val sinceMs = System.currentTimeMillis() - lastFixWall
        val gpsOn = lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) ?: true

        // Loud alert only when the user can fix it (GPS switched off). "GPS on but no satellites"
        // (forest, tunnel, cold start) is only logged: alerting would be pointless.
        if (!gpsOn) {
            raiseAlert("GPS выключен — маршрут не пишется", "Включите геолокацию, запись продолжится сама.")
        } else if (sinceMs > NO_SIGNAL_MS) {
            if (!signalLost) {
                signalLost = true
                log(this, "SIGNAL_LOST", "GPS on but no fixes for ${sinceMs / 1000}s (no alert: user cannot fix this)")
            }
        } else if (signalLost) {
            signalLost = false
            log(this, "SIGNAL_BACK", "fixes are arriving again")
        }

        beatCount++
        if (beatCount % 3 == 0) {
            val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            log(
                this, "BEAT",
                "native points=$points dist=${distanceM.toInt()}m sinceLastFix=${sinceMs / 1000}s gps=$gpsOn " +
                    "battery=${bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)}%"
            )
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification("Точек: $points · ${"%.2f".format(distanceM / 1000)} км"))
        }
        if (gpsOn && sinceMs > WATCHDOG_MS) {
            log(this, "WATCHDOG", "no fixes for >${WATCHDOG_MS / 1000}s, re-requesting updates")
            lastFixWall = System.currentTimeMillis() - NO_SIGNAL_MS // keep the alert state, retry in ~45s
            requestUpdates()
        }
    }

    private fun raiseAlert(title: String, text: String) {
        if (alertActive || stopRequested) return
        alertActive = true
        log(this, "ALERT", title)
        val open = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, ALERT_CHANNEL_ID) else Notification.Builder(this)
        val n = b.setContentTitle("⚠️ $title")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(ALERT_ID, n)
    }

    private fun clearAlert() {
        if (!alertActive) return
        alertActive = false
        log(this, "ALERT", "recording restored")
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(ALERT_ID)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        b.setContentTitle("Запись возобновлена").setSmallIcon(R.mipmap.ic_launcher).setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(15_000)
        nm.notify(ALERT_ID, b.build())
    }

    private fun finishSession(status: String) {
        val id = sessionId
        try {
            db?.execSQL("UPDATE sessions SET status=?, end_ms=? WHERE id=?", arrayOf<Any>(status, System.currentTimeMillis(), id))
        } catch (e: Exception) {
            log(this, "SVC", "failed to close session: $e")
        }
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(KEY_SESSION).apply()
        log(this, "SVC", "stopped session=$id points=$points dist=${distanceM.toInt()}m")
        shutdown()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun shutdown() {
        handler.removeCallbacks(heartbeat)
        try { lm?.removeUpdates(this) } catch (_: Exception) {}
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        running = false
        sessionId = 0
        db?.close()
        db = null
    }

    override fun onDestroy() {
        if (!stopRequested) log(this, "SVC", "onDestroy without stop request (killed by system?)")
        shutdown()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        log(this, "SVC", "task removed (swiped from recents), service keeps running")
        super.onTaskRemoved(rootIntent)
    }

    override fun onProviderEnabled(provider: String) {
        log(this, "GPS_SERVICE", "provider $provider enabled")
        if (provider == LocationManager.GPS_PROVIDER) {
            // Reset so that the next time GPS is switched off the alert fires again.
            handler.removeCallbacks(gpsOffCheck)
            alertActive = false
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(ALERT_ID)
        }
    }

    override fun onProviderDisabled(provider: String) {
        log(this, "GPS_SERVICE", "provider $provider disabled")
        if (provider == LocationManager.GPS_PROVIDER) {
            handler.removeCallbacks(gpsOffCheck)
            handler.postDelayed(gpsOffCheck, 10_000L)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
}
