package com.voicenote.app.core.audio

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AudioFileManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private var outputStream: FileOutputStream? = null
    private var pcmFile: File? = null
    private var recordAudioDir: File? = null
    private var currentBaseName: String? = null

    fun startNewRecording(recordId: Long, startTime: Instant) {
        val audioDir = File(context.filesDir, "audio/record_$recordId")
        audioDir.mkdirs()
        recordAudioDir = audioDir

        currentBaseName = dateFormatter.format(startTime)
        val pcm = File(audioDir, "${currentBaseName}.wav.pcm")
        pcmFile = pcm
        outputStream = FileOutputStream(pcm)
    }

    fun writeAudioChunk(data: ByteArray) {
        outputStream?.write(data)
    }

    fun finalizeRecording(): String {
        outputStream?.close()
        outputStream = null

        val pcm = pcmFile ?: return ""
        val baseName = currentBaseName ?: return ""
        val wavFile = File(recordAudioDir, "$baseName.wav")

        val pcmLength = pcm.length()
        val dataSize = pcmLength.toInt()
        val fileSize = dataSize + 36 // total file bytes minus 8

        FileOutputStream(wavFile).buffered().use { wavOut ->
            // RIFF header
            wavOut.write("RIFF".toByteArray())
            wavOut.write(intToLittleEndian(fileSize))
            wavOut.write("WAVE".toByteArray())
            // fmt sub-chunk
            wavOut.write("fmt ".toByteArray())
            wavOut.write(intToLittleEndian(16)) // sub-chunk size
            wavOut.write(shortToLittleEndian(1)) // PCM format
            wavOut.write(shortToLittleEndian(1)) // mono
            wavOut.write(intToLittleEndian(16000)) // sample rate
            wavOut.write(intToLittleEndian(32000)) // byte rate
            wavOut.write(shortToLittleEndian(2)) // block align
            wavOut.write(shortToLittleEndian(16)) // bits per sample
            // data sub-chunk
            wavOut.write("data".toByteArray())
            wavOut.write(intToLittleEndian(dataSize))
            // PCM data
            pcmFile!!.inputStream().buffered().use { pcmIn ->
                pcmIn.copyTo(wavOut)
            }
        }

        pcmFile!!.delete()
        pcmFile = null
        return wavFile.absolutePath
    }

    fun finalizeTranscript(text: String): String {
        if (text.isBlank() || recordAudioDir == null || currentBaseName == null) return ""
        val txtFile = File(recordAudioDir, "${currentBaseName}.txt")
        txtFile.writeText(text)
        return txtFile.absolutePath
    }

    fun deleteAudioFile(audioFilePath: String) {
        if (audioFilePath.isBlank()) return
        val file = File(audioFilePath)
        if (file.exists()) file.delete()
        // Delete corresponding transcript file
        val txtFile = File(file.absolutePath.replace(".wav", ".txt"))
        if (txtFile.exists()) txtFile.delete()
        file.parentFile?.delete() // remove empty directory
    }

    private fun intToLittleEndian(value: Int): ByteArray {
        return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()
    }

    private fun shortToLittleEndian(value: Short): ByteArray {
        return ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(value).array()
    }

    companion object {
        private val dateFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmm")
            .withZone(ZoneId.systemDefault())
    }
}