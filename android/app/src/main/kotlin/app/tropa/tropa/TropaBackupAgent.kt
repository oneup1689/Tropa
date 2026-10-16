package app.tropa.tropa

import android.app.backup.BackupAgent
import android.app.backup.BackupDataInput
import android.app.backup.BackupDataOutput
import android.app.backup.FullBackupDataOutput
import android.os.ParcelFileDescriptor

/**
 * Android's automatic backup (to the person's own Google Drive, or phone-to-phone transfer) copies the walks database.
 * It is off by default: the walks contain places where the person lives and walks. Settings → "Копия в аккаунте Google"
 * turns it on; the rules in res/xml say that only tropa.db is copied.
 */
class TropaBackupAgent : BackupAgent() {

    override fun onFullBackup(data: FullBackupDataOutput) {
        val enabled = getSharedPreferences(TrackingService.PREFS, MODE_PRIVATE).getBoolean(KEY_CLOUD_BACKUP, false)
        if (!enabled) {
            TrackingDb.log(this, "BACKUP", "system backup skipped: switched off in the settings")
            return
        }
        TrackingDb.log(this, "BACKUP", "system backup of the walks database")
        super.onFullBackup(data)
    }

    // Only the full (file) backup is used.
    override fun onBackup(oldState: ParcelFileDescriptor?, data: BackupDataOutput?, newState: ParcelFileDescriptor?) {}

    override fun onRestore(data: BackupDataInput?, appVersionCode: Int, newState: ParcelFileDescriptor?) {}

    companion object {
        const val KEY_CLOUD_BACKUP = "cloud_backup"
    }
}
