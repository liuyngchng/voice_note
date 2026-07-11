package com.voicenote.app.core.di

import com.voicenote.app.data.repository.VoiceRecordRepositoryImpl
import com.voicenote.app.domain.repository.VoiceRecordRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class AppModule {

    @Binds
    @Singleton
    abstract fun bindVoiceRecordRepository(impl: VoiceRecordRepositoryImpl): VoiceRecordRepository
}
