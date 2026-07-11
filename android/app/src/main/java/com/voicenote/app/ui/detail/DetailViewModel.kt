package com.voicenote.app.ui.detail

import android.app.Application
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.voicenote.app.core.asr.ASRModelManager
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.asr.OfflineASRClient
import com.voicenote.app.core.audio.AudioFileManager
import com.voicenote.app.core.audio.AudioImporter
import com.voicenote.app.core.di.SettingsDataStore
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
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
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
    val transcriptPreviewText: String = "",
    val isRetryingTranscript: Boolean = false,
    val retryProgress: String = ""
)

@HiltViewModel
class DetailViewModel @Inject constructor(
    application: Application,
    private val recordRepository: VoiceRecordRepository,
    private val audioFileManager: AudioFileManager,
    private val audioImporter: AudioImporter,
    private val offlineASRClient: OfflineASRClient,
    private val asrModelManager: ASRModelManager,
    private val settingsDataStore: SettingsDataStore
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(DetailUiState())
    val uiState: StateFlow<DetailUiState> = _uiState.asStateFlow()

    // AudioTrack playback state
    private var audioTrack: AudioTrack? = null
    private var playbackJob: Job? = null
    private var positionUpdateJob: Job? = null
    private var retryTranscriptJob: Job? = null

    // Parsed WAV header fields
    private var wavDataOffset: Long = 44
    private var wavDataSize: Long = 0
    private var wavSampleRate: Int = 16000
    private var wavChannels: Int = 1
    private var wavBitsPerSample: Int = 16
    private var totalFrames: Long = 0
    @Volatile private var playbackBaseFrame: Long = 0

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
            parseWavHeader(file)
            val bytesPerSec = wavSampleRate.toLong() * wavChannels * (wavBitsPerSample / 8)
            if (bytesPerSec > 0) formatDuration(wavDataSize / bytesPerSec) else "00:00"
        } catch (_: Exception) {
            "00:00"
        }
    }

    private fun parseWavHeader(file: File) {
        RandomAccessFile(file, "r").use { raf ->
            if (raf.length() < 44) return

            val header = ByteArray(12)
            raf.readFully(header)

            val chunkHeader = ByteArray(8)
            while (raf.filePointer < raf.length()) {
                val bytesRead = raf.read(chunkHeader)
                if (bytesRead < 8) break

                val chunkId = String(chunkHeader, 0, 4)
                val chunkSize = (
                    (chunkHeader[4].toInt() and 0xFF) or
                    ((chunkHeader[5].toInt() and 0xFF) shl 8) or
                    ((chunkHeader[6].toInt() and 0xFF) shl 16) or
                    ((chunkHeader[7].toInt() and 0xFF) shl 24)
                ).toLong() and 0xFFFFFFFFL

                when (chunkId) {
                    "fmt " -> {
                        val fmtData = ByteArray(chunkSize.toInt().coerceAtMost(16))
                        raf.readFully(fmtData)
                        wavChannels = (fmtData[2].toInt() and 0xFF) or ((fmtData[3].toInt() and 0xFF) shl 8)
                        wavSampleRate = (fmtData[4].toInt() and 0xFF) or
                            ((fmtData[5].toInt() and 0xFF) shl 8) or
                            ((fmtData[6].toInt() and 0xFF) shl 16) or
                            ((fmtData[7].toInt() and 0xFF) shl 24)
                        wavBitsPerSample = (fmtData[14].toInt() and 0xFF) or ((fmtData[15].toInt() and 0xFF) shl 8)
                    }
                    "data" -> {
                        wavDataOffset = raf.filePointer
                        wavDataSize = chunkSize
                        val bytesPerFrame = wavChannels.toLong() * (wavBitsPerSample / 8)
                        totalFrames = if (bytesPerFrame > 0) wavDataSize / bytesPerFrame else 0
                        return
                    }
                    else -> {
                        val skipTo = raf.filePointer + chunkSize
                        if (skipTo < raf.length()) raf.seek(skipTo) else break
                    }
                }
            }
        }
    }

    fun clearError() {
        _uiState.value = _uiState.value.copy(error = null)
    }

    // --- AudioTrack playback ---

    fun playPause() {
        val filePath = _uiState.value.record?.audioFilePath ?: return
        if (filePath.isBlank()) return
        val file = File(filePath)
        if (!file.exists()) {
            _uiState.value = _uiState.value.copy(error = "录音文件不存在")
            return
        }

        when (_uiState.value.playbackState) {
            PlaybackState.IDLE -> {
                parseWavHeader(file)
                if (totalFrames <= 0) {
                    _uiState.value = _uiState.value.copy(error = "录音文件无效")
                    return
                }
                playbackBaseFrame = 0
                startPlayback(file)
            }
            PlaybackState.PAUSED -> startPlayback(file)
            PlaybackState.PLAYING -> pausePlayback()
        }
    }

    private fun startPlayback(file: File) {
        playbackJob?.cancel()
        playbackJob = viewModelScope.launch {
            _uiState.value = _uiState.value.copy(playbackState = PlaybackState.PLAYING)
            startPositionUpdates()
            runAudioPlayback(file)
            // If we reach here and isActive is true, playback ended naturally
            if (isActive) {
                _uiState.value = _uiState.value.copy(
                    playbackState = PlaybackState.IDLE,
                    playbackProgress = 0f,
                    playbackPositionFormatted = "00:00"
                )
                playbackBaseFrame = 0
            }
        }
    }

    private fun pausePlayback() {
        positionUpdateJob?.cancel()
        positionUpdateJob = null
        playbackJob?.cancel()
        playbackJob = null
        // currentFrame captured in runAudioPlayback's finally block via playbackBaseFrame
        _uiState.value = _uiState.value.copy(playbackState = PlaybackState.PAUSED)
    }

    private suspend fun runAudioPlayback(file: File) = withContext(Dispatchers.IO) {
        val bytesPerFrame = wavChannels * (wavBitsPerSample / 8)
        if (bytesPerFrame <= 0 || wavSampleRate <= 0) return@withContext

        val channelConfig = if (wavChannels == 2) AudioFormat.CHANNEL_OUT_STEREO
            else AudioFormat.CHANNEL_OUT_MONO
        val encoding = if (wavBitsPerSample == 8) AudioFormat.ENCODING_PCM_8BIT
            else AudioFormat.ENCODING_PCM_16BIT

        val minBuf = AudioTrack.getMinBufferSize(wavSampleRate, channelConfig, encoding)
        val bufferSize = maxOf(minBuf, 4096)

        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(encoding)
                        .setSampleRate(wavSampleRate)
                        .setChannelMask(channelConfig)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create AudioTrack", e)
            withContext(Dispatchers.Main) {
                _uiState.value = _uiState.value.copy(error = "播放初始化失败")
            }
            return@withContext
        }

        audioTrack = track

        try {
            track.play()
            RandomAccessFile(file, "r").use { raf ->
                val startByte = wavDataOffset + playbackBaseFrame * bytesPerFrame
                raf.seek(startByte)
                val buffer = ByteArray(bufferSize)

                while (isActive) {
                    val bytesRead = raf.read(buffer)
                    if (bytesRead <= 0) break
                    val written = track.write(buffer, 0, bytesRead)
                    if (written <= 0) break
                }
            }
        } finally {
            playbackBaseFrame += track.playbackHeadPosition.toLong()
            try { track.stop() } catch (_: Exception) {}
            track.release()
            audioTrack = null
        }
    }

    private fun getCurrentFrame(): Long {
        val t = audioTrack
        return if (t != null && t.state == AudioTrack.STATE_INITIALIZED) {
            playbackBaseFrame + t.playbackHeadPosition.toLong()
        } else {
            playbackBaseFrame
        }
    }

    private fun frameToSeconds(frames: Long): Long =
        if (wavSampleRate > 0) frames / wavSampleRate else 0

    fun seekTo(fraction: Float) {
        playbackBaseFrame = (totalFrames * fraction).toLong().coerceIn(0, totalFrames)
        _uiState.value = _uiState.value.copy(
            playbackProgress = fraction,
            playbackPositionFormatted = formatDuration(frameToSeconds(playbackBaseFrame))
        )
        if (_uiState.value.playbackState == PlaybackState.PLAYING) {
            restartPlayback()
        }
    }

    fun skipBack() {
        val frameDelta = (15L * wavSampleRate)
        playbackBaseFrame = (playbackBaseFrame - frameDelta).coerceAtLeast(0)
        updatePositionUI()
        if (_uiState.value.playbackState == PlaybackState.PLAYING) {
            restartPlayback()
        }
    }

    fun skipForward() {
        val frameDelta = (15L * wavSampleRate)
        playbackBaseFrame = (playbackBaseFrame + frameDelta).coerceAtMost(totalFrames)
        updatePositionUI()
        if (_uiState.value.playbackState == PlaybackState.PLAYING) {
            restartPlayback()
        }
    }

    private fun restartPlayback() {
        val filePath = _uiState.value.record?.audioFilePath ?: return
        val file = File(filePath)
        if (!file.exists()) return
        // Stop current track, start new one from updated playbackBaseFrame
        playbackJob?.cancel()
        playbackJob = null
        audioTrack?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        audioTrack = null
        startPlayback(file)
    }

    private fun updatePositionUI() {
        val progress = if (totalFrames > 0) playbackBaseFrame.toFloat() / totalFrames.toFloat() else 0f
        _uiState.value = _uiState.value.copy(
            playbackProgress = progress,
            playbackPositionFormatted = formatDuration(frameToSeconds(playbackBaseFrame))
        )
    }

    fun releasePlayer() {
        positionUpdateJob?.cancel()
        positionUpdateJob = null
        playbackJob?.cancel()
        playbackJob = null
        audioTrack?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        audioTrack = null
        playbackBaseFrame = 0
    }

    private fun startPositionUpdates() {
        positionUpdateJob?.cancel()
        positionUpdateJob = viewModelScope.launch {
            while (isActive) {
                if (_uiState.value.playbackState == PlaybackState.PLAYING && totalFrames > 0) {
                    val cur = getCurrentFrame()
                    val progress = cur.toFloat() / totalFrames.toFloat()
                    _uiState.value = _uiState.value.copy(
                        playbackProgress = progress,
                        playbackPositionFormatted = formatDuration(frameToSeconds(cur))
                    )
                }
                delay(250)
            }
        }
    }

    // --- Share ---

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
            }
            val chooser = Intent.createChooser(intent, "分享录音文件")
            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(chooser)
        } catch (e: Exception) {
            _uiState.value = _uiState.value.copy(error = "分享失败")
        }
    }

    // --- Transcript ---

    fun openTranscriptPreview() {
        val path = _uiState.value.record?.transcriptFilePath ?: return
        if (path.isBlank()) return
        viewModelScope.launch(Dispatchers.IO) {
            val text = try {
                File(path).readText()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to read transcript file: ${e.message}")
                ""
            }
            _uiState.value = _uiState.value.copy(showTranscriptPreview = true, transcriptPreviewText = text)
        }
    }

    fun dismissTranscriptPreview() {
        _uiState.value = _uiState.value.copy(showTranscriptPreview = false, transcriptPreviewText = "")
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
            retryTranscriptJob?.cancel()
            retryTranscriptJob = null
            audioImporter.cancelProcessing(record.id)
            audioFileManager.deleteAudioFile(record.audioFilePath, record.transcriptFilePath)
            recordRepository.deleteRecord(record.id)
            _uiState.value = _uiState.value.copy(isDeleted = true, isDeleting = false)
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

        retryTranscriptJob = viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isRetryingTranscript = true, retryProgress = "", error = null)
            recordRepository.updateTranscriptStatus(record.id, ProcessingStatus.PROCESSING)

            try {
                val settings = settingsDataStore.settingsFlow.first()
                Log.i(TAG, "retryTranscript: quality=${settings.offlineModelQuality}")
                val result = runOfflineASR(audioPath, settings.offlineModelQuality)

                result.onSuccess { text ->
                    if (text.isNotBlank() && text != FALLBACK_TEXT) {
                        val app = getApplication<Application>()
                        val dir = File(app.filesDir, "audio/record_${record.id}")
                        dir.mkdirs()
                        val dateStr = transcriptDateFormatter.format(java.time.Instant.now())
                        val txtFile = File(dir, "$dateStr.txt")
                        txtFile.writeText(text)
                        recordRepository.updateTranscriptWithFile(record.id, txtFile.absolutePath)
                        recordRepository.updateTranscriptStatus(record.id, ProcessingStatus.COMPLETED)
                        _uiState.value = _uiState.value.copy(isRetryingTranscript = false, retryProgress = "")
                        refreshRecord(record.id)
                    } else {
                        recordRepository.updateTranscriptStatus(record.id, ProcessingStatus.UNAVAILABLE)
                        _uiState.value = _uiState.value.copy(isRetryingTranscript = false, retryProgress = "", error = "ASR 转写失败")
                        refreshRecord(record.id)
                    }
                }.onFailure { e ->
                    recordRepository.updateTranscriptStatus(record.id, ProcessingStatus.UNAVAILABLE)
                    _uiState.value = _uiState.value.copy(
                        isRetryingTranscript = false,
                        retryProgress = "",
                        error = e.message ?: "ASR 转写失败"
                    )
                    refreshRecord(record.id)
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isRetryingTranscript = false,
                    retryProgress = "",
                    error = e.message ?: "转写重试失败"
                )
            } finally {
                retryTranscriptJob = null
            }
        }
    }

    private suspend fun runOfflineASR(audioPath: String, qualityStr: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            Log.i(TAG, "runOfflineASR: audioPath=$audioPath, quality=$qualityStr")
            val quality = ModelQuality.fromString(qualityStr)
            offlineASRClient.ensureRecognizer(quality)

            val file = File(audioPath)
            val totalFileSize = file.length()

            // Parse WAV header to get PCM data offset and size
            parseWavHeader(file)
            val totalPcmBytes = wavDataSize
            val bytesPerSec = wavSampleRate.toLong() * wavChannels * (wavBitsPerSample / 8)
            val totalDurationSec = if (bytesPerSec > 0) totalPcmBytes / bytesPerSec else 0

            // 30-second chunks — balances progress granularity with decode overhead
            val chunkSizeBytes = (30 * bytesPerSec).toInt().coerceAtLeast(32000)

            val results = StringBuilder()
            var bytesProcessed = 0L
            val buffer = ByteArray(chunkSizeBytes)

            _uiState.value = _uiState.value.copy(retryProgress = "正在读取音频文件...")

            RandomAccessFile(file, "r").use { raf ->
                raf.seek(wavDataOffset)

                while (isActive && bytesProcessed < totalPcmBytes) {
                    val remaining = (totalPcmBytes - bytesProcessed).toInt()
                    val toRead = minOf(chunkSizeBytes, remaining)
                    raf.readFully(buffer, 0, toRead)

                    val progressSec = bytesProcessed / bytesPerSec
                    val totalSec = totalDurationSec
                    _uiState.value = _uiState.value.copy(
                        retryProgress = "正在识别... ${formatDuration(progressSec)} / ${formatDuration(totalSec)}"
                    )

                    val chunkData = if (toRead == chunkSizeBytes) buffer else buffer.copyOf(toRead)
                    val chunkResult = offlineASRClient.processPCMChunk(chunkData)
                    chunkResult.onSuccess { text ->
                        if (text.isNotBlank()) results.append(text)
                    }

                    bytesProcessed += toRead
                }
            }

            if (!isActive) {
                offlineASRClient.reset()
                return@withContext Result.failure(Exception("已取消"))
            }

            val text = results.toString().trim()
            if (text.isBlank()) {
                offlineASRClient.reset()
                return@withContext Result.failure(Exception("转写结果为空"))
            }

            // Apply punctuation — must ensure model is loaded first
            var punctReady = offlineASRClient.ensurePunctuation()
            if (!punctReady) {
                Log.i(TAG, "Punctuation model not loaded, attempting download...")
                try {
                    asrModelManager.downloadPunctuationModel().getOrThrow()
                    punctReady = offlineASRClient.ensurePunctuation()
                } catch (e: Exception) {
                    Log.w(TAG, "Punctuation model download failed: ${e.message}")
                }
            }
            Log.i(TAG, "Punctuation ready=$punctReady, textLength=${text.length}")

            _uiState.value = _uiState.value.copy(retryProgress = "正在添加标点...")
            val punctuated = if (punctReady) {
                val result = offlineASRClient.addPunctuation(text)
                Log.i(TAG, "Punctuation applied: before=${text.length} chars, after=${result.length} chars")
                result
            } else {
                Log.w(TAG, "Punctuation unavailable, returning raw text")
                text
            }

            offlineASRClient.reset()
            Result.success(punctuated)
        } catch (e: Exception) {
            try { offlineASRClient.reset() } catch (_: Exception) {}
            Result.failure(e)
        }
    }

    fun cancelRetryTranscript() {
        retryTranscriptJob?.cancel()
        retryTranscriptJob = null
        _uiState.value = _uiState.value.copy(isRetryingTranscript = false, retryProgress = "")
        try { offlineASRClient.reset() } catch (_: Exception) {}
        viewModelScope.launch {
            recordRepository.updateTranscriptStatus(
                _uiState.value.record?.id ?: return@launch,
                ProcessingStatus.UNAVAILABLE
            )
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
            }
            val chooser = Intent.createChooser(intent, "分享转写文件")
            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(chooser)
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

    override fun onCleared() {
        super.onCleared()
        releasePlayer()
    }

    private fun formatDuration(seconds: Long): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
    }

    companion object {
        private const val TAG = "DetailViewModel"
        private const val FALLBACK_TEXT = "服务暂时不可用，请采用离线方式"
        private val transcriptDateFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")
            .withZone(ZoneId.systemDefault())
    }
}
