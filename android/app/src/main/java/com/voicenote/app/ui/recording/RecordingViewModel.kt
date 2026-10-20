package com.voicenote.app.ui.recording

import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
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
import java.time.ZoneId
import java.time.format.DateTimeFormatter
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
    val statusMessage: String = "",
    val error: String? = null,
    val showBatteryOptDialog: Boolean = false,
    val batteryOptimizationDisabled: Boolean = false,
    val audioLevelHistory: List<Float> = emptyList(),
    val captureSystemAudio: Boolean = false,
    val needsMediaProjection: Boolean = false
)

@HiltViewModel
class RecordingViewModel @Inject constructor(
    application: Application,
    private val recordRepository: VoiceRecordRepository,
    private val settingsDataStore: SettingsDataStore
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(RecordingUiState())
    val uiState: StateFlow<RecordingUiState> = _uiState.asStateFlow()

    private var pendingMediaProjectionResultCode: Int = -1
    private var pendingMediaProjectionData: Intent? = null
    private var pendingOfflineModelQuality: String = "int8"

    fun updateTitle(title: String) { _uiState.value = _uiState.value.copy(title = title) }
    fun updateMemo(memo: String) { _uiState.value = _uiState.value.copy(memo = memo) }
    fun updateDescription(description: String) { _uiState.value = _uiState.value.copy(description = description) }
    fun updateSpeakers(speakers: String) { _uiState.value = _uiState.value.copy(speakers = speakers) }

    /**
     * Handle MediaProjection authorization result.
     * Called from RecordingScreen after the system dialog is dismissed.
     */
    fun onMediaProjectionResult(resultCode: Int, data: Intent?) {
        if (resultCode == android.app.Activity.RESULT_OK && data != null) {
            pendingMediaProjectionResultCode = resultCode
            pendingMediaProjectionData = data
            // Now actually start recording with system audio capture
            startRecordingInternal()
        } else {
            // User denied MediaProjection — start with mic-only
            pendingMediaProjectionResultCode = -1
            pendingMediaProjectionData = null
            _uiState.value = _uiState.value.copy(captureSystemAudio = false)
            startRecordingInternal()
        }
    }

    fun startRecording() {
        val state = _uiState.value

        // Guard: prevent duplicate recording if the service is already recording.
        // RecordingService.isRecording is the global source of truth and survives
        // ViewModel recreation (e.g. app backgrounded/foregrounded).
        if (state.isRecording || RecordingService.isRecording.value) {
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isStarting = true, error = null)

            val settings = settingsDataStore.settingsFlow.first()

            _uiState.value = _uiState.value.copy(
                captureSystemAudio = settings.captureSystemAudio
            )
            pendingOfflineModelQuality = settings.offlineModelQuality

            val title = state.title.trim().ifBlank {
                "新录音 ${dateFormatter.format(java.time.Instant.now())}"
            }

            val record = VoiceRecord(
                title = title,
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
                isRecording = true
            )

            // If system audio capture is enabled and device supports it, request
            // MediaProjection first. The recording will start after authorization.
            if (settings.captureSystemAudio &&
                android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q
            ) {
                _uiState.value = _uiState.value.copy(
                    needsMediaProjection = true,
                    isStarting = false
                )
            } else {
                pendingMediaProjectionResultCode = -1
                pendingMediaProjectionData = null
                startRecordingInternal()
            }
        }
    }

    private fun startRecordingInternal() {
        val state = _uiState.value
        _uiState.value = state.copy(needsMediaProjection = false)

        startRecordingService(
            state.currentRecordId,
            state.captureSystemAudio,
            pendingMediaProjectionResultCode,
            pendingMediaProjectionData
        )
    }

    private fun startRecordingService(
        recordId: Long,
        captureSystemAudio: Boolean,
        mediaProjectionResultCode: Int = -1,
        mediaProjectionData: Intent? = null
    ) {
        val context = getApplication<Application>()
        val intent = Intent(context, RecordingService::class.java).apply {
            action = RecordingService.ACTION_START
            putExtra(RecordingService.EXTRA_RECORD_ID, recordId)
            putExtra(RecordingService.EXTRA_CAPTURE_SYSTEM_AUDIO, captureSystemAudio)
            putExtra(RecordingService.EXTRA_OFFLINE_MODEL_QUALITY, pendingOfflineModelQuality)
        }
        if (mediaProjectionResultCode >= 0 && mediaProjectionData != null) {
            intent.putExtra(RecordingService.EXTRA_MEDIA_PROJECTION_RESULT_CODE,
                mediaProjectionResultCode)
            intent.putExtra(RecordingService.EXTRA_MEDIA_PROJECTION_DATA,
                mediaProjectionData)
        }
        try {
            context.startForegroundService(intent)
        } catch (e: Exception) {
            _uiState.value = _uiState.value.copy(
                isRecording = false,
                isStarting = false,
                error = "启动录音失败: ${e.message}"
            )
            return
        }

        observeServiceState()
    }

    fun stopRecording() {
        _uiState.value = _uiState.value.copy(isStopping = true)
        val context = getApplication<Application>()
        val intent = Intent(context, RecordingService::class.java).apply {
            action = RecordingService.ACTION_STOP
        }
        context.startService(intent)
    }

    fun checkBatteryOptimization() {
        val context = getApplication<Application>()
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val isIgnoring = powerManager.isIgnoringBatteryOptimizations(context.packageName)
        _uiState.value = _uiState.value.copy(
            batteryOptimizationDisabled = isIgnoring,
            showBatteryOptDialog = !isIgnoring
        )
    }

    fun dismissBatteryOptDialog() {
        _uiState.value = _uiState.value.copy(showBatteryOptDialog = false)
    }

    fun openBatteryOptimizationSettings() {
        val context = getApplication<Application>()
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:${context.packageName}")
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            if (intent.resolveActivity(context.packageManager) != null) {
                context.startActivity(intent)
            } else {
                // Fallback: open app's battery optimization settings page
                val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${context.packageName}")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(fallback)
            }
        } catch (e: Exception) {
            // Last resort: open app info page
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try { context.startActivity(fallback) } catch (_: Exception) {}
        }
    }

    fun reconnect(recordId: Long) {
        _uiState.value = _uiState.value.copy(
            currentRecordId = recordId,
            isRecording = true
        )
        observeServiceState()
    }

    private fun observeServiceState() {
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
        viewModelScope.launch {
            RecordingService.statusMessage.collect { msg ->
                _uiState.value = _uiState.value.copy(statusMessage = msg)
            }
        }
        // Accumulate audio level history for waveform visualization
        viewModelScope.launch {
            RecordingService.audioLevel.collect { level ->
                val current = _uiState.value
                val history = current.audioLevelHistory.toMutableList()
                history.add(level)
                // Keep last 50 samples (~10 seconds at 5Hz)
                if (history.size > 50) {
                    history.removeAt(0)
                }
                _uiState.value = current.copy(audioLevelHistory = history)
            }
        }
    }

    companion object {
        private val dateFormatter = DateTimeFormatter.ofPattern("M月d日 HH:mm")
            .withZone(ZoneId.systemDefault())
    }
}