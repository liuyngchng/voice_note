package com.smartbadge.app.ui.recording

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.smartbadge.app.core.di.SettingsDataStore
import com.smartbadge.app.core.service.RecordingService
import com.smartbadge.app.domain.model.Visit
import com.smartbadge.app.domain.repository.VisitRepository
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
    val clientName: String = "",
    val clientCompany: String = "",
    val purpose: String = "",
    val participants: String = "",
    val location: String = "获取中...",
    val currentVisitId: Long = 0,
    val isStarting: Boolean = false,
    val isStopping: Boolean = false,
    val error: String? = null
)

@HiltViewModel
class RecordingViewModel @Inject constructor(
    application: Application,
    private val visitRepository: VisitRepository,
    private val settingsDataStore: SettingsDataStore
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(RecordingUiState())
    val uiState: StateFlow<RecordingUiState> = _uiState.asStateFlow()

    fun updateClientName(name: String) { _uiState.value = _uiState.value.copy(clientName = name) }
    fun updateClientCompany(company: String) { _uiState.value = _uiState.value.copy(clientCompany = company) }
    fun updatePurpose(purpose: String) { _uiState.value = _uiState.value.copy(purpose = purpose) }
    fun updateParticipants(participants: String) { _uiState.value = _uiState.value.copy(participants = participants) }

    fun startVisit() {
        val state = _uiState.value
        if (state.clientName.isBlank()) {
            _uiState.value = state.copy(error = "请输入客户名称")
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isStarting = true, error = null)

            val settings = settingsDataStore.settingsFlow.first()

            val visit = Visit(
                clientName = state.clientName,
                clientCompany = state.clientCompany,
                purpose = state.purpose,
                participants = state.participants
                    .split(",", "，")
                    .map { it.trim() }
                    .filter { it.isNotBlank() }
            )

            val visitId = visitRepository.createVisit(visit)
            _uiState.value = _uiState.value.copy(
                currentVisitId = visitId,
                isRecording = true,
                isStarting = false
            )

            startRecordingService(visitId, settings)
        }
    }

    private fun startRecordingService(visitId: Long, settings: com.smartbadge.app.core.di.AppSettings) {
        val context = getApplication<Application>()
        val intent = Intent(context, RecordingService::class.java).apply {
            action = RecordingService.ACTION_START
            putExtra(RecordingService.EXTRA_VISIT_ID, visitId)
            putExtra(RecordingService.EXTRA_ASR_URL, settings.asrUrl)
            putExtra(RecordingService.EXTRA_LLM_URL, settings.llmUrl)
            putExtra(RecordingService.EXTRA_LLM_KEY, settings.llmKey)
            putExtra(RecordingService.EXTRA_LLM_MODEL, settings.llmModel)
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

    fun stopVisit() {
        _uiState.value = _uiState.value.copy(isStopping = true)
        val context = getApplication<Application>()
        val intent = Intent(context, RecordingService::class.java).apply {
            action = RecordingService.ACTION_STOP
        }
        context.startService(intent)
    }
}
