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
