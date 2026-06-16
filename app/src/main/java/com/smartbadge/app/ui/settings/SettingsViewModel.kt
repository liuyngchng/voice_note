package com.smartbadge.app.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.smartbadge.app.core.di.AppSettings
import com.smartbadge.app.core.di.SettingsDataStore
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsDataStore: SettingsDataStore
) : ViewModel() {

    private val _uiState = MutableStateFlow(AppSettings())
    val uiState: StateFlow<AppSettings> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            settingsDataStore.settingsFlow.collect { settings ->
                _uiState.value = settings
            }
        }
    }

    fun updateAsrUrl(url: String) {
        viewModelScope.launch { settingsDataStore.updateAsrUrl(url) }
    }

    fun updateLlmUrl(url: String) {
        viewModelScope.launch { settingsDataStore.updateLlmUrl(url) }
    }

    fun updateLlmKey(key: String) {
        viewModelScope.launch { settingsDataStore.updateLlmKey(key) }
    }

    fun updateLlmModel(model: String) {
        viewModelScope.launch { settingsDataStore.updateLlmModel(model) }
    }

    fun updateLlmPrompt(prompt: String) {
        viewModelScope.launch { settingsDataStore.updateLlmPrompt(prompt) }
    }
}
