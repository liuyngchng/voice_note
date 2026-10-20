package com.voicenote.app.core.audio

import kotlinx.coroutines.flow.Flow

/**
 * 音频采集源接口。
 *
 * 与桌面版 [desktop/internal/audio/capture.go] 的 Recorder 接口对齐：
 * 一个采集源输出统一格式的 PCM 数据流（16kHz / 16bit / mono）。
 */
interface AudioCapture {
    /**
     * 开始采集，返回 PCM 数据块流。
     * 每个 chunk 为 16kHz / 16bit / mono 的小端序 PCM 字节。
     */
    fun startCapture(): Flow<ByteArray>

    /** 停止采集并释放底层设备。 */
    fun stopCapture()

    /** 当前是否正在采集。 */
    fun isRecording(): Boolean
}
