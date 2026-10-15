package app.tropa.tropa

import android.content.Context

/**
 * Texts of the notifications written by the native service. The app tells the service its language
 * (the phone's setting or the person's choice in Settings); the service keeps it in its preferences,
 * so it also applies when the service starts on its own (24/7 mode, after a reboot, the planner).
 */
object Tr {
    private const val KEY_LANG = "lang"

    private val en = mapOf(
        "Запись маршрута" to "Route recording",
        "Тревоги и напоминания" to "Alerts and reminders",
        "GPS и разрешения" to "GPS and permissions",
        "Сход с маршрута" to "Leaving the route",
        "Подсказки" to "Hints",
        "GPS выключен — маршрут не пишется" to "GPS is off — the route is not being recorded",
        "Включите геолокацию, запись продолжится сама." to "Turn on location and the recording will continue by itself.",
        "Ожидание…" to "Waiting…",
        "Ожидание движения" to "Waiting for movement",
        "Вы двигаетесь, но GPS выключен" to "You are moving, but GPS is off",
        "Включите геолокацию — запись маршрута начнётся сама." to "Turn on location — the route recording will start by itself.",
        "Проверяю, началось ли движение" to "Checking whether you started moving",
        "Запись перезапущена системой" to "Recording restarted by the system",
        "В маршруте мог появиться пропуск." to "There may be a gap in the route.",
        "Идёт запись маршрута" to "Recording the route",
        "Пауза: пойдёте дальше — запись продолжится сама" to "Paused: when you walk on, recording resumes by itself",
        "Вы сошли с маршрута" to "You left the route",
        "Запись возобновлена" to "Recording resumed",
        "Запланированная прогулка" to "Scheduled walk",
        "Запись маршрута запущена автоматически." to "Route recording was started automatically.",
        "Не забудьте включить запись трека." to "Do not forget to start recording the track.",
        "Цель достигнута" to "Goal reached",
        "Половина пути" to "Halfway",
        "Половина пути пройдена" to "Halfway there",
        "Похоже, вы едете" to "It looks like you are driving",
        "Выбран режим «Пешком». Переключить на «Смешанный» (пешком и транспорт)?" to "Walk mode is selected. Switch to Mixed (walking and vehicle)?",
        "Переключить на Смешанный" to "Switch to Mixed",
        "Ждём вас у старта маршрута" to "Waiting for you at the route start",
        "Запись началась у старта" to "Recording started at the start",
        "Идите по маршруту." to "Follow the route.",
        "GPS выключен — запись не начнётся" to "GPS is off — recording will not start",
        "Включите геолокацию: приложение ждёт вас у старта маршрута." to "Turn on location: the app is waiting for you at the route start.",
    )

    fun setLanguage(ctx: Context, code: String) {
        ctx.getSharedPreferences(TrackingService.PREFS, Context.MODE_PRIVATE).edit().putString(KEY_LANG, if (code == "en") "en" else "ru").apply()
    }

    fun isEnglish(ctx: Context): Boolean =
        ctx.getSharedPreferences(TrackingService.PREFS, Context.MODE_PRIVATE).getString(KEY_LANG, "ru") == "en"

    /** The Russian text, or its English version when the app language is English. */
    fun t(ctx: Context, ru: String): String = if (isEnglish(ctx)) (en[ru] ?: ru) else ru

    fun offRoute(ctx: Context, meters: Int): String =
        if (isEnglish(ctx)) "You are $meters m from the route line." else "Вы в $meters м от линии маршрута."

    fun goalDone(ctx: Context, label: String): String =
        if (isEnglish(ctx)) "You have covered $label. Recording continues." else "Вы прошли $label. Запись продолжается."

    fun goalHalf(ctx: Context, halfLabel: String): String =
        if (isEnglish(ctx)) "Time to turn around: $halfLabel back to reach the goal." else "Пора разворачиваться: обратно ещё $halfLabel до цели."

    fun waitingStart(ctx: Context, meters: Double): String {
        val d = if (meters >= 1000) "%.1f km".format(meters / 1000) else "${meters.toInt()} m"
        return if (isEnglish(ctx)) "Waiting for you at the start: $d" else "Ждём вас у старта: ${d.replace("km", "км").replace(" m", " м")}"
    }

    fun points(ctx: Context, count: Int, km: String): String =
        if (isEnglish(ctx)) "Points: $count · $km km" else "Точек: $count · $km км"
}
