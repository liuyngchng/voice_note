package com.voicenote.app.core.audio

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

/**
 * 系统播放声音采集源。
 *
 * 通过 [AudioPlaybackCaptureConfiguration] + [MediaProjection] 捕获设备播放的音频
 * （其他 app 发出的声音，如在线会议中对方说话声）。
 * 需要用户通过 MediaProjection 授权（每次录音弹一次系统对话框）。
 *
 * 对应桌面版 WASAPI Loopback 采集：
 * [desktop/internal/audio/capture_windows_loopback.go]
 *
 * 要求 Android 10 (API 29)+。
 *
 * 输出 16kHz / 16bit / mono 的 PCM 数据流。
 */
class SystemAudioCapture(
    private val mediaProjection: MediaProjection,
    private val sampleRate: Int = 16000,
    private val channelConfig: Int = AudioFormat.CHANNEL_IN_MONO,
    private val audioFormat: Int = AudioFormat.ENCODING_PCM_16BIT
) : AudioCapture {

    private var audioRecord: AudioRecord? = null
    private var isRecording = false

    private val bufferSize: Int by lazy {
        val minSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        minSize * 2
    }

    @SuppressLint("MissingPermission")
    override fun startCapture(): Flow<ByteArray> = flow {
        Log.i(TAG, "SystemAudioCapture: starting...")
        try {
            val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()

            audioRecord = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(audioFormat)
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelConfig)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .build()
                .also {
                    Log.i(TAG, "SystemAudioCapture: AudioRecord created, state=${it.state}")
                    if (it.state != AudioRecord.STATE_INITIALIZED) {
                        throw IllegalStateException(
                            "SystemAudioCapture AudioRecord initialization failed, state=${it.state}"
                        )
                    }
                    it.startRecording()
                    isRecording = true
                    Log.i(TAG, "SystemAudioCapture: AudioRecord started, reading loop begin")
                }

            val buffer = ByteArray(bufferSize)
            while (isRecording) {
                val bytesRead = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                if (bytesRead > 0) {
                    emit(buffer.copyOf(bytesRead))
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "SystemAudioCapture: error: ${e.message}", e)
            // Don't crash — system audio might not be available for various reasons.
            // The mixer will fall back to mic-only.
        } finally {
            Log.i(TAG, "SystemAudioCapture: flow ending, calling stopCapture")
            stopCapture()
        }
    }.flowOn(Dispatchers.IO)

    override fun stopCapture() {
        isRecording = false
        try {
            audioRecord?.stop()
        } catch (_: Exception) {}
        try {
            audioRecord?.release()
        } catch (_: Exception) {}
        audioRecord = null
        Log.i(TAG, "SystemAudioCapture: stopped")
    }

    override fun isRecording(): Boolean = isRecording

    companion object {
        private const val TAG = "SystemAudioCapture"
    }
}