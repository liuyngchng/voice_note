package com.voicenote.app.core.di

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "settings")

data class AppSettings(
    val offlineModelQuality: String = "int8"
)

@Singleton
class SettingsDataStore @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private object Keys {
        val OFFLINE_MODEL_QUALITY = stringPreferencesKey("offline_model_quality")
    }

    val settingsFlow: Flow<AppSettings> = context.dataStore.data.map { prefs ->
        AppSettings(
            offlineModelQuality = prefs[Keys.OFFLINE_MODEL_QUALITY] ?: "int8"
        )
    }

    suspend fun updateOfflineModelQuality(quality: String) {
        context.dataStore.edit { it[Keys.OFFLINE_MODEL_QUALITY] = quality }
    }
}
