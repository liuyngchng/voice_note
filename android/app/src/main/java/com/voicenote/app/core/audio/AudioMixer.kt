package com.voicenote.app.core.audio

import android.util.Log
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 双源 PCM 混音器。
 *
 * 将麦克风流和系统音频流混合为一路输出。
 * 两路输入均为 16kHz / 16bit / mono 的小端序 PCM。
 *
 * 混音策略（与桌面版 [desktop/internal/audio/mixer.go] 对齐）：
 * - 麦克风流为主驱动源（始终有数据）
 * - 每次麦克风产出数据时，尝试非阻塞地从系统音频通道取数据
 * - 两路都有数据时逐 sample 平均（避免削波）
 * - 仅麦克风有数据时直接透传
 *
 * 输出为 16kHz / 16bit / mono 的小端序 PCM。
 */
class AudioMixer {

    companion object {
        private const val TAG = "AudioMixer"
    }

    /**
     * 混合两路 PCM 流。
     *
     * @param micFlow 麦克风采集流（主驱动源）
     * @param sysFlow 系统音频采集流（可能间歇性产出数据）
     * @return 混合后的 PCM 数据流
     */
    fun mix(
        micFlow: Flow<ByteArray>,
        sysFlow: Flow<ByteArray>
    ): Flow<ByteArray> = flow {
        coroutineScope {
            val sysChannel = Channel<ByteArray>(Channel.UNLIMITED)
            val sysJob = launch {
                try {
                    sysFlow.collect { chunk ->
                        sysChannel.send(chunk)
                    }
                } catch (_: Exception) {
                    // System audio flow ended or errored — mic-only fallback
                    Log.i(TAG, "System audio flow ended")
                }
            }

            try {
                micFlow.collect { micChunk ->
                    // Non-blocking try to get system audio chunk
                    val sysChunk = sysChannel.tryReceive().getOrNull()

                    if (sysChunk != null && sysChunk.isNotEmpty()) {
                        emit(mixPcmSamples(micChunk, sysChunk))
                    } else {
                        emit(micChunk)
                    }
                }
            } finally {
                sysChannel.close()
                sysJob.cancel()
                Log.i(TAG, "Mixer stopped")
            }
        }
    }

    /**
     * 将两路 16-bit PCM 数据逐 sample 平均混合。
     *
     * 较长的那一路决定输出长度；较短路缺失的 sample 视为静音 (0)。
     */
    private fun mixPcmSamples(a: ByteArray, b: ByteArray): ByteArray {
        val aSampleCount = a.size / 2
        val bSampleCount = b.size / 2
        val resultSampleCount = maxOf(aSampleCount, bSampleCount)
        val result = ByteArray(resultSampleCount * 2)
        val buf = ByteBuffer.wrap(result).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()

        for (i in 0 until resultSampleCount) {
            val aVal: Int = if (i < aSampleCount) {
                readShortLE(a, i * 2).toInt()
            } else 0

            val bVal: Int = if (i < bSampleCount) {
                readShortLE(b, i * 2).toInt()
            } else 0

            // Average the two sources to avoid clipping (matching mixer.go:147)
            buf.put(i, ((aVal + bVal) / 2).toShort())
        }

        return result
    }

    private fun readShortLE(bytes: ByteArray, offset: Int): Short {
        return (((bytes[offset + 1].toInt() shl 8) or
                (bytes[offset].toInt() and 0xFF))).toShort()
    }
}