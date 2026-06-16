package com.smartbadge.app.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.smartbadge.app.domain.model.Visit
import com.smartbadge.app.domain.repository.VisitRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import javax.inject.Inject

data class HomeUiState(
    val todayVisitCount: Int = 0,
    val todayTotalMinutes: Long = 0,
    val recentVisits: List<Visit> = emptyList(),
    val isLoading: Boolean = true
)

@HiltViewModel
class HomeViewModel @Inject constructor(
    private val visitRepository: VisitRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    init {
        loadData()
    }

    fun loadData() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true)

            visitRepository.getAllVisitsFlow().collect { visits ->
                val todayStart = Instant.now().atZone(ZoneId.systemDefault())
                    .truncatedTo(ChronoUnit.DAYS).toInstant()
                val todayVisits = visits.filter { it.startTime >= todayStart }
                val todayMinutes = todayVisits.sumOf { visit ->
                    val end = visit.endTime ?: visit.startTime
                    ChronoUnit.MINUTES.between(visit.startTime, end)
                }

                _uiState.value = HomeUiState(
                    todayVisitCount = todayVisits.size,
                    todayTotalMinutes = todayMinutes,
                    recentVisits = visits.take(20),
                    isLoading = false
                )
            }
        }
    }
}
