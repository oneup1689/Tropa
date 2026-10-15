package app.tropa.tropa

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.speech.tts.TextToSpeech
import java.util.Locale

/** Voice prompts (system speech synthesis, no extra files) and vibration patterns of the navigator. */
object Speaker {
    private var tts: TextToSpeech? = null
    private var ready = false
    private var failed = false
    private val waiting = mutableListOf<() -> Unit>()

    private fun withEngine(ctx: Context, then: () -> Unit) {
        if (ready || failed) {
            then()
            return
        }
        waiting.add(then)
        if (tts != null) return
        tts = TextToSpeech(ctx.applicationContext) { status ->
            ready = status == TextToSpeech.SUCCESS
            failed = !ready
            val todo = waiting.toList()
            waiting.clear()
            todo.forEach { it() }
        }
    }

    private fun locale(lang: String) = if (lang == "en") Locale.ENGLISH else Locale("ru")

    /** "ok", "missing" (language voice not installed) or "none" (no speech engine at all). */
    fun status(ctx: Context, lang: String, done: (String) -> Unit) = withEngine(ctx) {
        val t = tts
        if (!ready || t == null) {
            done("none")
            return@withEngine
        }
        val r = t.isLanguageAvailable(locale(lang))
        done(if (r >= TextToSpeech.LANG_AVAILABLE) "ok" else "missing")
    }

    fun speak(ctx: Context, text: String, lang: String) = withEngine(ctx) {
        if (!Sounds.soundOn(ctx)) return@withEngine
        val t = tts ?: return@withEngine
        if (!ready) return@withEngine
        t.language = locale(lang)
        t.speak(text, TextToSpeech.QUEUE_FLUSH, null, "nav")
    }

    fun stop() {
        tts?.stop()
    }

    /** Opens the system screen to install voice data for the speech engine. */
    fun openInstall(ctx: Context) {
        val i = Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(i)
        } catch (e: Exception) {
            TrackingDb.log(ctx, "NAV", "cannot open voice install: $e")
        }
    }

    fun vibrate(ctx: Context, pattern: LongArray) {
        if (!Sounds.vibrationOn(ctx)) return
        val v = ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        if (!v.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= 26) v.vibrate(VibrationEffect.createWaveform(pattern, -1))
        else @Suppress("DEPRECATION") v.vibrate(pattern, -1)
    }
}
