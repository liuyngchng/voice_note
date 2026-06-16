package com.smartbadge.app.core.di

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
    val asrUrl: String = "ws://192.168.27.29:10095",
    val llmUrl: String = "https://api.deepseek.com/chat/completions",
    val llmKey: String = "sk-0220a5e0d8ff4d39828859be52563df1",
    val llmModel: String = "deepseek-v4-pro",
    val llmPrompt: String = ""
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
    }

    val settingsFlow: Flow<AppSettings> = context.dataStore.data.map { prefs ->
        AppSettings(
            asrUrl = prefs[Keys.ASR_URL] ?: "ws://192.168.27.29:10095",
            llmUrl = prefs[Keys.LLM_URL] ?: "https://api.deepseek.com/v1/chat/completions",
            llmKey = prefs[Keys.LLM_KEY] ?: "sk-0220a5e0d8ff4d39828859be52563df1",
            llmModel = prefs[Keys.LLM_MODEL] ?: "deepseek-v4-pro",
            llmPrompt = prefs[Keys.LLM_PROMPT] ?: ""
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
}
