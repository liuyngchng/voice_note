package com.voicenote.app.ui.history

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.repository.VoiceRecordRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class HistoryUiState(
    val records: List<VoiceRecord> = emptyList(),
    val searchQuery: String = "",
    val isLoading: Boolean = true
)

@HiltViewModel
class HistoryViewModel @Inject constructor(
    private val recordRepository: VoiceRecordRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(HistoryUiState())
    val uiState: StateFlow<HistoryUiState> = _uiState.asStateFlow()

    private var searchJob: Job? = null

    init {
        loadAll()
    }

    fun loadAll() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true)
            recordRepository.getAllRecordsFlow().collect { records ->
                _uiState.value = HistoryUiState(records = records, isLoading = false)
            }
        }
    }

    fun search(query: String) {
        _uiState.value = _uiState.value.copy(searchQuery = query)
        searchJob?.cancel()
        searchJob = viewModelScope.launch {
            val flow = if (query.isBlank()) {
                recordRepository.getAllRecordsFlow()
            } else {
                recordRepository.searchRecordsFlow(query)
            }
            flow.collect { records ->
                _uiState.value = _uiState.value.copy(records = records, isLoading = false)
            }
        }
    }

    fun deleteRecord(id: Long) {
        viewModelScope.launch {
            recordRepository.deleteRecord(id)
        }
    }

    fun deleteAll() {
        viewModelScope.launch {
            val ids = _uiState.value.records.map { it.id }
            ids.forEach { recordRepository.deleteRecord(it) }
        }
    }
}
