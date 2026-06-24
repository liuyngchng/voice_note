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
    val asrUrl: String = "ws://192.168.240.29:10095",
    val llmUrl: String = "https://api.deepseek.com",
    val llmKey: String = "",
    val llmModel: String = "deepseek-v4-pro",
    val llmPrompt: String = "",
    val asrMode: String = "offline",
    val offlineModelQuality: String = "int8",
    val llmMode: String = "offline",
    val llmModelInfo: String = "qwen2_5_0_5b_q4km"
)

@Singleton
class SettingsDataStore @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private object Keys {
        val ASR_URL = stringPreferencesKey("asr_url")
        val LLM_URL = stringPreferencesKey("llm_url")
        val LLM_KEY = stringPreferencesKey("llm_key")
        val LLM_MODEL = stringPreferencesKey("llm_model")
        val LLM_PROMPT = stringPreferencesKey("llm_prompt")
        val ASR_MODE = stringPreferencesKey("asr_mode")
        val OFFLINE_MODEL_QUALITY = stringPreferencesKey("offline_model_quality")
        val LLM_MODE = stringPreferencesKey("llm_mode")
        val LLM_MODEL_INFO = stringPreferencesKey("llm_model_info")
    }

    val settingsFlow: Flow<AppSettings> = context.dataStore.data.map { prefs ->
        AppSettings(
            asrUrl = prefs[Keys.ASR_URL] ?: "ws://192.168.240.29:10095",
            llmUrl = prefs[Keys.LLM_URL] ?: "https://api.deepseek.com",
            llmKey = prefs[Keys.LLM_KEY] ?: "",
            llmModel = prefs[Keys.LLM_MODEL] ?: "deepseek-v4-pro",
            llmPrompt = prefs[Keys.LLM_PROMPT] ?: "",
            asrMode = prefs[Keys.ASR_MODE] ?: "offline",
            offlineModelQuality = prefs[Keys.OFFLINE_MODEL_QUALITY] ?: "int8",
            llmMode = prefs[Keys.LLM_MODE] ?: "offline",
            llmModelInfo = prefs[Keys.LLM_MODEL_INFO] ?: "qwen2_5_0_5b_q4km"
        )
    }

    suspend fun updateAsrUrl(url: String) {
        context.dataStore.edit { it[Keys.ASR_URL] = url }
    }

    suspend fun updateLlmUrl(url: String) {
        context.dataStore.edit { it[Keys.LLM_URL] = url }
    }

    suspend fun updateLlmKey(key: String) {
        context.dataStore.edit { it[Keys.LLM_KEY] = key }
    }

    suspend fun updateLlmModel(model: String) {
        context.dataStore.edit { it[Keys.LLM_MODEL] = model }
    }

    suspend fun updateLlmPrompt(prompt: String) {
        context.dataStore.edit { it[Keys.LLM_PROMPT] = prompt }
    }

    suspend fun updateAsrMode(mode: String) {
        context.dataStore.edit { it[Keys.ASR_MODE] = mode }
    }

    suspend fun updateOfflineModelQuality(quality: String) {
        context.dataStore.edit { it[Keys.OFFLINE_MODEL_QUALITY] = quality }
    }

    suspend fun updateLlmMode(mode: String) {
        context.dataStore.edit { it[Keys.LLM_MODE] = mode }
    }

    suspend fun updateLlmModelInfo(info: String) {
        context.dataStore.edit { it[Keys.LLM_MODEL_INFO] = info }
    }
}
