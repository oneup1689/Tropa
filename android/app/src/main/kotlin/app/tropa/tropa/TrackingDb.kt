package app.tropa.tropa

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** tropa.db access and the shared debug log, used by the tracking service and the receivers. */
object TrackingDb {

    fun open(context: Context): SQLiteDatabase {
        val path = context.getDatabasePath("tropa.db")
        path.parentFile?.mkdirs()
        val db = SQLiteDatabase.openDatabase(
            path.path, null, SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                "start_ms INTEGER NOT NULL, end_ms INTEGER, status TEXT NOT NULL, " +
                "mode TEXT NOT NULL DEFAULT 'mixed')"
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS points(id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                "session_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL, lat REAL NOT NULL, " +
                "lon REAL NOT NULL, acc REAL, alt REAL, speed REAL, pressure REAL)"
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_points_session ON points(session_id, ts_ms)")
        // Databases created by older builds miss some columns.
        ensureColumn(db, "sessions", "mode", "TEXT NOT NULL DEFAULT 'mixed'")
        ensureColumn(db, "points", "pressure", "REAL")
        if (db.version == 0) db.version = 1 // lets sqflite open the same file without re-creating
        return db
    }

    private fun ensureColumn(db: SQLiteDatabase, table: String, column: String, type: String) {
        var has = false
        db.rawQuery("PRAGMA table_info($table)", null).use { c ->
            while (c.moveToNext()) if (c.getString(1) == column) has = true
        }
        if (!has) db.execSQL("ALTER TABLE $table ADD COLUMN $column $type")
    }

    /** The log is one file: when it passes 4 MB the oldest lines are cut off (the newest ~3 MB stay). */
    private const val MAX_LOG_BYTES = 4L * 1024 * 1024
    private const val KEEP_LOG_BYTES = 3L * 1024 * 1024

    @Synchronized
    fun log(context: Context, tag: String, message: String) {
        try {
            val dir = File(context.applicationInfo.dataDir, "app_flutter")
            dir.mkdirs()
            val ts = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())
            val file = File(dir, "tropa_debug_log.txt")
            if (file.length() > MAX_LOG_BYTES) trimLog(file)
            file.appendText("$ts [$tag] $message\n")
        } catch (_: Exception) {
            // logging must never break recording
        }
    }

    private fun trimLog(file: File) {
        java.io.RandomAccessFile(file, "r").use { raf ->
            val start = (raf.length() - KEEP_LOG_BYTES).coerceAtLeast(0)
            raf.seek(start)
            val tail = ByteArray((raf.length() - start).toInt())
            raf.readFully(tail)
            val cut = tail.indexOf('\n'.code.toByte()) + 1 // start on a whole line
            val tmp = File(file.parentFile, "tropa_debug_log.tmp")
            tmp.writeBytes(tail.copyOfRange(cut, tail.size))
            if (!tmp.renameTo(file)) {
                file.writeBytes(tail.copyOfRange(cut, tail.size))
                tmp.delete()
            }
        }
    }
}
