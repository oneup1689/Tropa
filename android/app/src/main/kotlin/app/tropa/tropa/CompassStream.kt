package app.tropa.tropa

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.EventChannel
import kotlin.math.abs
import kotlin.math.atan2

/**
 * Compass heading (degrees from magnetic north, 0..360) of the direction the person faces, for the "Where am I"
 * arrow when standing still. Flat phone: the top edge; phone held upright: the back camera direction.
 * Listens only while Dart is subscribed (the Map tab), so it costs nothing otherwise.
 */
class CompassStream(context: Context) : EventChannel.StreamHandler, SensorEventListener {
    private val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sink: EventChannel.EventSink? = null
    private var last = -100.0
    private val rot = FloatArray(9)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val sensor = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (sensor == null) {
            events?.endOfStream()
            return
        }
        last = -100.0
        sm.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
    }

    override fun onCancel(arguments: Any?) {
        sm.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(e: SensorEvent) {
        SensorManager.getRotationMatrixFromVector(rot, e.values)
        // World axes: x east, y north, z up. Column 1 = device top edge, column 2 = device screen normal.
        val flat = abs(rot[8]) > 0.7
        val deg = if (flat) Math.toDegrees(atan2(rot[1].toDouble(), rot[4].toDouble()))
        else Math.toDegrees(atan2(-rot[2].toDouble(), -rot[5].toDouble()))
        val h = (deg + 360.0) % 360.0
        val diff = abs(((h - last + 540.0) % 360.0) - 180.0)
        if (diff >= 3.0) {
            last = h
            sink?.success(h)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
