package com.voicenote.app.core.di

import android.content.Context
import androidx.room.Room
import com.voicenote.app.core.database.AppDatabase
import com.voicenote.app.core.database.VoiceRecordDao
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): AppDatabase =
        Room.databaseBuilder(context, AppDatabase::class.java, "voice_note.db")
            .fallbackToDestructiveMigration()
            .build()

    @Provides
    fun provideVoiceRecordDao(database: AppDatabase): VoiceRecordDao = database.voiceRecordDao()
}
