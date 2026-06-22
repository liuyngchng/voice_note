package com.voicenote.app.core.database

import androidx.room.Database
import androidx.room.RoomDatabase

@Database(
    entities = [VoiceRecordEntity::class],
    version = 4,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun voiceRecordDao(): VoiceRecordDao
}
