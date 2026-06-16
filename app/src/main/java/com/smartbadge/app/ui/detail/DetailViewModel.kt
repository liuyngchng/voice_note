package com.smartbadge.app.ui.detail

import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.smartbadge.app.core.audio.AudioFileManager
import com.smartbadge.app.domain.model.Visit
import com.smartbadge.app.domain.repository.VisitRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import javax.inject.Inject

enum class PlaybackState { IDLE, PLAYING, PAUSED }

data class DetailUiState(
    val visit: Visit? = null,
    val isLoading: Boolean = true,
    val error: String? = null,
    val playbackState: PlaybackState = PlaybackState.IDLE,
    val playbackProgress: Float = 0f,
    val playbackPositionFormatted: String = "00:00",
    val playbackDurationFormatted: String = "00:00",
    val showDeleteConfirm: Boolean = false,
    val isDeleting: Boolean = false,
    val isDeleted: Boolean = false
)

@HiltViewModel
class DetailViewModel @Inject constructor(
    application: Application,
    private val visitRepository: VisitRepository,
    private val audioFileManager: AudioFileManager
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(DetailUiState())
    val uiState: StateFlow<DetailUiState> = _uiState.asStateFlow()

    private var mediaPlayer: MediaPlayer? = null
    private var positionUpdateJob: Job? = null

    fun loadVisit(visitId: Long) {
        viewModelScope.launch {
            _uiState.value = DetailUiState(isLoading = true)
            try {
                val visit = visitRepository.getVisitById(visitId)
                _uiState.value = DetailUiState(visit = visit, isLoading = false)
            } catch (e: Exception) {
                _uiState.value = DetailUiState(isLoading = false, error = e.message)
            }
        }
    }

    fun clearError() {
        _uiState.value = _uiState.value.copy(error = null)
    }

    fun playPause() {
        val filePath = _uiState.value.visit?.audioFilePath ?: return
        if (filePath.isBlank()) return
        val file = File(filePath)
        if (!file.exists()) {
            _uiState.value = _uiState.value.copy(error = "录音文件不存在")
            return
        }

        val mp = mediaPlayer
        if (mp == null) {
            mediaPlayer = MediaPlayer().apply {
                try {
                    setDataSource(filePath)
                    setOnPreparedListener {
                        start()
                        _uiState.value = _uiState.value.copy(
                            playbackState = PlaybackState.PLAYING,
                            playbackDurationFormatted = formatDuration(it.duration / 1000L)
                        )
                        startPositionUpdates()
                    }
                    setOnCompletionListener {
                        _uiState.value = _uiState.value.copy(
                            playbackState = PlaybackState.IDLE,
                            playbackProgress = 0f,
                            playbackPositionFormatted = "00:00"
                        )
                        positionUpdateJob?.cancel()
                    }
                    setOnErrorListener { _, _, _ ->
                        _uiState.value = _uiState.value.copy(error = "播放失败")
                        releasePlayer()
                        true
                    }
                    prepareAsync()
                } catch (e: Exception) {
                    _uiState.value = _uiState.value.copy(error = "播放初始化失败")
                }
            }
        } else {
            try {
                if (mp.isPlaying) {
                    mp.pause()
                    _uiState.value = _uiState.value.copy(playbackState = PlaybackState.PAUSED)
                    positionUpdateJob?.cancel()
                } else {
                    mp.start()
                    _uiState.value = _uiState.value.copy(playbackState = PlaybackState.PLAYING)
                    startPositionUpdates()
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(error = "播放操作失败")
            }
        }
    }

    fun seekTo(fraction: Float) {
        mediaPlayer?.let { mp ->
            try {
                val position = (mp.duration * fraction).toInt()
                mp.seekTo(position)
            } catch (_: Exception) {}
        }
    }

    fun releasePlayer() {
        positionUpdateJob?.cancel()
        mediaPlayer?.release()
        mediaPlayer = null
    }

    fun shareAudio() {
        val filePath = _uiState.value.visit?.audioFilePath ?: return
        if (filePath.isBlank()) return
        val file = File(filePath)
        if (!file.exists()) {
            _uiState.value = _uiState.value.copy(error = "录音文件不存在")
            return
        }
        val context = getApplication<Application>()
        try {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "audio/wav"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(Intent.createChooser(intent, "分享录音文件"))
        } catch (e: Exception) {
            _uiState.value = _uiState.value.copy(error = "分享失败")
        }
    }

    fun showDeleteConfirm() {
        _uiState.value = _uiState.value.copy(showDeleteConfirm = true)
    }

    fun dismissDeleteConfirm() {
        _uiState.value = _uiState.value.copy(showDeleteConfirm = false)
    }

    fun deleteVisit() {
        val visit = _uiState.value.visit ?: return
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isDeleting = true)
            releasePlayer()
            audioFileManager.deleteAudioFile(visit.audioFilePath)
            visitRepository.deleteVisit(visit.id)
            _uiState.value = _uiState.value.copy(isDeleted = true, isDeleting = false)
        }
    }

    private fun startPositionUpdates() {
        positionUpdateJob?.cancel()
        positionUpdateJob = viewModelScope.launch {
            while (isActive) {
                mediaPlayer?.let { mp ->
                    if (mp.isPlaying) {
                        _uiState.value = _uiState.value.copy(
                            playbackProgress = mp.currentPosition.toFloat() / mp.duration.toFloat(),
                            playbackPositionFormatted = formatDuration(mp.currentPosition / 1000L)
                        )
                    }
                }
                delay(250)
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        releasePlayer()
    }

    private fun formatDuration(seconds: Long): String {
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return "%02d:%02d".format(m, s)
    }
}