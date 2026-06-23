package com.voicenote.app.ui.detail

import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.voicenote.app.core.asr.FunASRClient
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.asr.OfflineASRClient
import com.voicenote.app.core.audio.AudioFileManager
import com.voicenote.app.core.di.SettingsDataStore
import com.voicenote.app.core.llm.LLMClient
import com.voicenote.app.core.llm.LLMModelInfo
import com.voicenote.app.core.llm.OfflineLLMClient
import com.voicenote.app.domain.model.ProcessingStatus
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.repository.VoiceRecordRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.inject.Inject

enum class PlaybackState { IDLE, PLAYING, PAUSED }

data class DetailUiState(
    val record: VoiceRecord? = null,
    val isLoading: Boolean = true,
    val error: String? = null,
    val playbackState: PlaybackState = PlaybackState.IDLE,
    val playbackProgress: Float = 0f,
    val playbackPositionFormatted: String = "00:00",
    val playbackDurationFormatted: String = "00:00",
    val showDeleteConfirm: Boolean = false,
    val isDeleting: Boolean = false,
    val isDeleted: Boolean = false,
    val showTranscriptPreview: Boolean = false,
    val aiSummaryExpanded: Boolean = false,
    val isRetryingTranscript: Boolean = false,
    val isRetryingSummary: Boolean = false
)

@HiltViewModel
class DetailViewModel @Inject constructor(
    application: Application,
    private val recordRepository: VoiceRecordRepository,
    private val audioFileManager: AudioFileManager,
    private val funASRClient: FunASRClient,
    private val offlineASRClient: OfflineASRClient,
    private val llmClient: LLMClient,
    private val offlineLLMClient: OfflineLLMClient,
    private val settingsDataStore: SettingsDataStore
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(DetailUiState())
    val uiState: StateFlow<DetailUiState> = _uiState.asStateFlow()

    private var mediaPlayer: MediaPlayer? = null
    private var positionUpdateJob: Job? = null

    fun loadRecord(recordId: Long) {
        viewModelScope.launch {
            _uiState.value = DetailUiState(isLoading = true)
            try {
                recordRepository.getRecordByIdFlow(recordId).collect { record ->
                    val duration = getFileDuration(record?.audioFilePath)
                    _uiState.value = DetailUiState(
                        record = record,
                        isLoading = false,
                        playbackDurationFormatted = duration
                    )
                }
            } catch (e: Exception) {
                _uiState.value = DetailUiState(isLoading = false, error = e.message)
            }
        }
    }

    private fun getFileDuration(filePath: String?): String {
        if (filePath.isNullOrBlank()) return "00:00"
        val file = File(filePath)
        if (!file.exists()) return "00:00"
        return try {
            val retriever = MediaMetadataRetriever()
            retriever.use {
                it.setDataSource(filePath)
                val durationMs = it.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
                formatDuration(durationMs / 1000L)
            }
        } catch (_: Exception) {
            "00:00"
        }
    }

    fun clearError() {
        _uiState.value = _uiState.value.copy(error = null)
    }

    fun playPause() {
        val filePath = _uiState.value.record?.audioFilePath ?: return
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
        val filePath = _uiState.value.record?.audioFilePath ?: return
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

    fun openTranscriptPreview() {
        _uiState.value = _uiState.value.copy(showTranscriptPreview = true)
    }

    fun dismissTranscriptPreview() {
        _uiState.value = _uiState.value.copy(showTranscriptPreview = false)
    }

    fun toggleAiSummary() {
        _uiState.value = _uiState.value.copy(aiSummaryExpanded = !_uiState.value.aiSummaryExpanded)
    }

    fun showDeleteConfirm() {
        _uiState.value = _uiState.value.copy(showDeleteConfirm = true)
    }

    fun dismissDeleteConfirm() {
        _uiState.value = _uiState.value.copy(showDeleteConfirm = false)
    }

    fun deleteRecord() {
        val record = _uiState.value.record ?: return
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isDeleting = true)
            releasePlayer()
            audioFileManager.deleteAudioFile(record.audioFilePath)
            recordRepository.deleteRecord(record.id)
            _uiState.value = _uiState.value.copy(isDeleted = true, isDeleting = false)
        }
    }

    fun skipBack() {
        mediaPlayer?.let { mp ->
            try {
                val pos = (mp.currentPosition - 15000).coerceAtLeast(0)
                mp.seekTo(pos)
                _uiState.value = _uiState.value.copy(
                    playbackProgress = pos.toFloat() / mp.duration.toFloat(),
                    playbackPositionFormatted = formatDuration(pos / 1000L)
                )
            } catch (_: Exception) {}
        }
    }

    fun skipForward() {
        mediaPlayer?.let { mp ->
            try {
                val pos = (mp.currentPosition + 15000).coerceAtMost(mp.duration)
                mp.seekTo(pos)
                _uiState.value = _uiState.value.copy(
                    playbackProgress = pos.toFloat() / mp.duration.toFloat(),
                    playbackPositionFormatted = formatDuration(pos / 1000L)
                )
            } catch (_: Exception) {}
        }
    }

    fun retryTranscript() {
        val record = _uiState.value.record ?: return
        if (_uiState.value.isRetryingTranscript) return

        val audioPath = record.audioFilePath
        if (audioPath.isBlank()) {
            _uiState.value = _uiState.value.copy(error = "没有关联的音频文件，无法重新转写")
            return
        }
        val audioFile = File(audioPath)
        if (!audioFile.exists()) {
            _uiState.value = _uiState.value.copy(error = "音频文件不存在或已被删除")
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isRetryingTranscript = true, error = null)
            recordRepository.updateTranscriptStatus(record.id, ProcessingStatus.PROCESSING)

            try {
                val settings = settingsDataStore.settingsFlow.first()
                val result = when (settings.asrMode) {
                    "offline" -> runOfflineASR(audioPath, settings.offlineModelQuality)
                    else -> funASRClient.processFile(audioPath, settings.asrUrl)
                }

                result.onSuccess { text ->
                    if (text.isNotBlank() && text != FALLBACK_TEXT) {
                        val app = getApplication<Application>()
                        val dir = File(app.filesDir, "audio/record_${record.id}")
                        dir.mkdirs()
                        val dateStr = transcriptDateFormatter.format(java.time.Instant.now())
                        val txtFile = File(dir, "$dateStr.txt")
                        txtFile.writeText(text)
                        recordRepository.updateTranscriptWithFile(record.id, text, txtFile.absolutePath)
                        _uiState.value = _uiState.value.copy(isRetryingTranscript = false)
                        refreshRecord(record.id)
                    } else {
                        recordRepository.updateTranscriptStatus(record.id, ProcessingStatus.UNAVAILABLE)
                        _uiState.value = _uiState.value.copy(isRetryingTranscript = false, error = "ASR 转写失败")
                        refreshRecord(record.id)
                    }
                }.onFailure { e ->
                    recordRepository.updateTranscriptStatus(record.id, ProcessingStatus.UNAVAILABLE)
                    _uiState.value = _uiState.value.copy(
                        isRetryingTranscript = false,
                        error = e.message ?: "ASR 转写失败"
                    )
                    refreshRecord(record.id)
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isRetryingTranscript = false,
                    error = e.message ?: "转写重试失败"
                )
            }
        }
    }

    private suspend fun runOfflineASR(audioPath: String, qualityStr: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            val quality = ModelQuality.fromString(qualityStr)
            offlineASRClient.ensureRecognizer(quality)
            val pcmData = File(audioPath).inputStream().use { input ->
                input.skip(44)
                input.readBytes()
            }
            val result = offlineASRClient.processPCMChunk(pcmData)
            offlineASRClient.reset()
            result
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun retrySummary() {
        val record = _uiState.value.record ?: return
        if (_uiState.value.isRetryingSummary) return

        val transcript = record.transcriptText
        if (transcript.isBlank() || transcript == FALLBACK_TEXT) {
            _uiState.value = _uiState.value.copy(error = "没有转写文本，无法生成总结")
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isRetryingSummary = true, error = null)
            recordRepository.updateSummaryStatus(record.id, ProcessingStatus.PROCESSING)

            try {
                val settings = settingsDataStore.settingsFlow.first()
                val llmPrompt = settings.llmPrompt.ifBlank { null }
                val result = when (settings.llmMode) {
                    "offline" -> {
                        val modelInfo = LLMModelInfo.fromString(settings.llmModelInfo)
                        offlineLLMClient.generateSummary(transcript, modelInfo, llmPrompt)
                    }
                    else -> {
                        if (settings.llmKey.isBlank()) {
                            _uiState.value = _uiState.value.copy(
                                isRetryingSummary = false,
                                error = "未配置 LLM API Key，请在设置中填写"
                            )
                            recordRepository.updateSummaryStatus(record.id, ProcessingStatus.UNAVAILABLE)
                            refreshRecord(record.id)
                            return@launch
                        }
                        llmClient.generateSummary(
                            transcript = transcript,
                            apiUrl = settings.llmUrl,
                            apiKey = settings.llmKey,
                            model = settings.llmModel,
                            customPrompt = llmPrompt
                        )
                    }
                }

                result.onSuccess { summary ->
                    recordRepository.updateSummary(record.id, summary)
                    _uiState.value = _uiState.value.copy(isRetryingSummary = false)
                    refreshRecord(record.id)
                }.onFailure { e ->
                    recordRepository.updateSummaryStatus(record.id, ProcessingStatus.UNAVAILABLE)
                    _uiState.value = _uiState.value.copy(
                        isRetryingSummary = false,
                        error = e.message ?: "AI 总结生成失败"
                    )
                    refreshRecord(record.id)
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isRetryingSummary = false,
                    error = e.message ?: "总结重试失败"
                )
            }
        }
    }

    fun shareTranscript() {
        val filePath = _uiState.value.record?.transcriptFilePath ?: return
        if (filePath.isBlank()) return
        val file = File(filePath)
        if (!file.exists()) {
            _uiState.value = _uiState.value.copy(error = "转写文件不存在")
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
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(Intent.createChooser(intent, "分享转写文件"))
        } catch (e: Exception) {
            _uiState.value = _uiState.value.copy(error = "分享失败")
        }
    }

    private suspend fun refreshRecord(recordId: Long) {
        val updated = recordRepository.getRecordById(recordId)
        if (updated != null) {
            _uiState.value = _uiState.value.copy(record = updated)
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

    companion object {
        private const val FALLBACK_TEXT = "服务暂时不可用，请采用离线方式"
        private val transcriptDateFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")
            .withZone(ZoneId.systemDefault())
    }
}