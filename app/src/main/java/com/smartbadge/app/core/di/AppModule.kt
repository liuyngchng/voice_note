package com.smartbadge.app.core.di

import com.smartbadge.app.data.repository.VisitRepositoryImpl
import com.smartbadge.app.domain.repository.VisitRepository
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
    abstract fun bindVisitRepository(impl: VisitRepositoryImpl): VisitRepository
}
