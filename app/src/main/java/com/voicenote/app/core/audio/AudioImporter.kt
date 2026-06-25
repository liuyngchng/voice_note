package com.voicenote.app.core.audio

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Log
import com.voicenote.app.core.asr.FunASRClient
import com.voicenote.app.core.asr.OfflineASRClient
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.di.AppSettings
import com.voicenote.app.core.llm.LLMClient
import com.voicenote.app.core.llm.LLMModelInfo
import com.voicenote.app.core.llm.OfflineLLMClient
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.repository.VoiceRecordRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AudioImporter @Inject constructor(
    @ApplicationContext private val context: Context,
    private val recordRepository: VoiceRecordRepository,
    private val audioFileManager: AudioFileManager,
    private val funASRClient: FunASRClient,
    private val offlineASRClient: OfflineASRClient,
    private val llmClient: LLMClient,
    private val offlineLLMClient: OfflineLLMClient
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val processingJobs = mutableMapOf<Long, Job>()

    suspend fun importAudio(uri: Uri, settings: AppSettings): Result<Long> = withContext(Dispatchers.IO) {
        try {
            val timestamp = Instant.now()
            val title = "导入音频 ${dateFormatter.format(timestamp)}"

            val importedDir = File(context.filesDir, "audio/imported")
            importedDir.mkdirs()

            val baseName = "import_${dateFormatter.format(timestamp)}"
            val targetFile = File(importedDir, "$baseName.wav")

            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(targetFile).use { output ->
                    input.copyTo(output)
                }
            } ?: return@withContext Result.failure(Exception("无法读取选择的音频文件"))

            Log.i(TAG, "导入音频: ${targetFile.absolutePath} (${targetFile.length()} bytes)")

            // Read actual audio duration from file for endTime
            val durationMs = try {
                val retriever = MediaMetadataRetriever()
                retriever.use {
                    it.setDataSource(targetFile.absolutePath)
                    it.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
                }
            } catch (_: Exception) { 0L }

            val record = VoiceRecord(
                title = title,
                memo = "",
                description = "",
                speakers = emptyList(),
                sourceType = "IMPORTED",
                startTime = timestamp,
                endTime = if (durationMs > 0) timestamp.plusMillis(durationMs) else null,
                audioFilePath = targetFile.absolutePath
            )

            val recordId = recordRepository.createRecord(record)
            Log.i(TAG, "录音记录已创建: recordId=$recordId，启动后台转写与总结")

            // Launch ASR + LLM in background; return recordId immediately
            processingJobs[recordId] = scope.launch {
                try {
                    processAudio(recordId, targetFile.absolutePath, settings)
                } finally {
                    processingJobs.remove(recordId)
                }
            }

            Result.success(recordId)
        } catch (e: Exception) {
            Log.e(TAG, "导入音频失败: ${e.message}", e)
            Result.failure(e)
        }
    }

    fun cancelProcessing(recordId: Long) {
        processingJobs[recordId]?.cancel()
        processingJobs.remove(recordId)
        Log.i(TAG, "取消后台处理: recordId=$recordId")
    }

    private suspend fun processAudio(recordId: Long, audioFilePath: String, settings: AppSettings) {
        recordRepository.updateTranscriptStatus(recordId, com.voicenote.app.domain.model.ProcessingStatus.PROCESSING)

        val transcript = runASR(audioFilePath, settings)

        // Write transcript file directly (not via AudioFileManager which depends on recording session state)
        val transcriptFilePath = if (transcript.isNotBlank() && transcript != FALLBACK_TEXT) {
            val dir = File(context.filesDir, "audio/record_$recordId")
            dir.mkdirs()
            val txtFile = File(dir, "${transcriptDateFormatter.format(java.time.Instant.now())}.txt")
            txtFile.writeText(transcript)
            txtFile.absolutePath
        } else {
            ""
        }

        recordRepository.updateTranscriptWithFile(recordId, transcript, transcriptFilePath)
        recordRepository.updateTranscriptStatus(
            recordId,
            if (transcript == FALLBACK_TEXT) com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE
            else com.voicenote.app.domain.model.ProcessingStatus.COMPLETED
        )

        if (transcript != FALLBACK_TEXT) {
            recordRepository.updateSummaryStatus(recordId, com.voicenote.app.domain.model.ProcessingStatus.PROCESSING)
            val summaryResult = runLLM(transcript, settings)
            summaryResult.onSuccess { summary ->
                recordRepository.updateSummary(recordId, summary)
            }
            if (summaryResult.isFailure) {
                recordRepository.updateSummaryStatus(recordId, com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE)
            }
        }

        Log.i(TAG, "后台处理完成: recordId=$recordId")
    }

    private suspend fun runASR(audioFilePath: String, settings: AppSettings): String {
        return when (settings.asrMode) {
            "offline" -> {
                try {
                    val quality = ModelQuality.fromString(settings.offlineModelQuality)
                    offlineASRClient.ensureRecognizer(quality)
                    // Read WAV PCM data
                    val file = File(audioFilePath)
                    val pcmData = file.inputStream().use { input ->
                        input.skip(44) // Skip WAV header
                        input.readBytes()
                    }
                    val result = offlineASRClient.processPCMChunk(pcmData)
                    offlineASRClient.reset()
                    result.getOrDefault(FALLBACK_TEXT)
                } catch (e: Exception) {
                    Log.e(TAG, "离线 ASR 失败: ${e.message}", e)
                    FALLBACK_TEXT
                }
            }
            else -> {
                val result = funASRClient.processFile(audioFilePath, settings.asrUrl)
                result.getOrDefault(FALLBACK_TEXT)
            }
        }
    }

    private suspend fun runLLM(
        transcript: String,
        settings: AppSettings
    ): Result<com.voicenote.app.domain.model.VoiceRecordSummary> {
        return when (settings.llmMode) {
            "offline" -> {
                val modelInfo = LLMModelInfo.fromString(settings.llmModelInfo)
                offlineLLMClient.generateSummary(transcript, modelInfo, settings.llmPrompt.ifBlank { null })
            }
            else -> {
                if (settings.llmKey.isBlank()) {
                    Result.failure(Exception("未配置 LLM API Key，请在设置中填写"))
                } else {
                    llmClient.generateSummary(
                        transcript = transcript,
                        apiUrl = settings.llmUrl,
                        apiKey = settings.llmKey,
                        model = settings.llmModel,
                        customPrompt = settings.llmPrompt.ifBlank { null }
                    )
                }
            }
        }
    }

    companion object {
        private const val TAG = "AudioImporter"
        private const val FALLBACK_TEXT = "服务暂时不可用，请采用离线方式"
        private val dateFormatter = DateTimeFormatter.ofPattern("M月d日 HH:mm")
            .withZone(ZoneId.systemDefault())
        private val transcriptDateFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmm")
            .withZone(ZoneId.systemDefault())
    }
}
