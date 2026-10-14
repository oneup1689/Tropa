package app.tropa.tropa

import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
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
import java.util.Calendar

/**
 * Records GPS fixes independently of the Flutter UI, so closing or swiping the app does not stop
 * the recording. Owns all writes of points to tropa.db.
 *
 * States: IDLE (nothing), WATCH (24/7 mode: only the step sensor is listening), PROBE (steps seen,
 * GPS is checking whether the person really moves), RECORD (a session is being recorded).
 */
class TrackingService : Service(), LocationListener, SensorEventListener {

    enum class State { IDLE, WATCH, PROBE, RECORD }

    companion object {
        const val ACTION_START = "app.tropa.tropa.START"
        const val ACTION_STOP = "app.tropa.tropa.STOP"
        const val ACTION_WATCH = "app.tropa.tropa.WATCH"
        const val ACTION_UNWATCH = "app.tropa.tropa.UNWATCH"
        const val ACTION_PAUSE = "app.tropa.tropa.PAUSE"
        const val ACTION_RESUME = "app.tropa.tropa.RESUME"
        const val ACTION_GOAL = "app.tropa.tropa.GOAL"
        const val ACTION_SET_MODE = "app.tropa.tropa.SET_MODE"
        const val EXTRA_GOAL_M = "goalM"
        const val EXTRA_GOAL_ROUND = "goalRound"
        const val EXTRA_GOAL_LABEL = "goalLabel"
        const val EXTRA_GOAL_HALF_LABEL = "goalHalfLabel"
        const val EXTRA_SESSION = "session"
        const val EXTRA_MAX_ACC = "maxAccuracy"
        const val EXTRA_INTERVAL = "intervalMs"
        const val EXTRA_MODE = "mode"
        const val EXTRA_JUMP = "jumpSpeed"
        const val EXTRA_MOVING = "movingSpeed"
        const val EXTRA_AUTOPAUSE = "autoPause"
        const val EXTRA_ROUTE = "routeId"
        const val EXTRA_OFFROUTE_M = "offRouteM"
        const val EXTRA_SPLIT_MIDNIGHT = "splitMidnight"
        const val EXTRA_IDLE_MIN = "idleMinutes"
        const val PREFS = "tropa_tracking"
        const val KEY_SESSION = "session"
        const val KEY_AUTO = "auto_mode"
        private const val HEARTBEAT_MS = 10_000L // check cadence; full log line every 3rd tick
        private const val NO_SIGNAL_MS = 45_000L
        private const val WATCHDOG_MS = 90_000L
        private val WATCHDOG_BACKOFF_MS = longArrayOf(60_000L, 120_000L, 300_000L, 600_000L)
        private const val VEHICLE_SPEED_MS = 4.2 // 15 km/h: a sustained faster pace in walk mode is a vehicle
        private const val VEHICLE_AFTER_MS = 60_000L
        private const val MAX_PLAUSIBLE_MS = 70.0 // 252 km/h: faster than any Doppler reading we trust
        private const val STATIONARY_STORE_MS = 15_000L
        private const val GAP_MS = 30_000L
        private const val PAUSE_AFTER_MS = 60_000L // standing this long -> low-power GPS rate
        private const val LOW_POWER_INTERVAL_MS = 5_000L // 10 s let the GNSS chip duty-cycle and accuracy fell to 100+ m
        private const val RESUME_DISTANCE_M = 20f // moved this far during a manual pause -> recording resumes
        private const val STEPS_TO_WAKE = 20 // steps within STEP_WINDOW_MS start a GPS probe
        private const val STEP_WINDOW_MS = 30_000L
        private const val PROBE_CONFIRM_M = 30f // displacement that confirms real movement
        private const val PROBE_MIN_MS = 8_000L
        private const val PROBE_TIMEOUT_MS = 90_000L
        private const val PROBE_COOLDOWN_MS = 60_000L

        @Volatile var running = false // true only while a session is recorded
        @Volatile var watching = false
        @Volatile var sessionId = 0L
        @Volatile var points = 0
        @Volatile var distanceM = 0.0
        @Volatile var lastAcc = 0f
        @Volatile var startMs = 0L
        @Volatile var lastFixAt = 0L
        @Volatile var movingMs = 0L
        @Volatile var lowPower = false
        @Volatile var manualPause = false
        @Volatile var lastLat = 0.0
        @Volatile var lastLon = 0.0
        @Volatile var offRouteM = -1.0 // distance from the loaded route, -1 when no route / unknown
        @Volatile var motionSensor = "none" // what 24/7 mode uses to notice movement: steps / significant / none
        @Volatile var activeMode = "mixed" // travel mode of the session being recorded
        @Volatile var goalM = 0.0 // distance goal of this walk in metres, 0 = none
        @Volatile var goalRound = false // out-and-back: the half-way notification asks to turn around
        @Volatile var goalStage = 0 // 0 = not yet, 1 = half passed, 2 = goal reached

        fun status(): Map<String, Any> = mapOf(
            "running" to running,
            "watching" to watching,
            "session" to sessionId,
            "points" to points,
            "distance" to distanceM,
            "accuracy" to lastAcc.toDouble(),
            "startMs" to startMs,
            "movingMs" to movingMs,
            "paused" to lowPower,
            "manualPause" to manualPause,
            "lat" to lastLat,
            "lon" to lastLon,
            "offRoute" to offRouteM,
            "motionSensor" to motionSensor,
            "mode" to activeMode,
            "goalM" to goalM,
            "goalRound" to goalRound,
            "goalStage" to goalStage,
            "sinceFix" to (if ((running || watching) && lastFixAt > 0) (System.currentTimeMillis() - lastFixAt) / 1000 else 0L)
        )

        /** Shorthand kept for the receivers and the service itself; the log lives in [TrackingDb]. */
        fun log(context: Context, tag: String, message: String) = TrackingDb.log(context, tag, message)
    }

    private var state = State.IDLE
    private var db: SQLiteDatabase? = null
    private var lm: LocationManager? = null
    private var sensors: SensorManager? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())

    // recording parameters
    private var maxAccuracy = 50f
    private var intervalMs = 2000L
    private var modeCode = "mixed"
    private var jumpSpeed = 70.0
    private var movingSpeed = 0.5
    private var autoPause = true
    private var splitMidnight = false
    private var idleMs = 5 * 60_000L
    private var autoSession = false

    // recording state
    private var lastStored: Location? = null
    private var lastStoredWall = 0L
    private var lastFixWall = 0L
    private var lastMovingWall = 0L
    private var sessionDay = 0
    private var stopRequested = false
    private var alertActive = false
    private var signalLost = false
    private var beatCount = 0
    private var lastPressure = 0f
    private var pendingFix: Location? = null
    private var gnssCallback: Any? = null // android.location.GnssStatus.Callback (API 24+), kept untyped for old phones
    private var storedLogCount = 0
    private var satsVisible = -1
    private var satsUsed = -1
    private var watchdogLevel = 0 // how many times in a row GPS was re-requested without a fix
    private var nextWatchdogWall = 0L
    private var fastSinceWall = 0L // when the speed rose above walking pace, 0 = not fast now
    private var modeHintShown = false // the "you seem to be driving" hint is offered once per walk
    private var pausePos: Location? = null
    private var gpsOffWhileWatching = false

    // 24/7 watching
    private val stepTimes = ArrayDeque<Long>()
    private var probeStartWall = 0L
    private var probeOrigin: Location? = null
    private val probeBuffer = ArrayList<Location>()
    private var cooldownUntil = 0L
    private var motionTrigger: TriggerEventListener? = null

    // distance goal: how it is shown in notifications (formatted by the app in the person's units)
    private var goalLabel = ""
    private var goalHalfLabel = ""

    // navigation along an imported route
    private val route by lazy { RouteGuard(this) }
    private var offRouteBase = 40f

    private val gpsOffCheck = Runnable {
        // Debounce: alert only if GPS is still off 10 s after it was switched off.
        if (lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) == false) {
            raiseAlert(Tr.t(this, "GPS выключен — маршрут не пишется"), Tr.t(this, "Включите геолокацию, запись продолжится сама."))
        }
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            try {
                beat()
            } catch (e: Throwable) {
                log(this@TrackingService, "SVC", "beat failed: $e")
            }
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
            watching = false
            stopSelf()
            START_NOT_STICKY
        }

    // ------------------------------------------------------------------ commands

    private fun handleStart(intent: Intent?): Int {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        when (intent?.action) {
            ACTION_STOP -> {
                stopRequested = true
                if (state == State.RECORD) stopRecording() else if (!autoEnabled()) shutdown()
                return if (autoEnabled()) START_STICKY else START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                if (state == State.RECORD && !manualPause) enterManualPause()
                return START_STICKY
            }
            ACTION_RESUME -> {
                if (state == State.RECORD && manualPause) leaveManualPause("button")
                return START_STICKY
            }
            ACTION_SET_MODE -> {
                intent.getStringExtra(EXTRA_MODE)?.let { applyModeChange(it) }
                if (state == State.IDLE) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                return START_STICKY
            }
            ACTION_GOAL -> {
                // Set, changed or cleared (0 m) while a walk is recorded.
                if (state == State.RECORD) applyGoalFromIntent(intent, prefs)
                if (state == State.IDLE) { // nothing is recorded: do not leave an idle service behind
                    stopSelf()
                    return START_NOT_STICKY
                }
                return START_STICKY
            }
            ACTION_UNWATCH -> {
                prefs.edit().putBoolean(KEY_AUTO, false).apply()
                if (state == State.WATCH || state == State.PROBE || state == State.IDLE) {
                    shutdown()
                    return START_NOT_STICKY
                }
                return START_STICKY // a session is running; it ends normally
            }
        }

        startInForeground(Tr.t(this, "Ожидание…"))
        loadParams(intent, prefs)

        when {
            intent?.action == ACTION_WATCH -> {
                prefs.edit().putBoolean(KEY_AUTO, true).apply()
                if (state != State.RECORD) enterWatch()
            }
            intent?.action == ACTION_START -> {
                if (state == State.RECORD) return START_STICKY
                startRecording(intent.getLongExtra(EXTRA_SESSION, 0L), auto = false, restarted = false)
                if (intent.getDoubleExtra(EXTRA_GOAL_M, 0.0) > 0) applyGoalFromIntent(intent, prefs)
            }
            intent == null || intent.action == null -> {
                // Restarted by the system (or after a reboot): continue where we left off.
                val saved = prefs.getLong(KEY_SESSION, 0L)
                if (saved > 0) {
                    startRecording(saved, auto = false, restarted = true)
                } else if (autoEnabled()) {
                    enterWatch()
                } else {
                    shutdown()
                    return START_NOT_STICKY
                }
            }
        }
        return START_STICKY
    }

    private fun autoEnabled() = getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_AUTO, false)

    /** Settings come from the UI on a normal start; after a system restart reuse the saved ones. */
    private fun loadParams(intent: Intent?, prefs: android.content.SharedPreferences) {
        intent?.getStringExtra("lang")?.let { Tr.setLanguage(this, it) }
        if (intent != null && intent.hasExtra(EXTRA_MAX_ACC)) {
            maxAccuracy = intent.getFloatExtra(EXTRA_MAX_ACC, 50f)
            intervalMs = intent.getLongExtra(EXTRA_INTERVAL, 2000L)
            modeCode = intent.getStringExtra(EXTRA_MODE) ?: "mixed"
            jumpSpeed = intent.getDoubleExtra(EXTRA_JUMP, 70.0)
            movingSpeed = intent.getDoubleExtra(EXTRA_MOVING, 0.5)
            autoPause = intent.getBooleanExtra(EXTRA_AUTOPAUSE, true)
            splitMidnight = intent.getBooleanExtra(EXTRA_SPLIT_MIDNIGHT, false)
            idleMs = intent.getIntExtra(EXTRA_IDLE_MIN, 5) * 60_000L
            offRouteBase = intent.getFloatExtra(EXTRA_OFFROUTE_M, 40f)
            prefs.edit().putFloat("max_acc", maxAccuracy).putLong("interval_ms", intervalMs)
                .putString("mode", modeCode).putFloat("jump", jumpSpeed.toFloat())
                .putFloat("moving", movingSpeed.toFloat()).putBoolean("autopause", autoPause)
                .putBoolean("split_midnight", splitMidnight).putLong("idle_ms", idleMs)
                .putFloat("offroute_m", offRouteBase).apply()
        } else {
            maxAccuracy = prefs.getFloat("max_acc", 50f)
            intervalMs = prefs.getLong("interval_ms", 2000L)
            modeCode = prefs.getString("mode", "mixed") ?: "mixed"
            jumpSpeed = prefs.getFloat("jump", 70f).toDouble()
            movingSpeed = prefs.getFloat("moving", 0.5f).toDouble()
            autoPause = prefs.getBoolean("autopause", true)
            splitMidnight = prefs.getBoolean("split_midnight", false)
            idleMs = prefs.getLong("idle_ms", 5 * 60_000L)
            offRouteBase = prefs.getFloat("offroute_m", 40f)
            // Started by the planner: only the travel mode is known, so use that mode's own profile.
            val plannedMode = intent?.getStringExtra(EXTRA_MODE)
            if (plannedMode != null) {
                modeCode = plannedMode
                when (plannedMode) {
                    "walk" -> { intervalMs = 2000L; jumpSpeed = 10.0; movingSpeed = 0.4 }
                    "bike" -> { intervalMs = 2000L; jumpSpeed = 25.0; movingSpeed = 0.8 }
                    "car" -> { intervalMs = 1000L; jumpSpeed = 70.0; movingSpeed = 2.0 }
                    "water" -> { intervalMs = 2000L; jumpSpeed = 15.0; movingSpeed = 0.3 }
                    else -> { intervalMs = 2000L; jumpSpeed = 70.0; movingSpeed = 0.5 }
                }
            }
        }
        if (intent != null && intent.hasExtra(EXTRA_ROUTE)) {
            val routeId = intent.getLongExtra(EXTRA_ROUTE, 0L)
            prefs.edit().putLong("route_id", routeId).apply()
        }
    }

    // ------------------------------------------------------------------ watch / probe (24/7)

    private fun enterWatch() {
        stopLocation()
        releaseWakeLock()
        state = State.WATCH
        watching = true
        running = false
        stepTimes.clear()
        registerStepSensor()
        updateNotification(Tr.t(this, "Ожидание движения"))
        ensureHeartbeat()
        log(this, "AUTO", "watching for movement (steps >= $STEPS_TO_WAKE in ${STEP_WINDOW_MS / 1000}s wakes GPS)")
    }

    private fun registerStepSensor() {
        val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        sensors = sm
        motionSensor = "none"
        if (checkSelfPermission("android.permission.ACTIVITY_RECOGNITION") != PackageManager.PERMISSION_GRANTED &&
            Build.VERSION.SDK_INT >= 29
        ) {
            log(this, "AUTO", "no ACTIVITY_RECOGNITION permission: step sensor unavailable")
            return
        }
        val steps = sm.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR, true) ?: sm.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
        if (steps != null) {
            sm.registerListener(this, steps, SensorManager.SENSOR_DELAY_NORMAL, 5_000_000) // batch up to 5 s
            motionSensor = "steps"
            log(this, "AUTO", "step detector registered (wakeUp=${steps.isWakeUpSensor})")
            return
        }
        if (Build.VERSION.SDK_INT >= 18) {
            val sig = sm.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)
            if (sig != null) {
                val trig = object : TriggerEventListener() {
                    override fun onTrigger(event: TriggerEvent?) {
                        if (state == State.WATCH) startProbe("significant motion")
                    }
                }
                motionTrigger = trig
                motionSensor = "significant"
                sm.requestTriggerSensor(trig, sig)
                log(this, "AUTO", "no step detector, using significant motion")
                return
            }
        }
        log(this, "AUTO", "no motion sensors: 24/7 mode cannot detect movement")
    }

    private fun unregisterMotionSensors() {
        try {
            sensors?.unregisterListener(this)
            motionTrigger?.let { t ->
                sensors?.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)?.let { sensors?.cancelTriggerSensor(t, it) }
            }
        } catch (_: Exception) {
        }
        motionTrigger = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_STEP_DETECTOR -> {
                if (state != State.WATCH) return
                val now = System.currentTimeMillis()
                stepTimes.addLast(now)
                while (stepTimes.isNotEmpty() && now - stepTimes.first() > STEP_WINDOW_MS) stepTimes.removeFirst()
                if (stepTimes.size >= STEPS_TO_WAKE && now >= cooldownUntil) startProbe("${stepTimes.size} steps")
            }
            Sensor.TYPE_PRESSURE -> lastPressure = event.values[0]
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun startProbe(reason: String) {
        if (state != State.WATCH) return
        // Steps and significant motion work without GPS, but a probe cannot: tell the user, who can switch it on.
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        if (!manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            cooldownUntil = System.currentTimeMillis() + PROBE_COOLDOWN_MS
            stepTimes.clear()
            if (!gpsOffWhileWatching) {
                gpsOffWhileWatching = true
                log(this, "AUTO", "movement seen ($reason) but GPS is off: asking the user to switch it on")
                Notifier.postAlert(this, Notifier.ALERT_ID, Tr.t(this, "Вы двигаетесь, но GPS выключен"), Tr.t(this, "Включите геолокацию — запись маршрута начнётся сама."))
            }
            return
        }
        gpsOffWhileWatching = false
        Notifier.cancel(this, Notifier.ALERT_ID)
        state = State.PROBE
        probeStartWall = System.currentTimeMillis()
        probeOrigin = null
        probeBuffer.clear()
        acquireWakeLock(PROBE_TIMEOUT_MS + 30_000)
        log(this, "AUTO", "probe started ($reason): checking GPS for real movement")
        updateNotification(Tr.t(this, "Проверяю, началось ли движение"))
        requestUpdates(2000L)
    }

    private fun handleProbeFix(loc: Location) {
        val acc = if (loc.hasAccuracy()) loc.accuracy else 99f
        if (acc > 25f) return
        probeBuffer.add(Location(loc))
        val origin = probeOrigin ?: loc.also { probeOrigin = Location(it) }
        val dist = origin.distanceTo(loc)
        val dt = loc.time - origin.time
        if (dist >= PROBE_CONFIRM_M && dt >= PROBE_MIN_MS) {
            log(this, "AUTO", "movement confirmed: ${dist.toInt()} m in ${dt / 1000}s, starting a session")
            val buffered = ArrayList(probeBuffer)
            probeBuffer.clear()
            startRecording(0L, auto = true, restarted = false)
            // Keep the probe fixes so the track starts where the walk actually started.
            for (b in buffered) storeBufferedFix(b)
        }
    }

    private fun storeBufferedFix(loc: Location) {
        val prev = lastStored
        val d = if (prev == null) 0f else prev.distanceTo(loc)
        insertPoint(loc.latitude, loc.longitude, if (loc.hasAccuracy()) loc.accuracy else 20f, loc, 0.0)
        if (prev != null && d > 0 && loc.time - prev.time <= GAP_MS) distanceM += d
        lastStored = Location(loc)
        lastStoredWall = System.currentTimeMillis()
    }

    private fun abortProbe() {
        log(this, "AUTO", "no real movement within ${PROBE_TIMEOUT_MS / 1000}s, back to watching")
        probeBuffer.clear()
        probeOrigin = null
        cooldownUntil = System.currentTimeMillis() + PROBE_COOLDOWN_MS
        enterWatch()
    }

    // ------------------------------------------------------------------ recording

    private fun startRecording(requestedId: Long, auto: Boolean, restarted: Boolean) {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        stopLocation()
        unregisterMotionSensors()
        val database = db ?: TrackingDb.open(this).also { db = it }

        val resumeId = requestedId
        if (resumeId > 0) {
            sessionId = resumeId
            database.execSQL("UPDATE sessions SET status='active', end_ms=NULL WHERE id=?", arrayOf<Any>(resumeId))
            loadSessionStats(database, resumeId)
            log(this, "SVC", "resumed session=$resumeId points=$points restartedBySystem=$restarted")
            if (restarted) raiseAlert(Tr.t(this, "Запись перезапущена системой"), Tr.t(this, "В маршруте мог появиться пропуск."))
        } else {
            val cv = ContentValues().apply {
                put("start_ms", System.currentTimeMillis())
                put("status", "active")
                put("mode", modeCode)
            }
            sessionId = database.insert("sessions", null, cv)
            points = 0
            distanceM = 0.0
            movingMs = 0L
            startMs = System.currentTimeMillis()
            lastStored = null
            log(this, "SVC", "started session=$sessionId mode=$modeCode auto=$auto")
        }
        // A restart after a kill must also remember the id of the session in progress.
        prefs.edit().putLong(KEY_SESSION, sessionId).apply()
        // A continued session keeps its goal (also after a restart by the system); a new one starts without.
        if (resumeId > 0) loadGoal(prefs) else clearGoal(prefs)
        log(
            this, "SVC",
            "settings: mode=$modeCode maxAccuracy=${maxAccuracy}m interval=${intervalMs}ms jump=${jumpSpeed}m/s " +
                "moving>=${movingSpeed}m/s autoPause=$autoPause splitMidnight=$splitMidnight idle=${idleMs / 60000}min"
        )

        autoSession = auto
        activeMode = modeCode
        fastSinceWall = 0L
        modeHintShown = false
        lowPower = false
        manualPause = false
        pausePos = null
        lastMovingWall = System.currentTimeMillis()
        lastFixWall = lastMovingWall
        lastFixAt = lastFixWall
        sessionDay = dayOf(System.currentTimeMillis())
        route.load(database, prefs.getLong("route_id", 0L), offRouteBase)
        offRouteM = -1.0

        acquireWakeLock(0)
        state = State.RECORD
        running = true
        watching = false
        registerPressureSensor()
        registerSatellites()
        watchdogLevel = 0
        nextWatchdogWall = 0L
        requestUpdates(intervalMs)
        ensureHeartbeat()
        updateNotification(Tr.t(this, "Идёт запись маршрута"))
    }

    private fun stopRecording() {
        val id = sessionId
        try {
            db?.execSQL(
                "UPDATE sessions SET status=?, end_ms=? WHERE id=?",
                arrayOf<Any>("finished", System.currentTimeMillis(), id)
            )
        } catch (e: Exception) {
            log(this, "SVC", "failed to close session: $e")
        }
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        prefs.edit().remove(KEY_SESSION).remove("route_id").apply()
        clearGoal(prefs) // the goal belongs to one walk
        log(this, "SVC", "stopped session=$id points=$points dist=${distanceM.toInt()}m auto=$autoSession")
        stopLocation()
        unregisterPressureSensor()
        unregisterSatellites()
        Notifier.cancel(this, Notifier.MODE_HINT_ID)
        releaseWakeLock()
        route.clear()
        offRouteM = -1.0
        cancelAlerts()
        running = false
        lowPower = false
        manualPause = false
        sessionId = 0
        autoSession = false
        lastStored = null
        if (autoEnabled() && !stopRequested) {
            enterWatch()
        } else if (autoEnabled()) {
            stopRequested = false
            enterWatch()
        } else {
            shutdown()
        }
    }

    /** Starts a new session at local midnight so each day is its own track (Pro option). */
    private fun rollSession() {
        val database = db ?: return
        val old = sessionId
        database.execSQL("UPDATE sessions SET status='finished', end_ms=? WHERE id=?", arrayOf<Any>(System.currentTimeMillis(), old))
        val cv = ContentValues().apply {
            put("start_ms", System.currentTimeMillis())
            put("status", "active")
            put("mode", modeCode)
        }
        sessionId = database.insert("sessions", null, cv)
        points = 0
        distanceM = 0.0
        movingMs = 0L
        startMs = System.currentTimeMillis()
        sessionDay = dayOf(startMs)
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putLong(KEY_SESSION, sessionId).apply()
        clearGoal(getSharedPreferences(PREFS, MODE_PRIVATE))
        log(this, "SVC", "midnight: session $old closed, new session=$sessionId")
    }

    // ------------------------------------------------------------------ distance goal

    private fun applyGoalFromIntent(intent: Intent, prefs: android.content.SharedPreferences) {
        val meters = intent.getDoubleExtra(EXTRA_GOAL_M, 0.0)
        if (meters <= 0) {
            clearGoal(prefs)
            log(this, "GOAL", "goal cleared")
            return
        }
        goalM = meters
        goalRound = intent.getBooleanExtra(EXTRA_GOAL_ROUND, false)
        goalLabel = intent.getStringExtra(EXTRA_GOAL_LABEL) ?: ""
        goalHalfLabel = intent.getStringExtra(EXTRA_GOAL_HALF_LABEL) ?: ""
        // Already past a threshold when the goal is set: that part counts as done silently, no old news.
        goalStage = when {
            distanceM >= goalM -> 2
            goalRound && distanceM >= goalM / 2 -> 1
            else -> 0
        }
        prefs.edit().putLong("goal_m", meters.toLong()).putBoolean("goal_round", goalRound)
            .putString("goal_label", goalLabel).putString("goal_half_label", goalHalfLabel)
            .putInt("goal_stage", goalStage).apply()
        log(this, "GOAL", "goal ${meters.toInt()} m roundTrip=$goalRound, now ${distanceM.toInt()} m, stage=$goalStage")
    }

    private fun loadGoal(prefs: android.content.SharedPreferences) {
        goalM = prefs.getLong("goal_m", 0L).toDouble()
        goalRound = prefs.getBoolean("goal_round", false)
        goalLabel = prefs.getString("goal_label", "") ?: ""
        goalHalfLabel = prefs.getString("goal_half_label", "") ?: ""
        goalStage = prefs.getInt("goal_stage", 0)
        if (goalM > 0) log(this, "GOAL", "goal restored: ${goalM.toInt()} m roundTrip=$goalRound stage=$goalStage")
    }

    private fun clearGoal(prefs: android.content.SharedPreferences) {
        goalM = 0.0
        goalRound = false
        goalStage = 0
        goalLabel = ""
        goalHalfLabel = ""
        prefs.edit().remove("goal_m").remove("goal_round").remove("goal_label").remove("goal_half_label").remove("goal_stage").apply()
    }

    /** One notification at the half-way point (out-and-back) and one when the goal is reached; recording goes on. */
    private fun checkGoal() {
        if (goalM <= 0 || goalStage >= 2) return
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (distanceM >= goalM) {
            goalStage = 2
            prefs.edit().putInt("goal_stage", 2).apply()
            log(this, "GOAL", "goal reached at ${distanceM.toInt()} m")
            Notifier.postAlert(this, Notifier.GOAL_ID, Tr.t(this, "Цель достигнута"), Tr.goalDone(this, goalLabel), "🎯")
        } else if (goalRound && goalStage == 0 && distanceM >= goalM / 2) {
            goalStage = 1
            prefs.edit().putInt("goal_stage", 1).apply()
            log(this, "GOAL", "half way at ${distanceM.toInt()} m")
            Notifier.postAlert(this, Notifier.GOAL_ID, Tr.t(this, "Половина пути пройдена"), Tr.goalHalf(this, goalHalfLabel), "🎯")
        }
    }

    private fun loadSessionStats(database: SQLiteDatabase, id: Long) {
        distanceM = 0.0
        points = 0
        movingMs = 0L
        lastStored = null
        database.rawQuery("SELECT ts_ms, lat, lon FROM points WHERE session_id=? ORDER BY ts_ms", arrayOf(id.toString()))
            .use { c ->
                var prev: Location? = null
                var prevTs = 0L
                while (c.moveToNext()) {
                    val ts = c.getLong(0)
                    val l = Location("db").apply { latitude = c.getDouble(1); longitude = c.getDouble(2) }
                    if (prev != null && ts - prevTs in 1..GAP_MS) {
                        val d = prev.distanceTo(l)
                        val v = d / ((ts - prevTs) / 1000.0)
                        // Same rule as while recording: an impossible jump is a new start, not distance.
                        if (v <= jumpSpeed * 3) {
                            distanceM += d
                            if (d >= 2 && v >= movingSpeed) movingMs += ts - prevTs
                        }
                    }
                    prev = l
                    prevTs = ts
                    points++
                }
            }
        database.rawQuery("SELECT start_ms FROM sessions WHERE id=?", arrayOf(id.toString())).use { c ->
            startMs = if (c.moveToFirst()) c.getLong(0) else System.currentTimeMillis()
        }
    }

    private fun dayOf(ms: Long): Int {
        val c = Calendar.getInstance()
        c.timeInMillis = ms
        return c.get(Calendar.YEAR) * 1000 + c.get(Calendar.DAY_OF_YEAR)
    }

    // ------------------------------------------------------------------ foreground notification

    private fun startInForeground(text: String) {
        Notifier.ensureChannels(this)
        val n = Notifier.ongoing(this, text)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(Notifier.NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(Notifier.NOTIFICATION_ID, n)
        }
    }

    private fun updateNotification(text: String) = Notifier.updateOngoing(this, text)

    // ------------------------------------------------------------------ GPS and sensors plumbing

    private fun acquireWakeLock(timeoutMs: Long) {
        releaseWakeLock()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tropa:tracking").apply {
            setReferenceCounted(false)
            if (timeoutMs > 0) acquire(timeoutMs) else acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun requestUpdates(every: Long) {
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        lm = manager
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            log(this, "SVC", "no location permission, cannot record")
            return
        }
        try {
            manager.removeUpdates(this)
            val rate = if (state == State.RECORD && lowPower) LOW_POWER_INTERVAL_MS else every
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, rate, 0f, this, Looper.getMainLooper())
            log(this, "SVC", "GPS updates requested every ${rate}ms, gpsEnabled=${manager.isProviderEnabled(LocationManager.GPS_PROVIDER)}")
        } catch (e: Exception) {
            log(this, "SVC", "requestLocationUpdates failed: $e")
        }
    }

    private fun stopLocation() {
        try {
            lm?.removeUpdates(this)
        } catch (_: Exception) {
        }
    }

    /** Satellite counts are only logged while the signal is missing, to tell "indoors" from "GPS chip asleep". */
    private fun registerSatellites() {
        if (Build.VERSION.SDK_INT < 24 || gnssCallback != null) return
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) return
        val cb = object : android.location.GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: android.location.GnssStatus) {
                var used = 0
                for (i in 0 until status.satelliteCount) if (status.usedInFix(i)) used++
                satsVisible = status.satelliteCount
                satsUsed = used
            }
        }
        try {
            (getSystemService(Context.LOCATION_SERVICE) as LocationManager).registerGnssStatusCallback(cb, handler)
            gnssCallback = cb
        } catch (e: Exception) {
            log(this, "SVC", "satellite status unavailable: $e")
        }
    }

    private fun unregisterSatellites() {
        if (Build.VERSION.SDK_INT < 24) return
        val cb = gnssCallback ?: return
        try {
            (getSystemService(Context.LOCATION_SERVICE) as LocationManager).unregisterGnssStatusCallback(cb as android.location.GnssStatus.Callback)
        } catch (_: Exception) {
        }
        gnssCallback = null
        satsVisible = -1
        satsUsed = -1
    }

    private fun registerPressureSensor() {
        val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        sensors = sm
        val p = sm.getDefaultSensor(Sensor.TYPE_PRESSURE)
        if (p != null) {
            sm.registerListener(this, p, SensorManager.SENSOR_DELAY_NORMAL)
            log(this, "SVC", "barometer registered")
        } else {
            log(this, "SVC", "no barometer on this device")
        }
    }

    private fun unregisterPressureSensor() {
        try {
            sensors?.unregisterListener(this)
        } catch (_: Exception) {
        }
        lastPressure = 0f
    }

    private fun ensureHeartbeat() {
        handler.removeCallbacks(heartbeat)
        handler.postDelayed(heartbeat, HEARTBEAT_MS)
    }

    // ------------------------------------------------------------------ location callbacks

    override fun onLocationChanged(loc: Location) {
        if (state == State.PROBE) {
            lastFixAt = System.currentTimeMillis()
            handleProbeFix(loc)
            return
        }
        if (state != State.RECORD) return

        val now = System.currentTimeMillis()
        lastFixWall = now
        lastFixAt = now
        clearAlert()
        val acc = if (loc.hasAccuracy()) loc.accuracy else 99f
        lastAcc = acc
        if (manualPause && !resumeIfMoved(loc, acc)) return
        val prev = lastStored
        var skip: String? = null
        var dist = 0f
        var dtSec = 0.0
        var dopplerOk = false

        if (acc > maxAccuracy) {
            skip = "acc>${maxAccuracy.toInt()}"
        } else if (prev != null) {
            dtSec = (loc.time - prev.time) / 1000.0
            dist = prev.distanceTo(loc)
            if (dtSec > 20 && acc > 20f && !confirmsPending(loc)) {
                // Not trusted alone, but remembered: a second fix that agrees with it ends the gap
                // (otherwise every following fix would be "first after a gap" and the hole kept growing).
                pendingFix = Location(loc)
                // Standing in low-power mode, then clearly displaced: the walk has started, even though
                // this fix is too poor to store. Return to the fast GPS rate to get good fixes quickly.
                if (lowPower && dist > maxOf(30f, acc)) {
                    lowPower = false
                    lastMovingWall = now
                    log(this, "AUTOPAUSE", "displacement ${dist.toInt()} m on a poor fix, back to normal GPS rate")
                    requestUpdates(intervalMs)
                }
                skip ="poor first fix after gap (acc=${"%.1f".format(acc)})"
            } else if (dtSec > 0 && dist / dtSec > jumpSpeed && acc > 8f) {
                // The implied speed is compared with the speed the GPS chip measures itself (Doppler):
                // a car in a walking-mode walk is fast, not a jump. Without this every following fix was
                // compared with the last stored one and rejected until the vehicle stopped.
                if (dopplerConfirms(loc, dist / dtSec)) {
                    dopplerOk = true
                } else {
                    skip = "speed jump ${"%.1f".format(dist / dtSec * 3.6)} km/h" +
                        (if (loc.hasSpeed()) " doppler=${"%.1f".format(loc.speed * 3.6)} km/h" else "")
                }
            }
        }
        if (skip != null) {
            log(this, "FIX", "${"%.6f".format(loc.latitude)},${"%.6f".format(loc.longitude)} acc=${"%.1f".format(acc)} SKIPPED ($skip)")
            return
        }

        val moving = prev == null || dist >= maxOf(2f, acc * 0.7f)

        // A "teleport" (position jumps far faster than anyone can travel, even with a good fix) is a new
        // starting point, not distance: it must not inflate the distance or the moving time.
        val speedNow = if (prev != null && dtSec > 0) dist / dtSec else 0.0
        val teleport = prev != null && dtSec > 0 && speedNow > jumpSpeed * 3 && !dopplerOk
        if (teleport) log(this, "FIX", "TELEPORT ${dist.toInt()} m in ${"%.1f".format(dtSec)}s: counted as a new start, no distance")

        // Moving time and auto-pause. Leaving low power on displacement alone, so a start is not missed.
        val movingNow = !teleport && moving && prev != null && dtSec > 0 && speedNow >= movingSpeed
        val wakeUp = prev != null && dist >= maxOf(5f, acc)
        if (movingNow && dtSec * 1000 <= GAP_MS) movingMs += (dtSec * 1000).toLong()
        if (movingNow || wakeUp) {
            lastMovingWall = now
            if (lowPower) {
                lowPower = false
                log(this, "AUTOPAUSE", "movement detected, back to normal GPS rate")
                requestUpdates(intervalMs)
            }
        } else if (autoPause && !lowPower && now - lastMovingWall > PAUSE_AFTER_MS) {
            lowPower = true
            log(this, "AUTOPAUSE", "standing for ${PAUSE_AFTER_MS / 1000}s, GPS rate reduced to save battery")
            requestUpdates(intervalMs)
        }

        val heartbeatDue = now - lastStoredWall >= STATIONARY_STORE_MS
        if (!moving && !heartbeatDue) return

        // Standing still: pin the previous position instead of storing GPS jitter.
        val lat = if (moving) loc.latitude else prev!!.latitude
        val lon = if (moving) loc.longitude else prev!!.longitude
        val speed = if (moving && prev != null && dtSec > 0) dist / dtSec else 0.0

        if (moving && !teleport && prev != null && dtSec * 1000 <= GAP_MS) distanceM += dist
        if (!insertPoint(lat, lon, acc, loc, speed)) return
        lastStoredWall = now
        lastLat = lat
        lastLon = lon
        if (moving) lastStored = loc.also { it.latitude = lat; it.longitude = lon } else lastStored = Location(prev).also { it.time = loc.time }
        // Ordinary stored fixes are the bulk of the log: only every 10th is written. Anything unusual is always logged.
        if (dopplerOk || storedLogCount++ % 10 == 0) {
            log(
                this, "FIX",
                "${"%.6f".format(lat)},${"%.6f".format(lon)} acc=${"%.1f".format(acc)} spd=${"%.2f".format(speed)} " +
                    (if (moving) "stored" else "stored(still)") + (if (dopplerOk) " doppler-confirmed" else "") + (if (lastPressure > 0) " p=${"%.1f".format(lastPressure)}" else "")
            )
        }

        if (moving) watchForVehicle(now, speed) // speed from the distance: some GPS chips report a Doppler speed of 0
        checkGoal()

        if (route.loaded) {
            route.evaluate(
                lat, lon, acc, offRouteBase, movingNow, now,
                onOff = { d -> Notifier.postAlert(this, Notifier.ROUTE_ALERT_ID, Tr.t(this, "Вы сошли с маршрута"), Tr.offRoute(this, d)) },
                onBack = { Notifier.cancel(this, Notifier.ROUTE_ALERT_ID) }
            )
            offRouteM = route.lastDistance
        }
    }

    // ------------------------------------------------------------------ manual pause

    /** Pause button: nothing is stored, but GPS keeps a slow watch so that walking on resumes the track. */
    private fun enterManualPause() {
        manualPause = true
        pausePos = lastStored?.let { Location(it) }
        lowPower = true
        pendingFix = null
        requestUpdates(intervalMs)
        updateNotification(Tr.t(this, "Пауза: пойдёте дальше — запись продолжится сама"))
        log(this, "PAUSE", "manual pause at ${pausePos?.let { "%.6f,%.6f".format(it.latitude, it.longitude) } ?: "unknown position"}")
    }

    private fun leaveManualPause(reason: String) {
        manualPause = false
        pausePos = null
        lowPower = false
        pendingFix = null
        lastMovingWall = System.currentTimeMillis()
        requestUpdates(intervalMs)
        updateNotification(Tr.t(this, "Идёт запись маршрута"))
        log(this, "PAUSE", "resumed ($reason)")
    }

    /** While paused: returns true (and ends the pause) once a reliable fix is [RESUME_DISTANCE_M] away. */
    private fun resumeIfMoved(loc: Location, acc: Float): Boolean {
        if (acc > 30f) return false
        val origin = pausePos
        if (origin == null) {
            pausePos = Location(loc)
            return false
        }
        val d = origin.distanceTo(loc)
        if (d < maxOf(RESUME_DISTANCE_M, acc)) return false
        leaveManualPause("moved ${d.toInt()} m")
        return true
    }

    /**
     * A walk recorded in "walk" mode that goes on faster than a person can walk for a minute: offer to
     * switch to the vehicle mode once (a notification with a button, so it works with the screen off).
     */
    private fun watchForVehicle(now: Long, speedMs: Double) {
        if (modeCode != "walk" || modeHintShown) return
        if (speedMs < VEHICLE_SPEED_MS) {
            if (speedMs < VEHICLE_SPEED_MS * 0.7) fastSinceWall = 0L // short slow-down at a junction is tolerated
            return
        }
        if (fastSinceWall == 0L) fastSinceWall = now
        if (now - fastSinceWall < VEHICLE_AFTER_MS) return
        modeHintShown = true
        log(this, "MODE_HINT", "moving faster than ${"%.0f".format(VEHICLE_SPEED_MS * 3.6)} km/h for ${VEHICLE_AFTER_MS / 1000}s in walk mode, suggesting mixed mode")
        Notifier.postModeHint(
            this,
            Tr.t(this, "Похоже, вы едете"),
            Tr.t(this, "Выбран режим «Пешком». Переключить на «Смешанный» (пешком и транспорт)?"),
            Tr.t(this, "Переключить на Смешанный"),
            PendingIntent.getService(
                this, 7, Intent(this, TrackingService::class.java).setAction(ACTION_SET_MODE).putExtra(EXTRA_MODE, "mixed"),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        )
    }

    /** The person (or the notification button) changed the travel mode of the walk in progress. */
    private fun applyModeChange(newMode: String) {
        if (state != State.RECORD) return
        when (newMode) {
            "walk" -> { jumpSpeed = 10.0; movingSpeed = 0.4 }
            "bike" -> { jumpSpeed = 25.0; movingSpeed = 0.8 }
            "car" -> { jumpSpeed = 70.0; movingSpeed = 2.0 }
            "water" -> { jumpSpeed = 15.0; movingSpeed = 0.3 }
            else -> { jumpSpeed = 70.0; movingSpeed = 0.5 }
        }
        modeCode = newMode
        activeMode = newMode
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString("mode", newMode)
            .putFloat("jump", jumpSpeed.toFloat()).putFloat("moving", movingSpeed.toFloat()).apply()
        try {
            db?.execSQL("UPDATE sessions SET mode=? WHERE id=?", arrayOf<Any>(newMode, sessionId))
        } catch (e: Exception) {
            log(this, "SVC", "failed to save the new mode: $e")
        }
        Notifier.cancel(this, Notifier.MODE_HINT_ID)
        log(this, "MODE_HINT", "travel mode changed to $newMode (jump=${jumpSpeed}m/s)")
    }

    /**
     * True when the speed measured by the GPS chip (Doppler, independent of position noise) agrees with the
     * speed implied by the distance from the last stored point: the movement is real, however fast it is.
     */
    private fun dopplerConfirms(loc: Location, impliedSpeed: Double): Boolean {
        if (!loc.hasSpeed() || loc.speed <= 0f || loc.speed > MAX_PLAUSIBLE_MS) return false
        if (Build.VERSION.SDK_INT >= 26 && loc.hasSpeedAccuracy() && loc.speedAccuracyMetersPerSecond > 2.5f) return false
        // The chord between two points is never longer than the path, so the implied speed may be lower
        // than the Doppler speed in curves, but it must not be much higher.
        return impliedSpeed <= loc.speed * 1.3 && impliedSpeed >= loc.speed * 0.5
    }

    /** True when [loc] lies close to the previously rejected poor fix, i.e. the position has stabilised. */
    private fun confirmsPending(loc: Location): Boolean {
        val p = pendingFix ?: return false
        pendingFix = null
        val dt = (loc.time - p.time) / 1000.0
        if (dt <= 0 || dt > 30) return false
        val speed = p.distanceTo(loc) / dt
        // Plausible on foot, by bike or by scooter at 10 s sampling; a bigger jump needs a good fix to be trusted.
        return speed <= minOf(jumpSpeed, 15.0)
    }

    private fun insertPoint(lat: Double, lon: Double, acc: Float, loc: Location, speed: Double): Boolean {
        val cv = ContentValues().apply {
            put("session_id", sessionId)
            put("ts_ms", loc.time)
            put("lat", lat)
            put("lon", lon)
            put("acc", acc.toDouble())
            put("alt", if (loc.hasAltitude()) loc.altitude else 0.0)
            put("speed", speed)
            if (lastPressure > 0) put("pressure", lastPressure.toDouble())
        }
        return try {
            db?.insert("points", null, cv)
            points++
            true
        } catch (e: Exception) {
            log(this, "SVC", "db insert failed: $e")
            false
        }
    }

    // ------------------------------------------------------------------ heartbeat

    private fun beat() {
        val now = System.currentTimeMillis()
        when (state) {
            State.PROBE -> {
                if (now - probeStartWall > PROBE_TIMEOUT_MS) abortProbe()
                return
            }
            State.WATCH -> {
                beatCount++
                if (beatCount % 30 == 0) log(this, "AUTO", "still watching (battery ${battery()}%)")
                // The user switched GPS on after our warning: check for movement right away.
                if (gpsOffWhileWatching) {
                    val m = getSystemService(Context.LOCATION_SERVICE) as LocationManager
                    if (m.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                        cooldownUntil = 0L
                        startProbe("GPS switched on after movement")
                    }
                }
                return
            }
            State.IDLE -> return
            State.RECORD -> {}
        }

        val sinceMs = now - lastFixWall
        val gpsOn = lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) ?: true

        // Loud alert only when the user can fix it (GPS switched off). "GPS on but no satellites"
        // (forest, tunnel, cold start) is only logged: alerting would be pointless.
        if (!gpsOn) {
            raiseAlert(Tr.t(this, "GPS выключен — маршрут не пишется"), Tr.t(this, "Включите геолокацию, запись продолжится сама."))
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
            log(
                this, "BEAT",
                "native points=$points dist=${distanceM.toInt()}m sinceLastFix=${sinceMs / 1000}s gps=$gpsOn battery=${battery()}%"
            )
            updateNotification(Tr.points(this, points, "%.2f".format(distanceM / 1000)))
        }
        if (gpsOn && sinceMs > NO_SIGNAL_MS && beatCount % 3 == 0 && satsVisible >= 0) {
            log(this, "SATS", "no fixes for ${sinceMs / 1000}s, satellites visible=$satsVisible usedInFix=$satsUsed")
        }
        if (!gpsOn || sinceMs <= WATCHDOG_MS) {
            watchdogLevel = 0
            nextWatchdogWall = 0L
        } else if (now >= nextWatchdogWall) {
            // Re-registering helps with a GPS chip that went to sleep, but indoors it only wakes the chip up again
            // and again: the pauses between attempts grow (90 s, then 2, 5, 10 min).
            log(this, "WATCHDOG", "no fixes for ${sinceMs / 1000}s, re-requesting updates (attempt ${watchdogLevel + 1})")
            requestUpdates(intervalMs)
            nextWatchdogWall = now + WATCHDOG_BACKOFF_MS[minOf(watchdogLevel, WATCHDOG_BACKOFF_MS.size - 1)]
            watchdogLevel++
        }

        // 24/7: a session that started by itself ends after a quiet period.
        if (autoSession && !manualPause && now - lastMovingWall > idleMs) {
            log(this, "AUTO", "no movement for ${idleMs / 60000} min, closing the automatic session")
            stopRecording()
            return
        }
        if (splitMidnight && dayOf(now) != sessionDay) rollSession()
    }

    private fun battery(): Int =
        (getSystemService(Context.BATTERY_SERVICE) as BatteryManager).getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)

    // ------------------------------------------------------------------ alerts

    private fun raiseAlert(title: String, text: String) {
        if (alertActive || stopRequested) return
        alertActive = true
        log(this, "ALERT", title)
        Notifier.postAlert(this, Notifier.ALERT_ID, title, text)
    }

    private fun clearAlert() {
        if (!alertActive) return
        alertActive = false
        log(this, "ALERT", "recording restored")
        Notifier.showResumed(this)
    }

    private fun cancelAlerts() {
        Notifier.cancel(this, Notifier.ALERT_ID)
        Notifier.cancel(this, Notifier.ROUTE_ALERT_ID)
        alertActive = false
    }

    // ------------------------------------------------------------------ shutdown

    private fun shutdown() {
        handler.removeCallbacks(heartbeat)
        handler.removeCallbacks(gpsOffCheck)
        stopLocation()
        unregisterMotionSensors()
        releaseWakeLock()
        running = false
        watching = false
        lowPower = false
        state = State.IDLE
        db?.close()
        db = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (!stopRequested && state == State.RECORD) log(this, "SVC", "onDestroy without stop request (killed by system?)")
        handler.removeCallbacks(heartbeat)
        stopLocation()
        unregisterMotionSensors()
        releaseWakeLock()
        running = false
        watching = false
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
            Notifier.cancel(this, Notifier.ALERT_ID)
        }
    }

    override fun onProviderDisabled(provider: String) {
        log(this, "GPS_SERVICE", "provider $provider disabled")
        if (provider == LocationManager.GPS_PROVIDER && state == State.RECORD) {
            handler.removeCallbacks(gpsOffCheck)
            handler.postDelayed(gpsOffCheck, 10_000L)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
}
