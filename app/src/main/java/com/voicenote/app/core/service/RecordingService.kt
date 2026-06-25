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
import com.voicenote.app.core.asr.ASRMode
import com.voicenote.app.core.asr.AsrEvent
import com.voicenote.app.core.asr.FunASRClient
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.asr.OfflineASRClient
import com.voicenote.app.core.audio.AudioCapture
import com.voicenote.app.core.audio.AudioFileManager
import com.voicenote.app.core.llm.LLMClient
import com.voicenote.app.core.llm.LLMMode
import com.voicenote.app.core.llm.LLMModelInfo
import com.voicenote.app.core.llm.OfflineLLMClient
import com.voicenote.app.data.repository.VoiceRecordRepositoryImpl
import com.voicenote.app.domain.model.VoiceRecord
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import android.util.Log
import javax.inject.Inject

@AndroidEntryPoint
class RecordingService : Service() {

    @Inject lateinit var audioCapture: AudioCapture
    @Inject lateinit var funASRClient: FunASRClient
    @Inject lateinit var offlineASRClient: OfflineASRClient
    @Inject lateinit var llmClient: LLMClient
    @Inject lateinit var offlineLLMClient: OfflineLLMClient
    @Inject lateinit var recordRepository: VoiceRecordRepositoryImpl
    @Inject lateinit var audioFileManager: AudioFileManager

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO +
        kotlinx.coroutines.CoroutineExceptionHandler { _, e ->
            Log.e("RecordingService", "Unhandled coroutine exception: ${e.message}", e)
        })
    private var recordingJob: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private val mutableTranscript = StringBuilder()
    private var currentAsrMode: ASRMode = ASRMode.ONLINE
    private var currentLlmMode: LLMMode = LLMMode.ONLINE
    private var currentLlmModelInfo: LLMModelInfo = LLMModelInfo.QWEN2_5_0_5B
    private var currentOfflineModelQuality: ModelQuality = ModelQuality.INT8
    private val offlinePcmBuffer = mutableListOf<ByteArray>()

    companion object {
        const val CHANNEL_ID = "recording_channel"
        const val NOTIFICATION_ID = 1
        const val ACTION_START = "com.voicenote.app.action.START_RECORDING"
        const val ACTION_STOP = "com.voicenote.app.action.STOP_RECORDING"
        const val EXTRA_RECORD_ID = "record_id"
        const val EXTRA_VISIT_INFO = "visit_info"
        const val EXTRA_ASR_URL = "asr_url"
        const val EXTRA_LLM_URL = "llm_url"
        const val EXTRA_LLM_KEY = "llm_key"
        const val EXTRA_LLM_MODEL = "llm_model"
        const val EXTRA_LLM_PROMPT = "llm_prompt"
        const val EXTRA_ASR_MODE = "asr_mode"
        const val EXTRA_LLM_MODE = "llm_mode"
        const val EXTRA_LLM_MODEL_INFO = "llm_model_info"
        const val EXTRA_OFFLINE_MODEL_QUALITY = "offline_model_quality"

        // Observables for UI binding
        private val _transcriptState = MutableStateFlow("")
        val transcriptState: StateFlow<String> = _transcriptState.asStateFlow()

        private val _isRecording = MutableStateFlow(false)
        val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

        private val _durationSeconds = MutableStateFlow(0L)
        val durationSeconds: StateFlow<Long> = _durationSeconds.asStateFlow()

        private val _asrEvents = MutableSharedFlow<AsrEvent>()
        val asrEvents: SharedFlow<AsrEvent> = _asrEvents.asSharedFlow()

        private var durationJob: Job? = null
        private var currentRecordId: Long = 0
        var currentRecord: VoiceRecord? = null
    }

    override fun onCreate() {
        super.onCreate()
        android.util.Log.e("REC_CRASH", "SVC: onCreate")
        createNotificationChannel()
        android.util.Log.e("REC_CRASH", "SVC: onCreate done, injected fields: audioCapture=${::audioCapture.isInitialized}, audioFileManager=${::audioFileManager.isInitialized}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        android.util.Log.e("REC_CRASH", "SVC: onStartCommand, action=${intent?.action}")
        when (intent?.action) {
            ACTION_START -> {
                android.util.Log.e("REC_CRASH", "SVC: ACTION_START, parsing extras")
                val recordId = intent.getLongExtra(EXTRA_RECORD_ID, 0)
                val asrUrl = intent.getStringExtra(EXTRA_ASR_URL) ?: ""
                val llmUrl = intent.getStringExtra(EXTRA_LLM_URL) ?: ""
                val llmKey = intent.getStringExtra(EXTRA_LLM_KEY) ?: ""
                val llmModel = intent.getStringExtra(EXTRA_LLM_MODEL) ?: "gpt-4o-mini"
                val llmPrompt = intent.getStringExtra(EXTRA_LLM_PROMPT)
                val asrModeStr = intent.getStringExtra(EXTRA_ASR_MODE) ?: "online"
                val llmModeStr = intent.getStringExtra(EXTRA_LLM_MODE) ?: "online"
                val llmModelInfoStr = intent.getStringExtra(EXTRA_LLM_MODEL_INFO) ?: "qwen2_5_0_5b_q4km"
                val offlineModelQuality = intent.getStringExtra(EXTRA_OFFLINE_MODEL_QUALITY) ?: "int8"
                android.util.Log.e("REC_CRASH", "SVC: extras parsed — recordId=$recordId, asrMode=$asrModeStr, llmMode=$llmModeStr")
                val asrMode = ASRMode.fromString(asrModeStr)
                val llmMode = LLMMode.fromString(llmModeStr)
                val llmModelInfo = LLMModelInfo.fromString(llmModelInfoStr)
                android.util.Log.e("REC_CRASH", "SVC: calling startRecording")
                startRecording(recordId, asrUrl, llmUrl, llmKey, llmModel, llmPrompt, asrMode, llmMode, llmModelInfo, offlineModelQuality)
                android.util.Log.e("REC_CRASH", "SVC: startRecording returned")
            }
            ACTION_STOP -> stopRecording()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startRecording(
        recordId: Long,
        asrUrl: String,
        llmUrl: String,
        llmKey: String,
        llmModel: String,
        llmPrompt: String?,
        asrMode: ASRMode = ASRMode.ONLINE,
        llmMode: LLMMode = LLMMode.ONLINE,
        llmModelInfo: LLMModelInfo = LLMModelInfo.QWEN2_5_0_5B,
        offlineModelQualityStr: String = "int8"
    ) {
        android.util.Log.e("REC_CRASH", "SVC: startRecording entered, asrMode=$asrMode")
        try {
            currentRecordId = recordId
            currentAsrMode = asrMode
            currentLlmMode = llmMode
            currentLlmModelInfo = llmModelInfo
            currentOfflineModelQuality = ModelQuality.fromString(offlineModelQualityStr)
            _isRecording.value = true
            mutableTranscript.clear()
            offlinePcmBuffer.clear()
            _transcriptState.value = ""
            _durationSeconds.value = 0
            android.util.Log.e("REC_CRASH", "SVC: state vars set, acquiring wake lock")

            // Acquire wake lock to keep CPU awake during recording
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "VoiceNote:RecordingWakeLock"
            ).apply { acquire() }
            android.util.Log.e("REC_CRASH", "SVC: wake lock acquired, SDK=${Build.VERSION.SDK_INT}")

            // Start foreground
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                android.util.Log.e("REC_CRASH", "SVC: calling startForeground with MICROPHONE type")
                startForeground(NOTIFICATION_ID, buildNotification("录音中..."), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                android.util.Log.e("REC_CRASH", "SVC: calling startForeground (pre-Q)")
                startForeground(NOTIFICATION_ID, buildNotification("录音中..."))
            }
            android.util.Log.e("REC_CRASH", "SVC: startForeground OK")

            // Initialize audio file recording
            android.util.Log.e("REC_CRASH", "SVC: starting audio file")
            audioFileManager.startNewRecording(recordId, java.time.Instant.now())
            android.util.Log.e("REC_CRASH", "SVC: audio file started")

            // Duration counter
            var batteryWarned = false
            durationJob = serviceScope.launch {
                while (true) {
                    kotlinx.coroutines.delay(1000)
                    _durationSeconds.value += 1
                    if (!batteryWarned && _durationSeconds.value >= 3600L) {
                        batteryWarned = true
                        updateNotification("电量提醒：已持续录音1小时，请注意电量")
                    }
                }
            }
            android.util.Log.e("REC_CRASH", "SVC: duration counter launched, dispatching ASR mode")

            when (asrMode) {
                ASRMode.ONLINE -> startOnlineASR(asrUrl)
                ASRMode.OFFLINE -> startOfflineASR()
            }

            android.util.Log.e("REC_CRASH", "SVC: ASR started, launching summary gen")
            // Launch summary generation (waits for recordingJob to complete)
            startSummaryGeneration(asrUrl, llmUrl, llmKey, llmModel, llmPrompt)
            android.util.Log.e("REC_CRASH", "SVC: startRecording complete")
        } catch (e: Exception) {
            android.util.Log.e("REC_CRASH", "SVC: startRecording FAILED: ${e.message}", e)
            Log.e("RecordingService", "Failed to start recording: ${e.message}", e)
            _isRecording.value = false
            releaseWakeLock()
            stopSelf()
        }
    }

    private fun startOnlineASR(asrUrl: String) {
        android.util.Log.e("REC_CRASH", "SVC: startOnlineASR, url=$asrUrl")

        recordingJob = serviceScope.launch {
            var asrConnected = false
            try {
                val asrFlow = funASRClient.connect(asrUrl)
                asrConnected = true
                android.util.Log.e("REC_CRASH", "SVC: online ASR connected")

                launch {
                    asrFlow.collect { event ->
                        _asrEvents.emit(event)
                        when (event) {
                            is AsrEvent.Partial -> {
                                mutableTranscript.append(event.text)
                                _transcriptState.value = mutableTranscript.toString()
                            }
                            is AsrEvent.Final -> {
                                _transcriptState.value = mutableTranscript.toString()
                            }
                            is AsrEvent.Error -> {
                                Log.e("RecordingService", "ASR error: ${event.message}")
                            }
                            else -> {}
                        }
                    }
                }

                kotlinx.coroutines.delay(300)
                funASRClient.sendHandshake()
            } catch (e: Exception) {
                android.util.Log.e("REC_CRASH", "SVC: online ASR connect failed: ${e.message}", e)
                Log.e("RecordingService", "Online ASR unavailable: ${e.message}", e)
            }

            android.util.Log.e("REC_CRASH", "SVC: starting audio capture, asrConnected=$asrConnected")
            audioCapture.startCapture().collect { audioData ->
                audioFileManager.writeAudioChunk(audioData)
                if (asrConnected) {
                    funASRClient.sendAudio(audioData)
                }
            }
        }
        android.util.Log.e("REC_CRASH", "SVC: startOnlineASR done, recordingJob launched")
    }

    private fun startOfflineASR() {
        android.util.Log.e("REC_CRASH", "SVC: startOfflineASR, quality=${currentOfflineModelQuality.name}")

        android.util.Log.e("REC_CRASH", "SVC: launching offline recordingJob")
        recordingJob = serviceScope.launch {
            // Init recognizer on IO thread — keep heavy JNI model load off main thread
            var asrReady = false
            try {
                Log.i("RecordingService", "Starting offline ASR with quality=${currentOfflineModelQuality.name}")
                android.util.Log.e("REC_CRASH", "SVC: calling ensureRecognizer (on IO thread)")
                offlineASRClient.ensureRecognizer(currentOfflineModelQuality)
                asrReady = true
                Log.i("RecordingService", "Offline ASR recognizer ready")
                android.util.Log.e("REC_CRASH", "SVC: ensureRecognizer OK")
            } catch (e: Exception) {
                android.util.Log.e("REC_CRASH", "SVC: ensureRecognizer FAILED: ${e.message}", e)
                Log.e("RecordingService", "Offline ASR init failed: ${e.message}", e)
            }

            try {
                android.util.Log.e("REC_CRASH", "SVC: offline recordingJob started, asrReady=$asrReady")
                var chunkStart = 0L
                val chunkIntervalMs = 30_000L

                android.util.Log.e("REC_CRASH", "SVC: offline calling audioCapture.startCapture()")
                audioCapture.startCapture().collect { audioData ->
                    audioFileManager.writeAudioChunk(audioData)

                    if (asrReady) {
                        offlinePcmBuffer.add(audioData)
                        val elapsed = _durationSeconds.value * 1000
                        if (elapsed - chunkStart >= chunkIntervalMs) {
                            chunkStart = elapsed
                            val merged = concatenateChunks(offlinePcmBuffer)
                            offlinePcmBuffer.clear()

                            val result = offlineASRClient.processPCMChunk(merged)
                            result.onSuccess { text ->
                                mutableTranscript.append(text)
                                _transcriptState.value = mutableTranscript.toString()
                            }
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

    private fun startSummaryGeneration(
        asrUrl: String, llmUrl: String, llmKey: String, llmModel: String, llmPrompt: String?
    ) {
        serviceScope.launch {
            recordingJob?.join()

            // Step 1: Process remaining PCM buffer, then unload ASR model
            if (currentAsrMode == ASRMode.OFFLINE) {
                if (offlinePcmBuffer.isNotEmpty()) {
                    Log.i("RecordingService", "Pipeline: processing remaining PCM buffer (${offlinePcmBuffer.size} chunks)")
                    val merged = concatenateChunks(offlinePcmBuffer)
                    offlinePcmBuffer.clear()
                    val result = offlineASRClient.processPCMChunk(merged)
                    result.onSuccess { text ->
                        mutableTranscript.append(text)
                        _transcriptState.value = mutableTranscript.toString()
                    }
                }
                if (offlineASRClient.isAvailable) {
                    Log.i("RecordingService", "Pipeline: unloading ASR model before summary")
                    offlineASRClient.reset()
                }
            }

            val audioFilePath = audioFileManager.finalizeRecording()
            recordRepository.updateAudioFilePath(currentRecordId, audioFilePath, java.time.Instant.now())

            var transcript = mutableTranscript.toString()
            val fallbackText = "服务暂时不可用，请采用离线方式"

            Log.i("RecordingService", "startSummaryGeneration: transcript.length=${transcript.length}, asrMode=$currentAsrMode, audioFilePath=$audioFilePath")

            if (transcript.isBlank() && audioFilePath.isNotBlank() && currentAsrMode == ASRMode.ONLINE && asrUrl.isNotBlank()) {
                recordRepository.updateTranscriptStatus(currentRecordId, com.voicenote.app.domain.model.ProcessingStatus.PROCESSING)
                val retryResult = retryAsrWithBackoff(audioFilePath, asrUrl)
                transcript = retryResult.getOrDefault(fallbackText)
            } else if (transcript.isBlank() && currentAsrMode == ASRMode.OFFLINE) {
                transcript = "离线转写未完成，请检查模型是否正确安装"
            } else if (transcript.isBlank()) {
                transcript = fallbackText
            }

            val transcriptFilePath = audioFileManager.finalizeTranscript(transcript)
            recordRepository.updateTranscriptWithFile(currentRecordId, transcript, transcriptFilePath)
            recordRepository.updateTranscriptStatus(
                currentRecordId,
                if (transcript.isBlank() || transcript == fallbackText || transcript == "离线转写未完成，请检查模型是否正确安装") com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE
                else com.voicenote.app.domain.model.ProcessingStatus.COMPLETED
            )

            if (transcript != fallbackText) {
                when (currentLlmMode) {
                    LLMMode.OFFLINE -> {
                        recordRepository.updateSummaryStatus(currentRecordId, com.voicenote.app.domain.model.ProcessingStatus.PROCESSING)
                        val summaryResult = offlineLLMClient.generateSummary(transcript, currentLlmModelInfo, llmPrompt)
                        summaryResult.onSuccess { summary ->
                            recordRepository.updateSummary(currentRecordId, summary)
                        }
                        if (summaryResult.isFailure) {
                            recordRepository.updateSummaryStatus(currentRecordId, com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE)
                        }
                    }
                    LLMMode.ONLINE -> {
                        if (llmUrl.isNotBlank()) {
                            recordRepository.updateSummaryStatus(currentRecordId, com.voicenote.app.domain.model.ProcessingStatus.PROCESSING)
                            val summaryResult = retryLlmWithBackoff(transcript, llmUrl, llmKey, llmModel, llmPrompt)
                            summaryResult.onSuccess { summary ->
                                recordRepository.updateSummary(currentRecordId, summary)
                            }
                            if (summaryResult.isFailure) {
                                recordRepository.updateSummaryStatus(currentRecordId, com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE)
                            }
                        } else {
                            recordRepository.updateSummaryStatus(currentRecordId, com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE)
                        }
                    }
                }
            }

            _isRecording.value = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            releaseWakeLock()
            stopSelf()
        }
    }

    private fun stopRecording() {
        durationJob?.cancel()
        audioCapture.stopCapture()

        when (currentAsrMode) {
            ASRMode.ONLINE -> {
                funASRClient.sendEnd()
                serviceScope.launch {
                    kotlinx.coroutines.delay(3000)
                    funASRClient.disconnect()
                    recordingJob?.cancel()
                }
            }
            ASRMode.OFFLINE -> {
                recordingJob?.cancel()
            }
        }

        _isRecording.value = false
        updateNotification("录音已结束，正在生成总结...")
    }

    private fun buildNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
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

    private suspend fun retryAsrWithBackoff(audioFilePath: String, asrUrl: String): Result<String> {
        val delays = listOf(20_000L, 40_000L, 80_000L, 160_000L, 320_000L)
        var lastError: Throwable? = null

        for ((index, delay) in delays.withIndex()) {
            if (index > 0) {
                Log.i("RecordingService", "ASR retry ${index + 1}/${delays.size} after ${delay}ms")
                kotlinx.coroutines.delay(delay)
            }

            val result = funASRClient.processFile(audioFilePath, asrUrl)
            if (result.isSuccess) {
                Log.i("RecordingService", "ASR retry ${index + 1} succeeded")
                return result
            }
            lastError = result.exceptionOrNull()
            Log.w("RecordingService", "ASR retry ${index + 1}/${delays.size} failed: ${lastError?.message}")
        }

        return Result.failure(lastError ?: Exception("All ASR retries exhausted"))
    }

    private suspend fun retryLlmWithBackoff(
        transcript: String,
        llmUrl: String,
        llmKey: String,
        llmModel: String,
        llmPrompt: String?
    ): Result<com.voicenote.app.domain.model.VoiceRecordSummary> {
        val delays = listOf(20_000L, 40_000L, 80_000L, 160_000L, 320_000L)
        var lastError: Throwable? = null

        for ((index, delay) in delays.withIndex()) {
            if (index > 0) {
                Log.i("RecordingService", "LLM retry ${index + 1}/${delays.size} after ${delay}ms")
                kotlinx.coroutines.delay(delay)
            }

            val result = llmClient.generateSummary(
                transcript = transcript,
                apiUrl = llmUrl,
                apiKey = llmKey,
                model = llmModel,
                customPrompt = llmPrompt
            )
            if (result.isSuccess) {
                Log.i("RecordingService", "LLM retry ${index + 1} succeeded")
                return result
            }
            lastError = result.exceptionOrNull()
            Log.w("RecordingService", "LLM retry ${index + 1}/${delays.size} failed: ${lastError?.message}")
        }

        return Result.failure(lastError ?: Exception("All LLM retries exhausted"))
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
