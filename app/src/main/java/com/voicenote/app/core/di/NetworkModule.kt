package com.voicenote.app.core.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {
    // OkHttpClient instances are created within FunASRClient and LLMClient
    // as they require different timeout configurations.
    // A shared singleton can be extracted here later if needed.
}
