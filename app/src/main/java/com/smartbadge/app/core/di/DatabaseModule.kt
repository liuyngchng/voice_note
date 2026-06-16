package com.smartbadge.app.core.di

import android.content.Context
import androidx.room.Room
import com.smartbadge.app.core.database.AppDatabase
import com.smartbadge.app.core.database.VisitDao
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
        Room.databaseBuilder(context, AppDatabase::class.java, "smart_badge.db")
            .fallbackToDestructiveMigration()
            .build()

    @Provides
    fun provideVisitDao(database: AppDatabase): VisitDao = database.visitDao()
}
