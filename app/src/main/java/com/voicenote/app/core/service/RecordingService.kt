package com.voicenote.app.core.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
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
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import android.util.Log
import java.io.File
import javax.inject.Inject

@AndroidEntryPoint
class RecordingService : Service() {

    @Inject lateinit var audioCapture: AudioCapture
    @Inject lateinit var offlineASRClient: OfflineASRClient
    @Inject lateinit var asrModelManager: ASRModelManager
    @Inject lateinit var recordRepository: VoiceRecordRepositoryImpl
    @Inject lateinit var audioFileManager: AudioFileManager

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO +
        kotlinx.coroutines.CoroutineExceptionHandler { _, e ->
            Log.e("RecordingService", "Unhandled coroutine exception: ${e.message}", e)
        })
    private var recordingJob: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var actualStopTime: java.time.Instant? = null

    private val mutableTranscript = StringBuilder()
    private var currentOfflineModelQuality: ModelQuality = ModelQuality.INT8
    private var transcriptFilePath: String = ""
    private var punctReady = false

    companion object {
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
        private const val DECODE_INTERVAL_MS = 3_000L
        private const val RECENT_CHAR_WINDOW = 500      // scrolling subtitle window

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
                val recordId = intent.getLongExtra(EXTRA_RECORD_ID, 0)
                val offlineModelQuality = intent.getStringExtra(EXTRA_OFFLINE_MODEL_QUALITY) ?: "int8"
                startRecording(recordId, offlineModelQuality)
            }
            ACTION_STOP -> stopRecording()
        }
        return START_NOT_STICKY
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

            // Acquire wake lock
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "VoiceNote:RecordingWakeLock"
            ).apply { acquire() }

            // Start foreground
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, buildNotification("录音中..."),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, buildNotification("录音中..."))
            }

            // Initialize audio file
            audioFileManager.startNewRecording(recordId, java.time.Instant.now())

            // Initialize transcript file for incremental saving
            val transcriptDir = File(filesDir, "audio/record_$recordId")
            transcriptDir.mkdirs()
            val dateStr = java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd_HHmm")
                .withZone(java.time.ZoneId.systemDefault())
                .format(java.time.Instant.now())
            transcriptFilePath = File(transcriptDir, "$dateStr.txt").absolutePath

            startOfflineASR()

            // Launch post-recording finalization (waits for recordingJob to complete)
            startFinalization()
        } catch (e: Exception) {
            Log.e("RecordingService", "Failed to start recording: ${e.message}", e)
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
                    Log.i("RecordingService", "Offline ASR recognizer ready")
                    // Init VAD — bundled in APK assets, copy to storage if needed
                    asrModelManager.ensureVadModelAvailable()
                    vadActive = offlineASRClient.ensureVad()
                    if (!vadActive) {
                        // Fallback: try download (assets copy may have failed on some devices)
                        Log.i("RecordingService", "VAD model not available from assets, attempting download...")
                        try {
                            asrModelManager.downloadVadModel().getOrThrow()
                            vadActive = offlineASRClient.ensureVad()
                        } catch (e: Exception) {
                            Log.w("RecordingService", "VAD model download failed: ${e.message}")
                        }
                    }
                    if (vadActive) {
                        Log.i("RecordingService", "VAD ready, silence will be filtered")
                    } else {
                        Log.w("RecordingService", "VAD unavailable, will decode all audio")
                    }
                    // Init punctuation model (post-processing, no impact on recording)
                    punctReady = offlineASRClient.ensurePunctuation()
                    if (!punctReady) {
                        Log.i("RecordingService", "Punctuation model missing, attempting download...")
                        try {
                            asrModelManager.downloadPunctuationModel().getOrThrow()
                            punctReady = offlineASRClient.ensurePunctuation()
                        } catch (e: Exception) {
                            Log.w("RecordingService", "Punctuation model download failed: ${e.message}")
                        }
                    }
                    if (punctReady) {
                        Log.i("RecordingService", "Punctuation model ready")
                    }

                    _statusMessage.value = if (vadActive) {
                        "VAD 已就绪，正在监听..."
                    } else {
                        "模型已就绪，正在转写..."
                    }
                } catch (e: Exception) {
                    Log.e("RecordingService", "Offline ASR init failed: ${e.message}", e)
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
                                    mutableTranscript.append(text)
                                }
                                if (segments.isNotEmpty()) {
                                    saveTranscriptToFile()
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
                                            mutableTranscript.append(text)
                                            saveTranscriptToFile()
                                            val full = mutableTranscript.toString()
                                            _transcriptState.value = full.takeLast(RECENT_CHAR_WINDOW)
                                            _statusMessage.value = "正在转写... ${formatDuration(_durationSeconds.value)}"
                                        }
                                    }.onFailure { e ->
                                        Log.w("RecordingService", "Offline decode failed: ${e.message}")
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
                            mutableTranscript.append(text)
                        }
                        if (segments.isNotEmpty()) {
                            saveTranscriptToFile()
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
                                    mutableTranscript.append(text)
                                    saveTranscriptToFile()
                                    val full = mutableTranscript.toString()
                                    _transcriptState.value = full.takeLast(RECENT_CHAR_WINDOW)
                                }
                            }
                        } catch (e: Exception) {
                            Log.w("RecordingService", "Final pending decode failed: ${e.message}")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e("RecordingService", "Offline ASR error: ${e.message}", e)
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

            Log.i("RecordingService", "Finalizing: transcript.length=${transcript.length}, punctReady=$punctReady")

            if (finalTranscript.isBlank()) {
                finalTranscript = "离线转写未完成，请检查模型是否正确安装"
            }

            // Apply offline punctuation (model stays resident in memory)
            if (punctReady && finalTranscript.isNotBlank()
                && finalTranscript != "离线转写未完成，请检查模型是否正确安装"
            ) {
                Log.i("RecordingService", "Applying punctuation to transcript (${finalTranscript.length} chars)")
                _statusMessage.value = "正在添加标点..."
                finalTranscript = offlineASRClient.addPunctuation(finalTranscript)
                Log.i("RecordingService", "Punctuation applied: result length=${finalTranscript.length}")
            } else {
                Log.i("RecordingService", "Punctuation skipped: punctReady=$punctReady, textBlank=${finalTranscript.isBlank()}")
            }

            // Model stays loaded in memory for next recording; released only on memory warning or app kill.

            _transcriptState.value = finalTranscript
            saveTranscriptToFile()

            recordRepository.updateTranscriptWithFile(
                currentRecordId, finalTranscript, transcriptFilePath
            )
            recordRepository.updateTranscriptStatus(
                currentRecordId,
                if (finalTranscript.isBlank() ||
                    finalTranscript == "离线转写未完成，请检查模型是否正确安装"
                ) com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE
                else com.voicenote.app.domain.model.ProcessingStatus.COMPLETED
            )

            _isRecording.value = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            releaseWakeLock()
            stopSelf()
        }
    }

    private fun stopRecording() {
        actualStopTime = java.time.Instant.now()
        durationJob?.cancel()
        audioCapture.stopCapture()
        // Flow ends naturally when audioCapture stops.
        // Cancelling here would truncate the WAV file.

        _isRecording.value = false
        _statusMessage.value = "录音已结束，正在保存..."
        updateNotification("录音已结束，正在保存...")
    }

    private suspend fun startDurationCounter() {
        recordRepository.updateStartTime(currentRecordId, java.time.Instant.now())
        _durationSeconds.value = 0
        var batteryWarned = false
        durationJob = serviceScope.launch {
            while (isActive) {
                kotlinx.coroutines.delay(1000)
                _durationSeconds.value += 1
                if (!batteryWarned && _durationSeconds.value >= 3600L) {
                    batteryWarned = true
                    updateNotification("电量提醒：已持续录音1小时，请注意电量")
                }
            }
        }
    }

    private fun saveTranscriptToFile() {
        try {
            if (transcriptFilePath.isNotBlank()) {
                File(transcriptFilePath).writeText(mutableTranscript.toString())
            }
        } catch (e: Exception) {
            Log.e("RecordingService", "Failed to save transcript file: ${e.message}")
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
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}
