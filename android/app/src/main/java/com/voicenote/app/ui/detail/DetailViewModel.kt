package com.voicenote.app.ui.detail

import android.app.Application
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.voicenote.app.core.audio.AudioFileManager
import com.voicenote.app.core.audio.AudioImporter
import com.voicenote.app.core.di.SettingsDataStore
import com.voicenote.app.core.llm.LLMConfig
import com.voicenote.app.core.network.ServerClient
import com.voicenote.app.domain.model.ProcessingStatus
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.repository.VoiceRecordRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import android.util.Log
import java.io.File
import javax.inject.Inject

// ── 对外统一状态（UI 层不感知子 Controller 拆分）─────────────────────────

data class DetailUiState(
    val record: VoiceRecord? = null,
    val isLoading: Boolean = true,
    val error: String? = null,
    // Playback
    val playbackState: PlaybackState = PlaybackState.IDLE,
    val playbackProgress: Float = 0f,
    val playbackPositionFormatted: String = "00:00",
    val playbackDurationFormatted: String = "00:00",
    // Delete
    val showDeleteConfirm: Boolean = false,
    val isDeleting: Boolean = false,
    val isDeleted: Boolean = false,
    // Transcript
    val showRegenerateConfirm: Boolean = false,
    val showTranscriptPreview: Boolean = false,
    val transcriptPreviewText: String = "",
    val isRetryingTranscript: Boolean = false,
    val retryProgress: String = "",
    // Summary
    val isGeneratingSummary: Boolean = false,
    val summaryProgressMessage: String = "",
    val summaryError: String? = null,
    // Upload
    val isUploadingToServer: Boolean = false,
    val uploadProgressMessage: String = "",
    val uploadError: String? = null,
    val showUploadConfirm: Boolean = false,
    // Export
    val isExporting: Boolean = false,
    val exportMessage: String? = null
)

@HiltViewModel
class DetailViewModel @Inject constructor(
    application: Application,
    private val recordRepository: VoiceRecordRepository,
    private val audioFileManager: AudioFileManager,
    private val audioImporter: AudioImporter,
    private val settingsDataStore: SettingsDataStore,
    serverClient: ServerClient,
    // ── 子 Controller 依赖 ─────────────────────────────────────────────
    offlineASRClient: com.voicenote.app.core.asr.OfflineASRClient,
    asrModelManager: com.voicenote.app.core.asr.ASRModelManager
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(DetailUiState())
    val uiState: StateFlow<DetailUiState> = _uiState.asStateFlow()

    // ── 子 Controller ──────────────────────────────────────────────────

    val playback = PlaybackController(viewModelScope)
    val transcript = TranscriptController(
        getApplication(), viewModelScope, recordRepository,
        offlineASRClient, asrModelManager
    )
    val summaryCtl = SummaryController(viewModelScope, recordRepository)
    val uploadCtl = UploadController(viewModelScope, recordRepository, serverClient, settingsDataStore)

    init {
        // 聚合子 Controller 状态到统一的 DetailUiState
        viewModelScope.launch {
            playback.state.collect { ps ->
                _uiState.value = _uiState.value.copy(
                    playbackState = ps.state,
                    playbackProgress = ps.progress,
                    playbackPositionFormatted = ps.positionFormatted,
                    playbackDurationFormatted = ps.durationFormatted
                )
            }
        }
        viewModelScope.launch {
            transcript.state.collect { ts ->
                _uiState.value = _uiState.value.copy(
                    isRetryingTranscript = ts.isRetrying,
                    retryProgress = ts.progress,
                    showRegenerateConfirm = ts.showRegenerateConfirm
                )
                if (ts.error != null) _uiState.value = _uiState.value.copy(error = ts.error)
            }
        }
        viewModelScope.launch {
            summaryCtl.state.collect { ss ->
                _uiState.value = _uiState.value.copy(
                    isGeneratingSummary = ss.isGenerating,
                    summaryProgressMessage = ss.progressMessage,
                    summaryError = ss.error
                )
            }
        }
        viewModelScope.launch {
            uploadCtl.state.collect { us ->
                _uiState.value = _uiState.value.copy(
                    isUploadingToServer = us.isUploading,
                    uploadProgressMessage = us.progressMessage,
                    uploadError = us.error,
                    showUploadConfirm = us.showConfirm
                )
            }
        }
    }

    // ── Load / Refresh ──────────────────────────────────────────────────

    fun loadRecord(recordId: Long) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true)
            try {
                recordRepository.getRecordByIdFlow(recordId).collect { record ->
                    val duration = playback.loadFile(record?.audioFilePath)
                    _uiState.value = _uiState.value.copy(
                        record = record,
                        isLoading = false,
                        playbackDurationFormatted = duration
                    )
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(isLoading = false, error = e.message)
            }
        }
    }

    fun clearError() { _uiState.value = _uiState.value.copy(error = null) }

    // ── Playback (delegate) ─────────────────────────────────────────────

    fun playPause() = playback.playPause()
    fun seekTo(fraction: Float) = playback.seekTo(fraction)
    fun skipBack() = playback.skipBack()
    fun skipForward() = playback.skipForward()
    fun releasePlayer() = playback.release()

    // ── Share ───────────────────────────────────────────────────────────

    fun shareAudio() {
        val filePath = _uiState.value.record?.audioFilePath ?: return
        if (filePath.isBlank()) return
        val file = File(filePath)
        if (!file.exists()) { _uiState.value = _uiState.value.copy(error = "录音文件不存在"); return }
        val context = getApplication<Application>()
        try {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "audio/wav"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "分享录音文件").apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
        } catch (e: Exception) { _uiState.value = _uiState.value.copy(error = "分享失败") }
    }

    fun shareTranscript() {
        val filePath = _uiState.value.record?.transcriptFilePath ?: return
        if (filePath.isBlank()) return
        val file = File(filePath)
        if (!file.exists()) { _uiState.value = _uiState.value.copy(error = "转写文件不存在"); return }
        val context = getApplication<Application>()
        try {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "分享转写文件").apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
        } catch (e: Exception) { _uiState.value = _uiState.value.copy(error = "分享失败") }
    }

    fun shareSummary() {
        val record = _uiState.value.record ?: return
        val summary = record.summary ?: return
        val text = formatSummaryAsText(summary)
        if (text.isBlank()) return
        val context = getApplication<Application>()
        try {
            val fileName = "总结_${record.title.replace("/", "_")}.txt"
            val file = File(context.cacheDir, fileName)
            file.writeText(text)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "分享总结").apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
        } catch (e: Exception) { _uiState.value = _uiState.value.copy(error = "分享失败") }
    }

    // ── Export to public storage ─────────────────────────────────────────

    /**
     * Copy the recording to the public Downloads/VoiceNote/ directory so it is
     * visible when the phone is connected to a computer. Result is surfaced via
     * a one-shot [exportMessage] in the UI state (shown as a snackbar).
     */
    fun exportAudio() {
        val record = _uiState.value.record ?: return
        if (_uiState.value.isExporting) return
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isExporting = true)
            val result = audioFileManager.exportToDownloads(record.audioFilePath)
            result.onSuccess { message ->
                _uiState.value = _uiState.value.copy(exportMessage = message)
            }.onFailure { e ->
                val msg = when (e) {
                    is UnsupportedOperationException -> e.message
                    else -> "导出失败: ${e.message}"
                }
                _uiState.value = _uiState.value.copy(exportMessage = msg)
            }
            _uiState.value = _uiState.value.copy(isExporting = false)
        }
    }

    fun dismissExportMessage() { _uiState.value = _uiState.value.copy(exportMessage = null) }

    // ── Transcript (delegate) ───────────────────────────────────────────

    fun openTranscriptPreview() {
        val path = _uiState.value.record?.transcriptFilePath ?: return
        if (path.isBlank()) return
        viewModelScope.launch(Dispatchers.IO) {
            val text = try { File(path).readText() } catch (e: Exception) { "" }
            _uiState.value = _uiState.value.copy(showTranscriptPreview = true, transcriptPreviewText = text)
        }
    }

    fun dismissTranscriptPreview() { _uiState.value = _uiState.value.copy(showTranscriptPreview = false, transcriptPreviewText = "") }
    fun showRegenerateConfirm() = transcript.showRegenerateConfirm()
    fun dismissRegenerateConfirm() = transcript.dismissRegenerateConfirm()

    fun retryTranscript() {
        val record = _uiState.value.record ?: return
        transcript.retry(record.id, record.audioFilePath)
    }

    fun cancelRetryTranscript() { transcript.cancel() }

    // ── AI Summary (delegate) ───────────────────────────────────────────

    fun generateSummary() {
        val record = _uiState.value.record ?: return
        viewModelScope.launch {
            val settings = settingsDataStore.settingsFlow.first()
            val config = LLMConfig(apiEndpoint = settings.llmApiEndpoint, apiKey = settings.llmApiKey, modelName = settings.llmModelName)
            summaryCtl.generate(record.id, record.transcriptFilePath, config) {
                viewModelScope.launch { refreshRecord(record.id) }
            }
        }
    }

    // ── Upload (delegate) ───────────────────────────────────────────────

    fun onUploadClick() {
        val record = _uiState.value.record ?: return
        uploadCtl.onUploadClick(record)
    }

    fun dismissUploadConfirm() = uploadCtl.dismissConfirm()
    fun dismissUploadError() = uploadCtl.dismissError()

    fun confirmReUpload() {
        val record = _uiState.value.record
        uploadCtl.confirmReUpload(record)
    }

    fun uploadToServer() {
        val record = _uiState.value.record ?: return
        uploadCtl.onUploadClick(record)
    }

    // ── Delete ───────────────────────────────────────────────────────────

    fun showDeleteConfirm() { _uiState.value = _uiState.value.copy(showDeleteConfirm = true) }
    fun dismissDeleteConfirm() { _uiState.value = _uiState.value.copy(showDeleteConfirm = false) }

    fun deleteRecord() {
        val record = _uiState.value.record ?: return
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isDeleting = true)
            playback.release()
            transcript.cancel()
            summaryCtl.cancel()
            audioImporter.cancelProcessing(record.id)
            audioFileManager.deleteAudioFile(record.audioFilePath, record.transcriptFilePath)
            recordRepository.deleteRecord(record.id)
            _uiState.value = _uiState.value.copy(isDeleted = true, isDeleting = false)
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private suspend fun refreshRecord(recordId: Long) {
        val updated = recordRepository.getRecordById(recordId)
        if (updated != null) _uiState.value = _uiState.value.copy(record = updated)
    }

    private fun formatSummaryAsText(summary: com.voicenote.app.domain.model.RecordSummary): String {
        val sb = StringBuilder()
        if (summary.topics.isNotEmpty()) {
            sb.appendLine("【议题】"); summary.topics.forEach { sb.appendLine("  • $it") }; sb.appendLine()
        }
        if (summary.conclusions.isNotEmpty()) {
            sb.appendLine("【结论】"); summary.conclusions.forEach { sb.appendLine("  • $it") }; sb.appendLine()
        }
        if (summary.todos.isNotEmpty()) {
            sb.appendLine("【待办】")
            summary.todos.forEach { todo ->
                var line = "  • ${todo.task}"
                if (todo.owner.isNotBlank()) line += "（${todo.owner}）"
                if (todo.deadline.isNotBlank()) line += " 截止: ${todo.deadline}"
                sb.appendLine(line)
            }
            sb.appendLine()
        }
        if (summary.nextSteps.isNotEmpty()) {
            sb.appendLine("【后续步骤】"); summary.nextSteps.forEach { sb.appendLine("  • $it") }; sb.appendLine()
        }
        return sb.toString().trimEnd()
    }

    override fun onCleared() {
        super.onCleared()
        playback.release()
    }
}