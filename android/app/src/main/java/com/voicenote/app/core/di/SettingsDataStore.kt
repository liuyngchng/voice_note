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
    val offlineModelQuality: String = "int8",
    // 在线 LLM 配置
    val llmApiEndpoint: String = "https://api.deepseek.com",
    val llmApiKey: String = "",
    val llmModelName: String = "deepseek-v4-flash",
    // 服务器配置
    val serverUri: String = "http://192.168.1.110:8080",
    // 登录状态
    val authToken: String = "",
    val username: String = ""
)

@Singleton
class SettingsDataStore @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private object Keys {
        val OFFLINE_MODEL_QUALITY = stringPreferencesKey("offline_model_quality")
        val LLM_API_ENDPOINT = stringPreferencesKey("llm_api_endpoint")
        val LLM_API_KEY = stringPreferencesKey("llm_api_key")
        val LLM_MODEL_NAME = stringPreferencesKey("llm_model_name")
        val SERVER_URI = stringPreferencesKey("server_uri")
        val AUTH_TOKEN = stringPreferencesKey("auth_token")
        val USERNAME = stringPreferencesKey("username")
    }

    val settingsFlow: Flow<AppSettings> = context.dataStore.data.map { prefs ->
        AppSettings(
            offlineModelQuality = prefs[Keys.OFFLINE_MODEL_QUALITY] ?: "int8",
            llmApiEndpoint = prefs[Keys.LLM_API_ENDPOINT] ?: "https://api.deepseek.com",
            llmApiKey = prefs[Keys.LLM_API_KEY] ?: "",
            llmModelName = prefs[Keys.LLM_MODEL_NAME] ?: "deepseek-v4-flash",
            serverUri = prefs[Keys.SERVER_URI] ?: "http://192.168.1.110:8080",
            authToken = prefs[Keys.AUTH_TOKEN] ?: "",
            username = prefs[Keys.USERNAME] ?: ""
        )
    }

    suspend fun updateOfflineModelQuality(quality: String) {
        context.dataStore.edit { it[Keys.OFFLINE_MODEL_QUALITY] = quality }
    }

    suspend fun updateLLMConfig(endpoint: String, apiKey: String, modelName: String) {
        context.dataStore.edit {
            it[Keys.LLM_API_ENDPOINT] = endpoint
            it[Keys.LLM_API_KEY] = apiKey
            it[Keys.LLM_MODEL_NAME] = modelName
        }
    }

    suspend fun updateServerUri(uri: String) {
        context.dataStore.edit { it[Keys.SERVER_URI] = uri }
    }

    suspend fun updateAuth(token: String, username: String) {
        context.dataStore.edit {
            it[Keys.AUTH_TOKEN] = token
            it[Keys.USERNAME] = username
        }
    }

    suspend fun clearAuth() {
        context.dataStore.edit {
            it.remove(Keys.AUTH_TOKEN)
            it.remove(Keys.USERNAME)
        }
    }
}
