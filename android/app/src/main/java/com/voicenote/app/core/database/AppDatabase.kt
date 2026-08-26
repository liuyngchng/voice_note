package com.voicenote.app.core.database

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [VoiceRecordEntity::class],
    version = 8,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun voiceRecordDao(): VoiceRecordDao

    companion object {
        val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE voice_records ADD COLUMN summaryJson TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE voice_records ADD COLUMN summaryStatus TEXT NOT NULL DEFAULT 'PENDING'")
                db.execSQL("ALTER TABLE voice_records ADD COLUMN summaryGeneratedAt INTEGER DEFAULT NULL")
            }
        }

        val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE voice_records ADD COLUMN serverRecordId TEXT NOT NULL DEFAULT ''")
            }
        }
    }
}
