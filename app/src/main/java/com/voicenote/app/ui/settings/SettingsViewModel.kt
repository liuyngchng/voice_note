package com.voicenote.app.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voicenote.app.core.di.AppSettings
import com.voicenote.app.core.di.SettingsDataStore
import com.voicenote.app.core.network.ConnectivityChecker
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

data class TestResult(
    val name: String,
    val success: Boolean,
    val message: String
)

data class SettingsUiState(
    val asrUrl: String = "",
    val llmUrl: String = "",
    val llmKey: String = "",
    val llmModel: String = "",
    val llmPrompt: String = "",
    val asrMode: String = "online",
    val offlineModelQuality: String = "int8",
    val llmMode: String = "online",
    val llmModelInfo: String = "qwen2_5_0_5b_q4km",
    val isTesting: Boolean = false,
    val testResults: List<TestResult> = emptyList(),
    val showResults: Boolean = false
)

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsDataStore: SettingsDataStore,
    private val connectivityChecker: ConnectivityChecker
) : ViewModel() {

    private val _uiState = MutableStateFlow(SettingsUiState())
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            settingsDataStore.settingsFlow.collect { settings ->
                _uiState.value = _uiState.value.copy(
                    asrUrl = settings.asrUrl,
                    llmUrl = settings.llmUrl,
                    llmKey = settings.llmKey,
                    llmModel = settings.llmModel,
                    llmPrompt = settings.llmPrompt,
                    asrMode = settings.asrMode,
                    offlineModelQuality = settings.offlineModelQuality,
                    llmMode = settings.llmMode,
                    llmModelInfo = settings.llmModelInfo
                )
            }
        }
    }

    fun updateAsrUrl(url: String) {
        _uiState.value = _uiState.value.copy(asrUrl = url)
    }

    fun updateLlmUrl(url: String) {
        _uiState.value = _uiState.value.copy(llmUrl = url)
    }

    fun updateLlmKey(key: String) {
        _uiState.value = _uiState.value.copy(llmKey = key)
    }

    fun updateLlmModel(model: String) {
        _uiState.value = _uiState.value.copy(llmModel = model)
    }

    fun updateLlmPrompt(prompt: String) {
        _uiState.value = _uiState.value.copy(llmPrompt = prompt)
    }

    fun updateAsrMode(mode: String) {
        _uiState.value = _uiState.value.copy(asrMode = mode)
        viewModelScope.launch { settingsDataStore.updateAsrMode(mode) }
    }

    fun updateOfflineModelQuality(quality: String) {
        _uiState.value = _uiState.value.copy(offlineModelQuality = quality)
        viewModelScope.launch { settingsDataStore.updateOfflineModelQuality(quality) }
    }

    fun updateLlmMode(mode: String) {
        _uiState.value = _uiState.value.copy(llmMode = mode)
        viewModelScope.launch { settingsDataStore.updateLlmMode(mode) }
    }

    fun updateLlmModelInfo(info: String) {
        _uiState.value = _uiState.value.copy(llmModelInfo = info)
        viewModelScope.launch { settingsDataStore.updateLlmModelInfo(info) }
    }

    fun save() {
        val state = _uiState.value
        viewModelScope.launch {
            settingsDataStore.updateAsrUrl(state.asrUrl)
            settingsDataStore.updateLlmUrl(state.llmUrl)
            settingsDataStore.updateLlmKey(state.llmKey)
            settingsDataStore.updateLlmModel(state.llmModel)
            settingsDataStore.updateLlmPrompt(state.llmPrompt)
            settingsDataStore.updateAsrMode(state.asrMode)
            settingsDataStore.updateOfflineModelQuality(state.offlineModelQuality)
            settingsDataStore.updateLlmMode(state.llmMode)
            settingsDataStore.updateLlmModelInfo(state.llmModelInfo)
        }
    }

    fun testConnection() {
        val state = _uiState.value
        _uiState.value = state.copy(isTesting = true, testResults = emptyList(), showResults = false)

        viewModelScope.launch {
            val asrDeferred = if (state.asrMode == "online") {
                async {
                    val result = connectivityChecker.checkAsrConnection(state.asrUrl)
                    TestResult(
                        name = "语音识别",
                        success = result.isSuccess,
                        message = result.getOrElse { it.message ?: "未知错误" }
                    )
                }
            } else null

            val llmDeferred = if (state.llmMode == "online") {
                async {
                    val result = connectivityChecker.checkLlmConnection(
                        state.llmUrl,
                        state.llmKey,
                        state.llmModel
                    )
                    TestResult(
                        name = "AI 总结",
                        success = result.isSuccess,
                        message = result.getOrElse { it.message ?: "未知错误" }
                    )
                }
            } else null

            val results = listOfNotNull(asrDeferred?.await(), llmDeferred?.await())

            _uiState.value = _uiState.value.copy(
                isTesting = false,
                testResults = results,
                showResults = true
            )
        }
    }

    fun dismissResults() {
        _uiState.value = _uiState.value.copy(showResults = false, testResults = emptyList())
    }
}