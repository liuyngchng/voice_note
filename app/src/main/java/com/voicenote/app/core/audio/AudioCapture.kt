package com.voicenote.app.core.audio

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AudioCapture @Inject constructor() {

    private var audioRecord: AudioRecord? = null
    private var isRecording = false

    companion object {
        const val SAMPLE_RATE = 16000
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        const val BUFFER_SIZE_FACTOR = 2
    }

    private val bufferSize: Int by lazy {
        val minSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        minSize * BUFFER_SIZE_FACTOR
    }

    fun startCapture(): Flow<ByteArray> = flow {
        android.util.Log.e("REC_CRASH", "AUDIO: startCapture flow entered")
        try {
            android.util.Log.e("REC_CRASH", "AUDIO: creating AudioRecord, bufferSize=$bufferSize")
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                CHANNEL_CONFIG,
                AUDIO_FORMAT,
                bufferSize
            ).also {
                android.util.Log.e("REC_CRASH", "AUDIO: AudioRecord created, state=${it.state}")
                if (it.state != AudioRecord.STATE_INITIALIZED) {
                    throw IllegalStateException("AudioRecord initialization failed, state=${it.state}")
                }
                it.startRecording()
                isRecording = true
                android.util.Log.e("REC_CRASH", "AUDIO: AudioRecord started, reading loop begin")
            }

            val buffer = ByteArray(bufferSize)
            while (isRecording) {
                val bytesRead = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                if (bytesRead > 0) {
                    emit(buffer.copyOf(bytesRead))
                }
            }
        } finally {
            android.util.Log.e("REC_CRASH", "AUDIO: startCapture flow ending, calling stopCapture")
            stopCapture()
        }
    }.flowOn(Dispatchers.IO)

    fun stopCapture() {
        isRecording = false
        try {
            audioRecord?.stop()
        } catch (_: Exception) {}
        try {
            audioRecord?.release()
        } catch (_: Exception) {}
        audioRecord = null
    }

    fun isRecording(): Boolean = isRecording
}
