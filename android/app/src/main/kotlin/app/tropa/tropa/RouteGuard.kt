package app.tropa.tropa

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sqrt

/** Follows an imported route and tells when the walker has left it (and when they are back). */
class RouteGuard(private val context: Context) {

    private var lat: DoubleArray? = null
    private var lon: DoubleArray? = null
    private var offCount = 0
    private var onCount = 0
    private var offStartWall = 0L
    private var offActive = false

    /** Distance to the route at the last evaluated fix, -1 when no route / unknown. */
    var lastDistance = -1.0
        private set

    val loaded: Boolean get() = lat != null

    /**
     * False while the walker is still on the way to the route (started recording away from it): no "left the route"
     * warnings until the route has been reached once.
     */
    var armed = true

    fun load(database: SQLiteDatabase, routeId: Long, threshold: Float) {
        clear()
        if (routeId <= 0) return
        try {
            database.rawQuery("SELECT lat, lon FROM route_points WHERE route_id=? ORDER BY idx", arrayOf(routeId.toString())).use { c ->
                val la = DoubleArray(c.count)
                val lo = DoubleArray(c.count)
                var i = 0
                while (c.moveToNext()) {
                    la[i] = c.getDouble(0)
                    lo[i] = c.getDouble(1)
                    i++
                }
                if (i >= 2) {
                    lat = la
                    lon = lo
                    TrackingDb.log(context, "NAV", "route $routeId loaded: $i points, off-route threshold ${threshold.toInt()} m")
                }
            }
        } catch (e: Exception) {
            TrackingDb.log(context, "NAV", "could not load route $routeId: $e")
        }
    }

    fun clear() {
        lat = null
        lon = null
        lastDistance = -1.0
        offActive = false
        offCount = 0
        onCount = 0
    }

    /** Distance in metres from a point to the route polyline (flat approximation, fine for a few km). */
    fun distanceTo(pLat: Double, pLon: Double): Double {
        val la = lat ?: return -1.0
        val lo = lon ?: return -1.0
        val ky = 110540.0
        val kx = 111320.0 * cos(Math.toRadians(pLat))
        var best = Double.MAX_VALUE
        for (i in 0 until la.size - 1) {
            val ax = (lo[i] - pLon) * kx
            val ay = (la[i] - pLat) * ky
            val bx = (lo[i + 1] - pLon) * kx
            val by = (la[i + 1] - pLat) * ky
            val dx = bx - ax
            val dy = by - ay
            val len2 = dx * dx + dy * dy
            val t = if (len2 == 0.0) 0.0 else ((-ax) * dx + (-ay) * dy) / len2
            val tc = t.coerceIn(0.0, 1.0)
            val px = ax + tc * dx
            val py = ay + tc * dy
            val d = sqrt(px * px + py * py)
            if (d < best) best = d
        }
        return best
    }

    /**
     * Needs 3 consecutive fixes over 15 s beyond the threshold (>= 2x accuracy) to warn; 3 fixes within 25 m to clear.
     * [onOff] gets the distance when the warning starts, [onBack] is called when the walker is back on the route.
     */
    fun evaluate(
        pLat: Double, pLon: Double, acc: Float, base: Float, movingNow: Boolean, now: Long,
        onOff: (Int) -> Unit, onBack: () -> Unit
    ) {
        val d = distanceTo(pLat, pLon)
        lastDistance = d
        val threshold = max(base, acc * 2f).toDouble()
        if (!armed) {
            if (d <= threshold) {
                armed = true
                TrackingDb.log(context, "NAV", "route reached, off-route warnings are on")
            }
            return
        }
        if (d > threshold && (movingNow || offCount > 0)) {
            if (offCount == 0) offStartWall = now
            offCount++
            onCount = 0
            if (!offActive && offCount >= 3 && now - offStartWall >= 15_000) {
                offActive = true
                TrackingDb.log(context, "NAV", "OFF ROUTE: ${d.toInt()} m from the route")
                onOff(d.toInt())
            }
        } else if (d < 25.0) {
            onCount++
            offCount = 0
            if (offActive && onCount >= 3) {
                offActive = false
                TrackingDb.log(context, "NAV", "back on route")
                onBack()
            }
        }
    }
}
