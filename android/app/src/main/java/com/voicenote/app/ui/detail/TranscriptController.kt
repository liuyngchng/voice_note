package com.voicenote.app.ui.detail

import android.app.Application
import android.util.Log
import com.voicenote.app.core.asr.ASRModelManager
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.asr.OfflineASRClient
import com.voicenote.app.core.audio.WavParser
import com.voicenote.app.core.common.TimeUtil
import com.voicenote.app.domain.model.ProcessingStatus
import com.voicenote.app.domain.repository.VoiceRecordRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.RandomAccessFile
import java.time.ZoneId
import java.time.format.DateTimeFormatter

data class TranscriptViewState(
    val isRetrying: Boolean = false,
    val progress: String = "",
    val error: String? = null,
    val showRegenerateConfirm: Boolean = false
)

/**
 * 转写重试控制器，从 [DetailViewModel] 中抽离。
 * 负责离线 ASR 重试 + 标点恢复。
 */
class TranscriptController(
    private val app: Application,
    private val scope: CoroutineScope,
    private val recordRepository: VoiceRecordRepository,
    private val offlineASRClient: OfflineASRClient,
    private val asrModelManager: ASRModelManager
) {
    private val _state = MutableStateFlow(TranscriptViewState())
    val state: StateFlow<TranscriptViewState> = _state.asStateFlow()

    private var retryJob: Job? = null

    fun showRegenerateConfirm() { _state.value = _state.value.copy(showRegenerateConfirm = true) }
    fun dismissRegenerateConfirm() { _state.value = _state.value.copy(showRegenerateConfirm = false) }

    fun retry(recordId: Long, audioFilePath: String?) {
        if (_state.value.isRetrying) return
        if (audioFilePath.isNullOrBlank()) {
            _state.value = _state.value.copy(error = "没有关联的音频文件，无法重新转写")
            return
        }
        val audioFile = File(audioFilePath)
        if (!audioFile.exists()) {
            _state.value = _state.value.copy(error = "音频文件不存在或已被删除")
            return
        }

        _state.value = _state.value.copy(isRetrying = true, progress = "", error = null)
        retryJob = scope.launch {
            recordRepository.updateTranscriptStatus(recordId, ProcessingStatus.PROCESSING)
            try {
                val result = runOfflineASR(audioFilePath)
                result.onSuccess { text ->
                    if (text.isNotBlank() && text != FALLBACK_TEXT) {
                        val dir = File(app.filesDir, "audio/record_$recordId")
                        dir.mkdirs()
                        val dateStr = transcriptDateFormatter.format(java.time.Instant.now())
                        val txtFile = File(dir, "$dateStr.txt")
                        txtFile.writeText(text)
                        recordRepository.updateTranscriptWithFile(recordId, txtFile.absolutePath)
                        recordRepository.updateTranscriptStatus(recordId, ProcessingStatus.COMPLETED)
                        _state.value = _state.value.copy(isRetrying = false, progress = "")
                    } else {
                        recordRepository.updateTranscriptStatus(recordId, ProcessingStatus.UNAVAILABLE)
                        _state.value = _state.value.copy(isRetrying = false, progress = "", error = "ASR 转写失败")
                    }
                }.onFailure { e ->
                    recordRepository.updateTranscriptStatus(recordId, ProcessingStatus.UNAVAILABLE)
                    _state.value = _state.value.copy(isRetrying = false, progress = "", error = e.message ?: "ASR 转写失败")
                }
            } catch (e: Exception) {
                _state.value = _state.value.copy(isRetrying = false, progress = "", error = e.message ?: "转写重试失败")
            } finally { retryJob = null }
        }
    }

    fun cancel() {
        retryJob?.cancel()
        retryJob = null
        _state.value = _state.value.copy(isRetrying = false, progress = "")
        offlineASRClient.requestReset()
    }

    // ── Internals ──────────────────────────────────────

    private suspend fun runOfflineASR(audioPath: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            val quality = ModelQuality.INT8  // default; caller can override
            offlineASRClient.ensureRecognizer(quality)
            val file = File(audioPath)
            val wavInfo = WavParser.parse(file)
            val bytesPerSec = wavInfo.sampleRate.toLong() * wavInfo.channels * (wavInfo.bitsPerSample / 8)
            val totalDurationSec = if (bytesPerSec > 0) wavInfo.dataSize / bytesPerSec else 0
            val chunkSizeBytes = (30 * bytesPerSec).toInt().coerceAtLeast(32000)
            val results = StringBuilder()
            var bytesProcessed = 0L
            val buffer = ByteArray(chunkSizeBytes)

            _state.value = _state.value.copy(progress = "正在读取音频文件...")
            RandomAccessFile(file, "r").use { raf ->
                raf.seek(wavInfo.dataOffset)
                while (isActive && bytesProcessed < wavInfo.dataSize) {
                    val remaining = (wavInfo.dataSize - bytesProcessed).toInt()
                    val toRead = minOf(chunkSizeBytes, remaining)
                    raf.readFully(buffer, 0, toRead)
                    val progressSec = bytesProcessed / bytesPerSec
                    _state.value = _state.value.copy(progress = "正在识别... ${TimeUtil.formatDuration(progressSec)} / ${TimeUtil.formatDuration(totalDurationSec)}")
                    val chunkData = if (toRead == chunkSizeBytes) buffer else buffer.copyOf(toRead)
                    val chunkResult = offlineASRClient.processPCMChunk(chunkData)
                    chunkResult.onSuccess { text -> if (text.isNotBlank()) results.append(text) }
                    bytesProcessed += toRead
                }
            }
            if (!isActive) {
                offlineASRClient.requestReset()
                return@withContext Result.failure(Exception("已取消"))
            }
            val text = results.toString().trim()
            if (text.isBlank()) {
                offlineASRClient.requestReset()
                return@withContext Result.failure(Exception("转写结果为空"))
            }
            // Punctuation
            _state.value = _state.value.copy(progress = "正在添加标点...")
            var punctReady = offlineASRClient.ensurePunctuation()
            if (!punctReady) {
                try {
                    asrModelManager.downloadPunctuationModel().getOrThrow()
                    punctReady = offlineASRClient.ensurePunctuation()
                } catch (e: Exception) { Log.w(TAG, "Punctuation download failed: ${e.message}") }
            }
            val punctuated = if (punctReady) offlineASRClient.addPunctuation(text) else text
            offlineASRClient.requestReset()
            Result.success(punctuated)
        } catch (e: Exception) {
            try { offlineASRClient.requestReset() } catch (_: Exception) {}
            Result.failure(e)
        }
    }

    companion object {
        private const val TAG = "TranscriptController"
        private const val FALLBACK_TEXT = "服务暂时不可用，请采用离线方式"
        private val transcriptDateFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss").withZone(ZoneId.systemDefault())
    }
}