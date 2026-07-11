package com.voicenote.app.core.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.voicenote.app.MainActivity
import com.voicenote.app.R
import com.voicenote.app.core.asr.ASRModelManager
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.asr.OfflineASRClient
import com.voicenote.app.core.audio.AudioCapture
import com.voicenote.app.core.audio.AudioFileManager
import com.voicenote.app.data.repository.VoiceRecordRepositoryImpl
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import android.util.Log
import com.google.gson.Gson
import java.io.File
import javax.inject.Inject

@AndroidEntryPoint
class RecordingService : Service() {

    private data class RecordingCheckpoint(
        val recordId: Long,
        val startTime: Long,
        val lastTranscriptLength: Int,
        val pcmBytesWritten: Long,
        val sampleRate: Int = 16000,
        val channels: Int = 1,
        val bitsPerSample: Int = 16
    )

    @Inject lateinit var audioCapture: AudioCapture
    @Inject lateinit var offlineASRClient: OfflineASRClient
    @Inject lateinit var asrModelManager: ASRModelManager
    @Inject lateinit var recordRepository: VoiceRecordRepositoryImpl
    @Inject lateinit var audioFileManager: AudioFileManager

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO +
        kotlinx.coroutines.CoroutineExceptionHandler { _, e ->
            Log.e(TAG, "Unhandled coroutine exception: ${e.message}", e)
        })
    private var recordingJob: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var actualStopTime: java.time.Instant? = null
    private var audioFocusRequest: AudioFocusRequest? = null

    private val mutableTranscript = StringBuilder()
    private var currentOfflineModelQuality: ModelQuality = ModelQuality.INT8
    private var transcriptFilePath: String = ""
    private var punctReady = false
    private var wakeLockStartTime = 0L
    private var diskCheckJob: Job? = null
    private var checkpointJob: Job? = null
    private val gson = Gson()

    companion object {
        private const val TAG = "RecordingService"
        const val CHANNEL_ID = "recording_channel"
        const val NOTIFICATION_ID = 1
        const val ACTION_START = "com.voicenote.app.action.START_RECORDING"
        const val ACTION_STOP = "com.voicenote.app.action.STOP_RECORDING"
        const val EXTRA_RECORD_ID = "record_id"
        const val EXTRA_OFFLINE_MODEL_QUALITY = "offline_model_quality"

        // Offline ASR strategy:
        // - Audio capture writes to file independently, never blocked by ASR.
        // - Model loads in parallel with capture.
        // - During recording: decode only new audio chunks incrementally.
        // - Screen shows scrolling recent-text window (last N chars).
        // - Transcript file appends incrementally; no full-file re-decode needed.
        private const val DECODE_INTERVAL_MS = 5_000L
        private const val RECENT_CHAR_WINDOW = 100      // scrolling subtitle window

        // Long-recording optimization
        private const val DISK_CHECK_INTERVAL_MS = 300_000L   // 5 minutes
        private const val MIN_FREE_SPACE_BYTES = 500L * 1024 * 1024  // 500 MB
        private const val MAX_TRANSCRIPT_CHARS = 1_000_000   // 1M char cap
        private const val PUNCTUATION_CHUNK_SIZE = 5000      // chars per punctuation batch
        private const val CHECKPOINT_INTERVAL_MS = 120_000L  // 2 minutes
        private const val BATTERY_WARNING_SECONDS = 3600L    // 1 hour
        private const val ACTIVE_RECORDING_FILE = "active_recording.txt"
        private const val CHECKPOINTS_DIR = "checkpoints"

        // Observables for UI binding
        private val _transcriptState = MutableStateFlow("")
        val transcriptState: StateFlow<String> = _transcriptState.asStateFlow()

        private val _isRecording = MutableStateFlow(false)
        val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

        private val _durationSeconds = MutableStateFlow(0L)
        val durationSeconds: StateFlow<Long> = _durationSeconds.asStateFlow()

        private val _statusMessage = MutableStateFlow("")
        val statusMessage: StateFlow<String> = _statusMessage.asStateFlow()

        private var durationJob: Job? = null
        private var currentRecordId: Long = 0
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                // Guard: prevent duplicate recording
                if (_isRecording.value) {
                    Log.w(TAG, "Ignoring duplicate START request — already recording")
                    return START_REDELIVER_INTENT
                }
                val recordId = intent.getLongExtra(EXTRA_RECORD_ID, 0)
                val offlineModelQuality = intent.getStringExtra(EXTRA_OFFLINE_MODEL_QUALITY) ?: "int8"
                startRecording(recordId, offlineModelQuality)
            }
            ACTION_STOP -> stopRecording()
        }
        // Restart with last intent if killed — enables crash recovery
        return START_REDELIVER_INTENT
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startRecording(
        recordId: Long,
        offlineModelQualityStr: String = "int8"
    ) {
        try {
            currentRecordId = recordId
            currentOfflineModelQuality = ModelQuality.fromString(offlineModelQualityStr)
            _isRecording.value = true
            _durationSeconds.value = 0
            mutableTranscript.clear()
            _transcriptState.value = ""
            _statusMessage.value = "正在初始化录音服务..."

            // Acquire wake lock — held for entire recording to prevent CPU sleep
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "VoiceNote:RecordingWakeLock"
            ).apply { acquire() }
            wakeLockStartTime = System.currentTimeMillis()

            // Request audio focus — auto-stop on incoming call
            requestAudioFocus()

            // Start foreground
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, buildNotification("录音中..."),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, buildNotification("录音中..."))
            }

            // Initialize audio file — detect and resume incomplete recording
            val existingWavPath = audioFileManager.getCurrentFilePath()
            val resumed = if (existingWavPath.isNotBlank()) {
                // Service was killed and restarted — attempt to resume
                Log.i(TAG, "Attempting to resume: $existingWavPath")
                audioFileManager.resumeRecording(recordId, existingWavPath)
            } else {
                // Check for orphaned checkpoint from a previous crash
                val checkpointFile = File(filesDir, "checkpoints/record_${recordId}.json")
                if (checkpointFile.exists()) {
                    val checkpoint = gson.fromJson(checkpointFile.readText(), RecordingCheckpoint::class.java)
                    // Try to find the existing WAV file
                    val audioDir = File(filesDir, "audio/record_$recordId")
                    val wavFiles = audioDir.listFiles { f -> f.extension == "wav" }
                    if (wavFiles != null && wavFiles.isNotEmpty()) {
                        Log.i(TAG, "Recovering from orphaned checkpoint: ${wavFiles[0].absolutePath}")
                        _statusMessage.value = "正在恢复上次录音..."
                        audioFileManager.resumeRecording(recordId, wavFiles[0].absolutePath)
                    } else false
                } else false
            }

            if (!resumed) {
                // Fresh recording
                audioFileManager.startNewRecording(recordId, java.time.Instant.now())
            }

            // Initialize transcript file for incremental saving
            val transcriptDir = File(filesDir, "audio/record_$recordId")
            transcriptDir.mkdirs()
            // Reuse existing transcript file if resuming, else create new
            val existingTxtFiles = transcriptDir.listFiles { f -> f.extension == "txt" }
            if (resumed && existingTxtFiles != null && existingTxtFiles.isNotEmpty()) {
                transcriptFilePath = existingTxtFiles.last().absolutePath
                // Reload in-memory transcript from file
                val existing = try { File(transcriptFilePath).readText() } catch (_: Exception) { "" }
                if (existing.isNotBlank()) {
                    mutableTranscript.append(existing)
                }
                Log.i(TAG, "Resumed transcript: ${mutableTranscript.length} chars")
            } else {
                val dateStr = java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd_HHmm")
                    .withZone(java.time.ZoneId.systemDefault())
                    .format(java.time.Instant.now())
                transcriptFilePath = File(transcriptDir, "$dateStr.txt").absolutePath
            }

            startOfflineASR()

            // Persist active recording marker for crash recovery
            writeActiveRecordingMarker(recordId)

            // Launch post-recording finalization (waits for recordingJob to complete)
            startFinalization()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start recording: ${e.message}", e)
            _isRecording.value = false
            releaseWakeLock()
            stopSelf()
        }
    }


    private fun startOfflineASR() {
        recordingJob = serviceScope.launch {
            // ── Model/VAD should already be preloaded; ensureReady is a fast no-op ──
            var asrReady = false
            var vadActive = false
            launch {
                val alreadyLoaded = offlineASRClient.isAvailable
                if (!alreadyLoaded) {
                    _statusMessage.value = "正在加载离线模型..."
                }
                try {
                    offlineASRClient.ensureRecognizer(currentOfflineModelQuality)
                    asrReady = true
                    Log.i(TAG, "Offline ASR recognizer ready")
                    // Init VAD — bundled in APK assets, copy to storage if needed
                    asrModelManager.ensureVadModelAvailable()
                    vadActive = offlineASRClient.ensureVad()
                    if (!vadActive) {
                        // Fallback: try download (assets copy may have failed on some devices)
                        Log.i(TAG, "VAD model not available from assets, attempting download...")
                        try {
                            asrModelManager.downloadVadModel().getOrThrow()
                            vadActive = offlineASRClient.ensureVad()
                        } catch (e: Exception) {
                            Log.w(TAG, "VAD model download failed: ${e.message}")
                        }
                    }
                    if (vadActive) {
                        Log.i(TAG, "VAD ready, silence will be filtered")
                    } else {
                        Log.w(TAG, "VAD unavailable, will decode all audio")
                    }
                    // Init punctuation model (post-processing, no impact on recording)
                    punctReady = offlineASRClient.ensurePunctuation()
                    if (!punctReady) {
                        Log.i(TAG, "Punctuation model missing, attempting download...")
                        try {
                            asrModelManager.downloadPunctuationModel().getOrThrow()
                            punctReady = offlineASRClient.ensurePunctuation()
                        } catch (e: Exception) {
                            Log.w(TAG, "Punctuation model download failed: ${e.message}")
                        }
                    }
                    if (punctReady) {
                        Log.i(TAG, "Punctuation model ready")
                    }

                    _statusMessage.value = if (vadActive) {
                        "VAD 已就绪，正在监听..."
                    } else {
                        "模型已就绪，正在转写..."
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Offline ASR init failed: ${e.message}", e)
                }
            }

            // ── Disk space monitor (P1) ──────────────────────────────────────
            diskCheckJob = launch {
                while (isActive) {
                    delay(DISK_CHECK_INTERVAL_MS)
                    if (!checkDiskSpace()) {
                        Log.w(TAG, "磁盘空间不足，自动停止录音")
                        stopRecording()
                        break
                    }
                }
            }

            // ── Periodic checkpoint (P2) ─────────────────────────────────────
            checkpointJob = launch {
                while (isActive) {
                    delay(CHECKPOINT_INTERVAL_MS)
                    saveCheckpoint()
                }
            }

            try {
                val pendingChunks = mutableListOf<ByteArray>()
                var lastDecodeTime = 0L

                startDurationCounter()
                audioCapture.startCapture().collect { audioData ->
                    audioFileManager.writeAudioChunk(audioData)

                    if (asrReady) {
                        if (vadActive) {
                            // ── VAD path: feed audio to VAD, decode only speech segments ──
                            offlineASRClient.vadAcceptPCM(audioData)

                            val elapsed = _durationSeconds.value * 1000
                            if (elapsed - lastDecodeTime >= DECODE_INTERVAL_MS) {
                                lastDecodeTime = elapsed
                                val segments = offlineASRClient.vadDecodeSpeechSegments()
                                for (text in segments) {
                                    appendToTranscript(text)
                                    appendTranscriptChunk(text + "\n")
                                }
                                if (segments.isNotEmpty()) {
                                    val full = mutableTranscript.toString()
                                    _transcriptState.value = full.takeLast(RECENT_CHAR_WINDOW)
                                    _statusMessage.value = "正在转写... ${formatDuration(_durationSeconds.value)}"
                                } else {
                                    _statusMessage.value = "静音中... ${formatDuration(_durationSeconds.value)}"
                                }
                            }
                        } else {
                            // ── Fallback: no VAD, decode raw chunks incrementally ──
                            pendingChunks.add(audioData)

                            val elapsed = _durationSeconds.value * 1000
                            if (elapsed - lastDecodeTime >= DECODE_INTERVAL_MS) {
                                lastDecodeTime = elapsed
                                if (pendingChunks.isNotEmpty()) {
                                    val newAudio = concatenateChunks(pendingChunks)
                                    pendingChunks.clear()

                                    val result = offlineASRClient.processPCMChunk(newAudio)
                                    result.onSuccess { text ->
                                        if (text.isNotBlank()) {
                                            appendToTranscript(text)
                                            appendTranscriptChunk(text + "\n")
                                            val full = mutableTranscript.toString()
                                            _transcriptState.value = full.takeLast(RECENT_CHAR_WINDOW)
                                            _statusMessage.value = "正在转写... ${formatDuration(_durationSeconds.value)}"
                                        }
                                    }.onFailure { e ->
                                        Log.w(TAG, "Offline decode failed: ${e.message}")
                                    }
                                }
                            }
                        }
                    }
                }

                // Drain remaining after capture stops
                if (asrReady) {
                    if (vadActive) {
                        // Flush in-progress speech: feed silence to force VAD
                        // to complete any partial segment before draining.
                        offlineASRClient.vadFlush()
                        val segments = offlineASRClient.vadDecodeSpeechSegments()
                        for (text in segments) {
                            appendToTranscript(text)
                            appendTranscriptChunk(text + "\n")
                        }
                        if (segments.isNotEmpty()) {
                            val full = mutableTranscript.toString()
                            _transcriptState.value = full.takeLast(RECENT_CHAR_WINDOW)
                        }
                    } else if (pendingChunks.isNotEmpty()) {
                        try {
                            val finalAudio = concatenateChunks(pendingChunks)
                            pendingChunks.clear()
                            val result = offlineASRClient.processPCMChunk(finalAudio)
                            result.onSuccess { text ->
                                if (text.isNotBlank()) {
                                    appendToTranscript(text)
                                    appendTranscriptChunk(text + "\n")
                                    val full = mutableTranscript.toString()
                                    _transcriptState.value = full.takeLast(RECENT_CHAR_WINDOW)
                                }
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Final pending decode failed: ${e.message}")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Offline ASR error: ${e.message}", e)
            }
        }
    }


    private fun concatenateChunks(chunks: List<ByteArray>): ByteArray {
        val totalSize = chunks.sumOf { it.size }
        val result = ByteArray(totalSize)
        var offset = 0
        for (chunk in chunks) {
            System.arraycopy(chunk, 0, result, offset, chunk.size)
            offset += chunk.size
        }
        return result
    }

    private fun startFinalization() {
        serviceScope.launch {
            recordingJob?.join()

            val audioFilePath = audioFileManager.finalizeRecording()
            recordRepository.updateAudioFilePath(
                currentRecordId, audioFilePath,
                actualStopTime ?: java.time.Instant.now()
            )

            val transcript = mutableTranscript.toString()
            var finalTranscript = transcript

            Log.i(TAG, "Finalizing: transcript.length=${transcript.length}, punctReady=$punctReady")

            if (finalTranscript.isBlank()) {
                finalTranscript = "离线转写未完成，请检查模型是否正确安装"
            }

            // Apply offline punctuation in chunks (model stays resident in memory)
            if (punctReady && finalTranscript.isNotBlank()
                && finalTranscript != "离线转写未完成，请检查模型是否正确安装"
            ) {
                Log.i(TAG, "Applying punctuation to transcript (${finalTranscript.length} chars)")
                _statusMessage.value = "正在添加标点..."
                finalTranscript = applyPunctuationInChunks(finalTranscript)
                Log.i(TAG, "Punctuation applied: result length=${finalTranscript.length}")
            } else {
                Log.i(TAG, "Punctuation skipped: punctReady=$punctReady, textBlank=${finalTranscript.isBlank()}")
            }

            // Model stays loaded in memory for next recording; released only on memory warning or app kill.

            _transcriptState.value = finalTranscript
            try {
                if (transcriptFilePath.isNotBlank()) {
                    File(transcriptFilePath).writeText(finalTranscript)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to write final transcript: ${e.message}")
            }

            recordRepository.updateTranscriptWithFile(
                currentRecordId, transcriptFilePath
            )
            recordRepository.updateTranscriptStatus(
                currentRecordId,
                if (finalTranscript.isBlank() ||
                    finalTranscript == "离线转写未完成，请检查模型是否正确安装"
                ) com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE
                else com.voicenote.app.domain.model.ProcessingStatus.COMPLETED
            )

            _isRecording.value = false
            deleteActiveRecordingMarker()
            stopForeground(STOP_FOREGROUND_REMOVE)
            releaseWakeLock()
            stopSelf()
        }
    }

    private fun stopRecording() {
        actualStopTime = java.time.Instant.now()
        durationJob?.cancel()
        diskCheckJob?.cancel()
        checkpointJob?.cancel()
        audioCapture.stopCapture()
        // Flow ends naturally when audioCapture stops.
        // Cancelling here would truncate the WAV file.

        _isRecording.value = false
        _statusMessage.value = "录音已结束，正在保存..."
        updateNotification("录音已结束，正在保存...")
    }

    private fun requestAudioFocus() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val focusAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
                audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(focusAttributes)
                    .setOnAudioFocusChangeListener { focusChange ->
                        when (focusChange) {
                            AudioManager.AUDIOFOCUS_LOSS -> {
                                Log.w(TAG, "Audio focus lost — stopping recording")
                                stopRecording()
                            }
                            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                                Log.w(TAG, "Audio focus transient loss")
                            }
                            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                                // Continue recording, other app is ducking
                            }
                            AudioManager.AUDIOFOCUS_GAIN -> {
                                // Focus regained — nothing to do
                            }
                        }
                    }
                    .build()
                audioManager.requestAudioFocus(audioFocusRequest!!)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to request audio focus: ${e.message}")
        }
    }

    private fun abandonAudioFocus() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to abandon audio focus: ${e.message}")
        }
        audioFocusRequest = null
    }

    private suspend fun startDurationCounter() {
        recordRepository.updateStartTime(currentRecordId, java.time.Instant.now())
        _durationSeconds.value = 0
        var batteryWarned = false
        durationJob = serviceScope.launch {
            while (isActive) {
                kotlinx.coroutines.delay(1000)
                _durationSeconds.value += 1
                if (!batteryWarned && _durationSeconds.value >= BATTERY_WARNING_SECONDS) {
                    batteryWarned = true
                    // Check if battery optimization is disabled — warn if not
                    val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                    if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
                        updateNotification("⚡ 建议关闭电池优化以确保持续录音")
                    }
                }
                // WakeLock held for entire recording — released only on stop/crash
            }
        }
    }

    private fun appendTranscriptChunk(text: String) {
        try {
            if (transcriptFilePath.isBlank() || text.isEmpty()) return
            val file = File(transcriptFilePath)
            if (!file.exists()) file.createNewFile()
            file.appendText(text)
            // Ensure transcript is on disk — crash recovery depends on it
            file.outputStream().use { it.fd.sync() }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to append transcript chunk: ${e.message}")
        }
    }

    /** Append text to in-memory transcript with upper-bound protection. */
    private fun appendToTranscript(text: String) {
        if (mutableTranscript.length + text.length > MAX_TRANSCRIPT_CHARS) {
            Log.w(TAG, "转写文本超过上限 (${mutableTranscript.length})，截断旧内容")
            mutableTranscript.delete(0, mutableTranscript.length / 4)
        }
        mutableTranscript.append(text)
    }

    // ── Disk space check (P1) ─────────────────────────────────────────────

    private fun checkDiskSpace(): Boolean {
        val usableSpace = filesDir.usableSpace
        if (usableSpace < MIN_FREE_SPACE_BYTES) {
            _statusMessage.value = "磁盘空间不足，请停止录音"
            updateNotification("磁盘空间不足 (剩余 ${usableSpace / 1_048_576}MB)")
            return false
        }
        return true
    }

    // ── Punctuation chunking (P0) ──────────────────────────────────────────

    private fun applyPunctuationInChunks(rawText: String, chunkSize: Int = PUNCTUATION_CHUNK_SIZE): String {
        if (!punctReady || rawText.isBlank()) return rawText
        if (rawText.length <= chunkSize) {
            return offlineASRClient.addPunctuation(rawText)
        }

        val result = StringBuilder()
        var offset = 0
        while (offset < rawText.length) {
            val end = minOf(offset + chunkSize, rawText.length)
            val adjustedEnd = findBestSplitPoint(rawText, offset, end)
            val chunk = rawText.substring(offset, adjustedEnd)
            val punctuated = offlineASRClient.addPunctuation(chunk)
            result.append(punctuated)
            offset = adjustedEnd
        }
        return result.toString()
    }

    private fun findBestSplitPoint(text: String, start: Int, maxEnd: Int): Int {
        if (maxEnd >= text.length) return text.length
        val searchStart = maxOf(start, maxEnd - 500)
        val searchRange = text.substring(searchStart, maxEnd)
        val breakChars = charArrayOf('\n', '。', '！', '？', '.', '!', '?')
        val lastBreak = breakChars.map { searchRange.lastIndexOf(it) }.maxOrNull() ?: -1
        return if (lastBreak >= 0) searchStart + lastBreak + 1 else maxEnd
    }

    private fun writeActiveRecordingMarker(recordId: Long) {
        try {
            File(filesDir, ACTIVE_RECORDING_FILE).writeText(recordId.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write active recording marker: ${e.message}")
        }
    }

    private fun deleteActiveRecordingMarker() {
        try {
            val marker = File(filesDir, ACTIVE_RECORDING_FILE)
            if (marker.exists()) marker.delete()
            val checkpointDir = File(filesDir, CHECKPOINTS_DIR)
            if (checkpointDir.isDirectory) {
                checkpointDir.listFiles()?.forEach { it.delete() }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to delete active recording marker: ${e.message}")
        }
    }

    // ── Checkpoint (P2) ───────────────────────────────────────────────────

    private suspend fun saveCheckpoint() {
        try {
            // Force-flush audio data to disk and get persisted byte count
            val pcmBytes = audioFileManager.flushAndCheckpoint()
            val checkpoint = RecordingCheckpoint(
                recordId = currentRecordId,
                startTime = wakeLockStartTime,
                lastTranscriptLength = mutableTranscript.length,
                pcmBytesWritten = pcmBytes
            )
            val json = gson.toJson(checkpoint)
            val checkpointDir = File(filesDir, "checkpoints")
            checkpointDir.mkdirs()
            File(checkpointDir, "record_${currentRecordId}.json").writeText(json)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save checkpoint: ${e.message}")
        }
    }

    private fun formatDuration(seconds: Long): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) "%02d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
    }

    private fun buildNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("语音笔记")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification_mic)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .addAction(
                R.drawable.ic_notification_stop,
                "结束",
                PendingIntent.getService(
                    this, 1,
                    Intent(this, RecordingService::class.java).setAction(ACTION_STOP),
                    PendingIntent.FLAG_IMMUTABLE
                )
            )
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "录音",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "录音进行中"
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }


    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
        abandonAudioFocus()
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}
