package app.tropa.tropa

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool

/** The short Tropa sounds (res/raw/snd_*.wav) and the "sound and vibration" mode shared by the whole app. */
object Sounds {
    const val PREF_MODE = "sound_mode"

    /** "both" (default), "sound", "vibe" or "silent". */
    fun mode(c: Context): String =
        c.getSharedPreferences(TrackingService.PREFS, Context.MODE_PRIVATE).getString(PREF_MODE, "both") ?: "both"

    fun soundOn(c: Context) = mode(c).let { it == "both" || it == "sound" }
    fun vibrationOn(c: Context) = mode(c).let { it == "both" || it == "vibe" }

    fun setMode(c: Context, mode: String) {
        c.getSharedPreferences(TrackingService.PREFS, Context.MODE_PRIVATE).edit().putString(PREF_MODE, mode).apply()
        Notifier.ensureChannels(c)
    }

    private var pool: SoundPool? = null
    private val ids = mutableMapOf<String, Int>()
    private val loaded = mutableSetOf<Int>()
    private val names = listOf("start", "stop", "back", "turn_left", "turn_right")

    private fun pool(c: Context): SoundPool {
        pool?.let { return it }
        val p = SoundPool.Builder()
            .setMaxStreams(2)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .build()
        p.setOnLoadCompleteListener { _, id, status -> if (status == 0) loaded.add(id) }
        for (n in names) {
            val res = c.resources.getIdentifier("snd_$n", "raw", c.packageName)
            if (res != 0) ids[n] = p.load(c.applicationContext, res, 1)
        }
        pool = p
        return p
    }

    /** Loads the sounds in advance so the first one is not lost. */
    fun warmUp(c: Context) {
        pool(c)
    }

    /** Plays one of the short sounds now (start, stop, back, turn_left, turn_right), if sound is on. */
    fun play(c: Context, name: String) {
        if (!soundOn(c)) return
        val p = pool(c)
        val id = ids[name] ?: return
        if (id in loaded) p.play(id, 1f, 1f, 1, 0, 1f)
    }
}
