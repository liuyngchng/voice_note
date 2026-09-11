package com.voicenote.app.core.audio

/** PCM 音频数据转换工具 */
object PcmUtil {

    /**
     * 将 16-bit 小端序 PCM 字节数组转换为归一化浮点数组 [-1, 1]。
     * 供 ASR 推理与实时音量计算复用。
     */
    fun convertPCMToFloats(pcmData: ByteArray): FloatArray {
        val sampleCount = pcmData.size / 2
        val floats = FloatArray(sampleCount)
        var offset = 0
        for (i in 0 until sampleCount) {
            val sample = ((pcmData[offset + 1].toInt() shl 8) or
                          (pcmData[offset].toInt() and 0xFF)).toShort()
            floats[i] = sample.toFloat() / 32768.0f
            offset += 2
        }
        return floats
    }
}