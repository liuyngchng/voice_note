package com.voicenote.app.core.service

import android.util.Log
import com.google.gson.Gson
import com.voicenote.app.core.audio.AudioFileManager
import java.io.File

/**
 * 录音检查点管理器，从 [RecordingService] 中抽离。
 * 定期持久化录音进度到文件系统，支持崩溃恢复。
 */
class CheckpointManager(private val filesDir: File) {
    private val gson = Gson()

    data class RecordingCheckpoint(
        val recordId: Long,
        val startTime: Long,
        val lastTranscriptLength: Int,
        val pcmBytesWritten: Long,
        val sampleRate: Int = 16000,
        val channels: Int = 1,
        val bitsPerSample: Int = 16
    )

    /** 保存检查点到文件 */
    fun save(
        recordId: Long,
        wakeLockStartTime: Long,
        transcriptLength: Int,
        audioFileManager: AudioFileManager
    ) {
        try {
            val pcmBytes = audioFileManager.flushAndCheckpoint()
            val checkpoint = RecordingCheckpoint(
                recordId = recordId,
                startTime = wakeLockStartTime,
                lastTranscriptLength = transcriptLength,
                pcmBytesWritten = pcmBytes
            )
            val checkpointDir = File(filesDir, CHECKPOINTS_DIR)
            checkpointDir.mkdirs()
            val json = gson.toJson(checkpoint)
            File(checkpointDir, "record_${recordId}.json").writeText(json)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save checkpoint: ${e.message}")
        }
    }

    /** 尝试加载已有的检查点，不存在则返回 null */
    fun load(recordId: Long): RecordingCheckpoint? {
        return try {
            val file = File(filesDir, "checkpoints/record_${recordId}.json")
            if (file.exists()) gson.fromJson(file.readText(), RecordingCheckpoint::class.java)
            else null
        } catch (e: Exception) {
            null
        }
    }

    /** 清理所有检查点文件 */
    fun deleteAll() {
        try {
            val dir = File(filesDir, CHECKPOINTS_DIR)
            if (dir.isDirectory) dir.listFiles()?.forEach { it.delete() }
        } catch (e: Exception) {
            Log.e(TAG, "清理检查点失败: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "CheckpointManager"
        private const val CHECKPOINTS_DIR = "checkpoints"
    }
}