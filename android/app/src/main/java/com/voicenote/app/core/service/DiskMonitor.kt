package com.voicenote.app.core.service

import android.content.Context
import android.os.PowerManager
import android.util.Log
import com.voicenote.app.core.audio.AudioFileManager
import java.io.File
import java.io.IOException

/**
 * 磁盘空间和写入错误监控器，从 [RecordingService] 中抽离。
 * 每 5 分钟检查一次可用空间，低于 500MB 时发出告警。
 */
class DiskMonitor(
    private val filesDir: File,
    private val audioFileManager: AudioFileManager
) {
    private var lastStatus: Status = Status.OK

    enum class Status { OK, LOW_SPACE, WRITE_ERROR }

    /** 检查磁盘状态，返回 false 表示应该停止录音 */
    fun check(): Boolean {
        val usableSpace = filesDir.usableSpace
        if (usableSpace < MIN_FREE_SPACE_BYTES) {
            lastStatus = Status.LOW_SPACE
            Log.w(TAG, "磁盘空间不足 (剩余 ${usableSpace / 1_048_576}MB)")
            return false
        }
        if (audioFileManager.hasWriteError()) {
            lastStatus = Status.WRITE_ERROR
            Log.w(TAG, "磁盘写入失败")
            return false
        }
        lastStatus = Status.OK
        return true
    }

    /** 获取用户可读的状态描述 */
    fun statusMessage(): String? = when (lastStatus) {
        Status.LOW_SPACE -> "磁盘空间不足，请停止录音"
        Status.WRITE_ERROR -> "磁盘写入失败，录音已中断"
        Status.OK -> null
    }

    fun notificationMessage(): String? = when (lastStatus) {
        Status.LOW_SPACE -> "磁盘空间不足 (剩余 ${filesDir.usableSpace / 1_048_576}MB)"
        Status.WRITE_ERROR -> "磁盘写入失败，录音已中断"
        Status.OK -> null
    }

    companion object {
        private const val TAG = "DiskMonitor"
        private const val MIN_FREE_SPACE_BYTES = 500L * 1024 * 1024  // 500 MB
    }
}