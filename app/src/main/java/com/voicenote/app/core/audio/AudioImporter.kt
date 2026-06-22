package com.voicenote.app.core.audio

import android.content.Context
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
import kotlinx.coroutines.Dispatchers
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

            val record = VoiceRecord(
                title = title,
                memo = "",
                description = "",
                speakers = emptyList(),
                sourceType = "IMPORTED",
                startTime = timestamp,
                audioFilePath = targetFile.absolutePath
            )

            val recordId = recordRepository.createRecord(record)
            recordRepository.updateTranscriptStatus(recordId, com.voicenote.app.domain.model.ProcessingStatus.PROCESSING)

            val transcript = runASR(targetFile.absolutePath, settings)

            val transcriptFilePath = audioFileManager.finalizeTranscript(transcript)
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

            Log.i(TAG, "音频导入完成: recordId=$recordId")
            Result.success(recordId)
        } catch (e: Exception) {
            Log.e(TAG, "导入音频失败: ${e.message}", e)
            Result.failure(e)
        }
    }

    private suspend fun runASR(audioFilePath: String, settings: AppSettings): String {
        return when (settings.asrMode) {
            "offline" -> {
                try {
                    offlineASRClient.ensureRecognizer(ModelQuality.INT8)
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

    companion object {
        private const val TAG = "AudioImporter"
        private const val FALLBACK_TEXT = "服务暂时不可用，请采用离线方式"
        private val dateFormatter = DateTimeFormatter.ofPattern("M月d日 HH:mm")
            .withZone(ZoneId.systemDefault())
    }
}
