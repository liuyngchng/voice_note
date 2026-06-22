package com.voicenote.app.ui.recording

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.voicenote.app.core.di.SettingsDataStore
import com.voicenote.app.core.service.RecordingService
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.repository.VoiceRecordRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

data class RecordingUiState(
    val isRecording: Boolean = false,
    val durationSeconds: Long = 0,
    val transcript: String = "",
    val title: String = "",
    val memo: String = "",
    val description: String = "",
    val speakers: String = "",
    val currentRecordId: Long = 0,
    val isStarting: Boolean = false,
    val isStopping: Boolean = false,
    val error: String? = null
)

@HiltViewModel
class RecordingViewModel @Inject constructor(
    application: Application,
    private val recordRepository: VoiceRecordRepository,
    private val settingsDataStore: SettingsDataStore
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(RecordingUiState())
    val uiState: StateFlow<RecordingUiState> = _uiState.asStateFlow()

    fun updateTitle(title: String) { _uiState.value = _uiState.value.copy(title = title) }
    fun updateMemo(memo: String) { _uiState.value = _uiState.value.copy(memo = memo) }
    fun updateDescription(description: String) { _uiState.value = _uiState.value.copy(description = description) }
    fun updateSpeakers(speakers: String) { _uiState.value = _uiState.value.copy(speakers = speakers) }

    fun startRecording() {
        val state = _uiState.value
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isStarting = true, error = null)

            val settings = settingsDataStore.settingsFlow.first()

            val record = VoiceRecord(
                title = state.title,
                memo = state.memo,
                description = state.description,
                speakers = state.speakers
                    .split(",", "，")
                    .map { it.trim() }
                    .filter { it.isNotBlank() }
            )

            val recordId = recordRepository.createRecord(record)
            _uiState.value = _uiState.value.copy(
                currentRecordId = recordId,
                isRecording = true,
                isStarting = false
            )

            startRecordingService(recordId, settings)
        }
    }

    private fun startRecordingService(recordId: Long, settings: com.voicenote.app.core.di.AppSettings) {
        val context = getApplication<Application>()
        val intent = Intent(context, RecordingService::class.java).apply {
            action = RecordingService.ACTION_START
            putExtra(RecordingService.EXTRA_RECORD_ID, recordId)
            putExtra(RecordingService.EXTRA_ASR_URL, settings.asrUrl)
            putExtra(RecordingService.EXTRA_LLM_URL, settings.llmUrl)
            putExtra(RecordingService.EXTRA_LLM_KEY, settings.llmKey)
            putExtra(RecordingService.EXTRA_LLM_MODEL, settings.llmModel)
            putExtra(RecordingService.EXTRA_ASR_MODE, settings.asrMode)
            putExtra(RecordingService.EXTRA_LLM_MODE, settings.llmMode)
            putExtra(RecordingService.EXTRA_LLM_MODEL_INFO, settings.llmModelInfo)
            if (settings.llmPrompt.isNotBlank()) {
                putExtra(RecordingService.EXTRA_LLM_PROMPT, settings.llmPrompt)
            }
        }
        context.startForegroundService(intent)

        // Observe service state
        viewModelScope.launch {
            RecordingService.transcriptState.collect { text ->
                _uiState.value = _uiState.value.copy(transcript = text)
            }
        }
        viewModelScope.launch {
            RecordingService.durationSeconds.collect { seconds ->
                _uiState.value = _uiState.value.copy(durationSeconds = seconds)
            }
        }
        viewModelScope.launch {
            RecordingService.isRecording.collect { recording ->
                _uiState.value = _uiState.value.copy(isRecording = recording)
                if (!recording) {
                    _uiState.value = _uiState.value.copy(isStopping = false)
                }
            }
        }
    }

    fun stopRecording() {
        _uiState.value = _uiState.value.copy(isStopping = true)
        val context = getApplication<Application>()
        val intent = Intent(context, RecordingService::class.java).apply {
            action = RecordingService.ACTION_STOP
        }
        context.startService(intent)
    }
}
