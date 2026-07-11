package com.voicenote.app.core.audio

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Log
import com.voicenote.app.core.asr.OfflineASRClient
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.di.AppSettings
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
import java.io.RandomAccessFile
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
    private val offlineASRClient: OfflineASRClient
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val processingJobs = mutableMapOf<Long, Job>()

    suspend fun importAudio(uri: Uri, settings: AppSettings): Result<Long> = withContext(Dispatchers.IO) {
        try {
            val timestamp = Instant.now()
            val title = "导入音频 ${dateFormatter.format(timestamp)}"

            val importedDir = File(context.filesDir, "audio/imported")
            importedDir.mkdirs()

            val safeName = "import_${safeDateFormatter.format(timestamp)}"
            val targetFile = File(importedDir, "$safeName.wav")

            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(targetFile).use { output ->
                    input.copyTo(output)
                }
            } ?: return@withContext Result.failure(Exception("无法读取选择的音频文件"))

            Log.i(TAG, "导入音频: ${targetFile.absolutePath} (${targetFile.length()} bytes)")

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
            Log.i(TAG, "录音记录已创建: recordId=$recordId，启动后台转写")

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

        val transcriptFilePath = if (transcript.isNotBlank() && transcript != FALLBACK_TEXT) {
            val dir = File(context.filesDir, "audio/record_$recordId")
            dir.mkdirs()
            val txtFile = File(dir, "${transcriptDateFormatter.format(java.time.Instant.now())}.txt")
            txtFile.writeText(transcript)
            txtFile.absolutePath
        } else {
            ""
        }

        recordRepository.updateTranscriptWithFile(recordId, transcriptFilePath)
        recordRepository.updateTranscriptStatus(
            recordId,
            if (transcript == FALLBACK_TEXT) com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE
            else com.voicenote.app.domain.model.ProcessingStatus.COMPLETED
        )

        Log.i(TAG, "后台处理完成: recordId=$recordId")
    }

    private suspend fun runASR(audioFilePath: String, settings: AppSettings): String {
        return try {
            val quality = ModelQuality.fromString(settings.offlineModelQuality)
            offlineASRClient.ensureRecognizer(quality)
            val file = File(audioFilePath)
            if (!file.exists()) return FALLBACK_TEXT

            // Chunked reading to avoid OOM on large files (e.g. 12h recordings)
            RandomAccessFile(file, "r").use { raf ->
                // Skip WAV header to find PCM data
                if (raf.length() < 44) return FALLBACK_TEXT
                raf.skipBytes(12) // RIFF + size + WAVE
                val chunkHeader = ByteArray(8)
                var dataOffset = 44L
                var dataSize = raf.length() - 44
                while (raf.filePointer + 8 <= raf.length()) {
                    raf.readFully(chunkHeader)
                    val chunkId = String(chunkHeader, 0, 4)
                    val chunkLen = ((chunkHeader[4].toInt() and 0xFF).toLong() or
                        ((chunkHeader[5].toInt() and 0xFF).toLong() shl 8) or
                        ((chunkHeader[6].toInt() and 0xFF).toLong() shl 16) or
                        ((chunkHeader[7].toInt() and 0xFF).toLong() shl 24))
                    if (chunkId == "data") {
                        dataOffset = raf.filePointer
                        dataSize = chunkLen
                        break
                    }
                    raf.seek(raf.filePointer + chunkLen)
                }

                // Process in 30-second chunks
                val bytesPerSec = 32000L  // 16000 Hz * 2 bytes
                val chunkSize = (30 * bytesPerSec).toInt()
                var bytesProcessed = 0L
                val results = StringBuilder()

                raf.seek(dataOffset)
                val buffer = ByteArray(chunkSize)
                while (bytesProcessed < dataSize) {
                    val remaining = (dataSize - bytesProcessed).toInt()
                    val toRead = minOf(chunkSize, remaining)
                    raf.readFully(buffer, 0, toRead)
                    val chunkData = if (toRead == chunkSize) buffer else buffer.copyOf(toRead)
                    val result = offlineASRClient.processPCMChunk(chunkData)
                    result.onSuccess { text ->
                        if (text.isNotBlank()) results.append(text)
                    }
                    bytesProcessed += toRead
                }

                offlineASRClient.reset()
                val text = results.toString().trim()
                if (text.isBlank()) FALLBACK_TEXT else text
            }
        } catch (e: Exception) {
            Log.e(TAG, "离线 ASR 失败: ${e.message}", e)
            FALLBACK_TEXT
        }
    }

    companion object {
        private const val TAG = "AudioImporter"
        private const val FALLBACK_TEXT = "服务暂时不可用，请采用离线方式"
        private val dateFormatter = DateTimeFormatter.ofPattern("M月d日 HH:mm")
            .withZone(ZoneId.systemDefault())
        private val safeDateFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")
            .withZone(ZoneId.systemDefault())
        private val transcriptDateFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmm")
            .withZone(ZoneId.systemDefault())
    }
}
