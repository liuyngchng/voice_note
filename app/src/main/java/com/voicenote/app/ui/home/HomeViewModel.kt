package com.voicenote.app.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.asr.ModelStatus
import com.voicenote.app.core.asr.OfflineASRClient
import com.voicenote.app.core.di.SettingsDataStore
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.repository.VoiceRecordRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import javax.inject.Inject

data class HomeUiState(
    val todayRecordCount: Int = 0,
    val totalRecordCount: Int = 0,
    val recentRecords: List<VoiceRecord> = emptyList(),
    val isLoading: Boolean = true,
    val modelStatus: ModelStatus = ModelStatus.UNKNOWN
)

@HiltViewModel
class HomeViewModel @Inject constructor(
    private val recordRepository: VoiceRecordRepository,
    private val offlineASRClient: OfflineASRClient,
    private val settingsDataStore: SettingsDataStore
) : ViewModel() {

    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    init {
        loadData()
        preloadModel()
    }

    /**
     * Refresh model status based on current settings.
     * Called when HomeScreen (re)enters composition to pick up
     * changes made on other screens (e.g. uploading a model in Settings).
     */
    fun refreshModelStatus() {
        viewModelScope.launch(Dispatchers.IO) {
            val settings = settingsDataStore.settingsFlow.first()
            val quality = ModelQuality.fromString(settings.offlineModelQuality)
            offlineASRClient.refreshModelStatus(quality)
        }
    }

    fun loadData() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true)

            recordRepository.getAllRecordsFlow().collect { records ->
                val todayStart = Instant.now().atZone(ZoneId.systemDefault())
                    .truncatedTo(ChronoUnit.DAYS).toInstant()
                val todayRecords = records.filter { it.startTime >= todayStart }
                _uiState.value = _uiState.value.copy(
                    todayRecordCount = todayRecords.size,
                    totalRecordCount = records.size,
                    recentRecords = records.take(2),
                    isLoading = false
                )
            }
        }
    }

    private fun preloadModel() {
        viewModelScope.launch(Dispatchers.IO) {
            val settings = settingsDataStore.settingsFlow.first()
            val quality = ModelQuality.fromString(settings.offlineModelQuality)
            offlineASRClient.preloadIfAvailable(quality)
        }
        viewModelScope.launch {
            offlineASRClient.modelStatus.collect { status ->
                _uiState.value = _uiState.value.copy(modelStatus = status)
            }
        }
    }
}
