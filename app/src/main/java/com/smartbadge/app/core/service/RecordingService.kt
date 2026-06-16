package com.smartbadge.app.core.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.smartbadge.app.MainActivity
import com.smartbadge.app.core.asr.AsrEvent
import com.smartbadge.app.core.asr.FunASRClient
import com.smartbadge.app.core.audio.AudioCapture
import com.smartbadge.app.core.audio.AudioFileManager
import com.smartbadge.app.core.llm.LLMClient
import com.smartbadge.app.core.location.LocationTracker
import com.smartbadge.app.data.repository.VisitRepositoryImpl
import com.smartbadge.app.domain.model.LocationPoint
import com.smartbadge.app.domain.model.Visit
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
    @Inject lateinit var llmClient: LLMClient
    @Inject lateinit var locationTracker: LocationTracker
    @Inject lateinit var visitRepository: VisitRepositoryImpl
    @Inject lateinit var audioFileManager: AudioFileManager

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var recordingJob: Job? = null
    private var locationJob: Job? = null

    private val mutableTranscript = StringBuilder()
    private val locationPoints = mutableListOf<LocationPoint>()

    companion object {
        const val CHANNEL_ID = "recording_channel"
        const val NOTIFICATION_ID = 1
        const val ACTION_START = "com.smartbadge.app.action.START_RECORDING"
        const val ACTION_STOP = "com.smartbadge.app.action.STOP_RECORDING"
        const val EXTRA_VISIT_ID = "visit_id"
        const val EXTRA_VISIT_INFO = "visit_info"
        const val EXTRA_ASR_URL = "asr_url"
        const val EXTRA_LLM_URL = "llm_url"
        const val EXTRA_LLM_KEY = "llm_key"
        const val EXTRA_LLM_MODEL = "llm_model"
        const val EXTRA_LLM_PROMPT = "llm_prompt"

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
        private var currentVisitId: Long = 0
        var currentVisit: Visit? = null
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val visitId = intent.getLongExtra(EXTRA_VISIT_ID, 0)
                val asrUrl = intent.getStringExtra(EXTRA_ASR_URL) ?: ""
                val llmUrl = intent.getStringExtra(EXTRA_LLM_URL) ?: ""
                val llmKey = intent.getStringExtra(EXTRA_LLM_KEY) ?: ""
                val llmModel = intent.getStringExtra(EXTRA_LLM_MODEL) ?: "gpt-4o-mini"
                val llmPrompt = intent.getStringExtra(EXTRA_LLM_PROMPT)
                startRecording(visitId, asrUrl, llmUrl, llmKey, llmModel, llmPrompt)
            }
            ACTION_STOP -> stopRecording()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startRecording(
        visitId: Long,
        asrUrl: String,
        llmUrl: String,
        llmKey: String,
        llmModel: String,
        llmPrompt: String?
    ) {
        currentVisitId = visitId
        _isRecording.value = true
        mutableTranscript.clear()
        locationPoints.clear()
        _transcriptState.value = ""
        _durationSeconds.value = 0

        // Start foreground
        startForeground(NOTIFICATION_ID, buildNotification("拜访录音中..."))

        // Initialize audio file recording
        audioFileManager.startNewRecording(visitId, java.time.Instant.now())

        // Duration counter
        durationJob = serviceScope.launch {
            while (true) {
                kotlinx.coroutines.delay(1000)
                _durationSeconds.value += 1
            }
        }

        // Location tracking
        locationJob = serviceScope.launch {
            locationTracker.startTracking().collect { point ->
                locationPoints.add(point)
            }
        }

        // Connect FunASR
        val asrFlow = funASRClient.connect(asrUrl)

        // Start audio capture and send to ASR
        recordingJob = serviceScope.launch {
            // Wait for WebSocket connected
            launch {
                asrFlow.collect { event ->
                    _asrEvents.emit(event)
                    when (event) {
                        is AsrEvent.Partial -> {
                            mutableTranscript.append(event.text)
                            _transcriptState.value = mutableTranscript.toString()
                        }
                        is AsrEvent.Final -> {
                            // Final result for a segment
                            _transcriptState.value = mutableTranscript.toString()
                        }
                        is AsrEvent.Error -> {
                            Log.e("RecordingService", "ASR error: ${event.message}")
                        }
                        else -> {}
                    }
                }
            }

            // Small delay for WS connection
            kotlinx.coroutines.delay(300)
            funASRClient.sendHandshake()

            audioCapture.startCapture().collect { audioData ->
                audioFileManager.writeAudioChunk(audioData)
                funASRClient.sendAudio(audioData)
            }
        }

        // Generate AI summary when recording stops, then update visit
        serviceScope.launch {
            recordingJob?.join()

            // Save final transcript
            val transcript = mutableTranscript.toString()
            visitRepository.updateTranscript(currentVisitId, transcript)

            // Generate summary
            if (transcript.isNotBlank() && llmUrl.isNotBlank()) {
                val result = llmClient.generateSummary(
                    transcript = transcript,
                    apiUrl = llmUrl,
                    apiKey = llmKey,
                    model = llmModel,
                    customPrompt = llmPrompt
                )
                result.onSuccess { summary ->
                    visitRepository.updateSummary(currentVisitId, summary)
                }
            }

            // Finalize audio file
            val audioFilePath = audioFileManager.finalizeRecording()

            // Finalize visit
            val visit = visitRepository.getVisitById(currentVisitId)
            if (visit != null) {
                visitRepository.updateVisit(
                    visit.copy(
                        endTime = java.time.Instant.now(),
                        locationPoints = locationPoints.toList(),
                        transcriptText = transcript,
                        audioFilePath = audioFilePath
                    )
                )
            }

            _isRecording.value = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun stopRecording() {
        durationJob?.cancel()
        locationJob?.cancel()
        locationTracker.stopTracking()
        audioCapture.stopCapture()
        funASRClient.sendEnd()
        funASRClient.disconnect()
        recordingJob?.cancel()

        _isRecording.value = false
        updateNotification("拜访已结束，正在生成总结...")
    }

    private fun buildNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("智能工牌")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .addAction(
                android.R.drawable.ic_media_pause,
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
            "拜访录音",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "拜访录音进行中"
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }
}
