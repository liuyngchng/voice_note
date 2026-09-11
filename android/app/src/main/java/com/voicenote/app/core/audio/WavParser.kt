package com.voicenote.app.core.audio

import java.io.File
import java.io.RandomAccessFile

/**
 * WAV 文件头解析工具。
 * 统一提供 WAV 头字段的解析能力，供 [AudioFileManager] 和 [com.voicenote.app.ui.detail.DetailViewModel]
 * 复用，避免重复的字节级解析逻辑。
 */
object WavParser {

    data class WavInfo(
        val dataOffset: Long = 44,
        val dataSize: Long = 0,
        val sampleRate: Int = 16000,
        val channels: Int = 1,
        val bitsPerSample: Int = 16,
        val totalFrames: Long = 0
    )

    /** 读取小端序 uint32 */
    private fun readUint32LE(bytes: ByteArray, offset: Int): Long {
        return ((bytes[offset].toInt() and 0xFF).toLong() or
                ((bytes[offset + 1].toInt() and 0xFF).toLong() shl 8) or
                ((bytes[offset + 2].toInt() and 0xFF).toLong() shl 16) or
                ((bytes[offset + 3].toInt() and 0xFF).toLong() shl 24))
    }

    /** 读取小端序 uint16 */
    private fun readUint16LE(bytes: ByteArray, offset: Int): Int {
        return ((bytes[offset].toInt() and 0xFF) or
                ((bytes[offset + 1].toInt() and 0xFF) shl 8))
    }

    /**
     * 解析 WAV 头，返回 PCM 数据偏移、大小及音频格式字段。
     * 找不到 data chunk 时 dataOffset 回退为 44（标准 44 字节头），dataSize 为 0。
     */
    fun parse(file: File): WavInfo {
        RandomAccessFile(file, "r").use { raf ->
            if (raf.length() < 44) {
                return WavInfo(44, 0, 16000, 1, 16, 0)
            }

            val header = ByteArray(12)
            raf.readFully(header)
            if (String(header, 0, 4) != "RIFF") {
                return WavInfo(44, 0, 16000, 1, 16, 0)
            }

            var channels = 1
            var sampleRate = 16000
            var bitsPerSample = 16
            var dataOffset = 44L
            var dataSize = 0L

            val chunkHeader = ByteArray(8)
            while (raf.filePointer + 8 <= raf.length()) {
                val bytesRead = raf.read(chunkHeader)
                if (bytesRead < 8) break

                val chunkId = String(chunkHeader, 0, 4)
                val chunkSize = readUint32LE(chunkHeader, 4)

                when (chunkId) {
                    "fmt " -> {
                        val fmtData = ByteArray(chunkSize.toInt().coerceAtMost(16))
                        raf.readFully(fmtData)
                        channels = readUint16LE(fmtData, 2)
                        sampleRate = readUint32LE(fmtData, 4).toInt()
                        bitsPerSample = readUint16LE(fmtData, 14)
                    }
                    "data" -> {
                        dataOffset = raf.filePointer
                        dataSize = chunkSize
                        val bytesPerFrame = channels.toLong() * (bitsPerSample / 8)
                        val totalFrames = if (bytesPerFrame > 0) dataSize / bytesPerFrame else 0
                        return WavInfo(dataOffset, dataSize, sampleRate, channels, bitsPerSample, totalFrames)
                    }
                    else -> {
                        val skipTo = raf.filePointer + chunkSize
                        if (skipTo < raf.length()) raf.seek(skipTo) else break
                    }
                }
            }

            val bytesPerFrame = channels.toLong() * (bitsPerSample / 8)
            val totalFrames = if (bytesPerFrame > 0) dataSize / bytesPerFrame else 0
            return WavInfo(dataOffset, dataSize, sampleRate, channels, bitsPerSample, totalFrames)
        }
    }
}