package com.voicenote.app.core.audio

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
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
    private var wavFile: File? = null
    private var recordAudioDir: File? = null
    private var currentBaseName: String? = null

    /** Total PCM data bytes written (excluding WAV header). */
    private var dataBytesWritten: Long = 0

    /** Last time FileDescriptor.sync() was called. */
    private var lastSyncTimeMs: Long = 0

    // ── Recording lifecycle ──────────────────────────────────────────────────

    fun startNewRecording(recordId: Long, startTime: Instant) {
        val audioDir = File(context.filesDir, "audio/record_$recordId")
        audioDir.mkdirs()
        recordAudioDir = audioDir

        currentBaseName = dateFormatter.format(startTime)
        val wav = File(audioDir, "${currentBaseName}.wav")
        wavFile = wav
        dataBytesWritten = 0
        lastSyncTimeMs = System.currentTimeMillis()

        // Write initial WAV header with dataSize=0 — will be patched in finalizeRecording()
        outputStream = FileOutputStream(wav)
        writeWavHeader(outputStream!!, dataSize = 0)
    }

    fun getCurrentFilePath(): String = wavFile?.absolutePath ?: ""

    fun writeAudioChunk(data: ByteArray) {
        outputStream?.write(data)
        dataBytesWritten += data.size

        // Periodic fsync: every ~30 seconds to bound data loss on crash
        val now = System.currentTimeMillis()
        if (now - lastSyncTimeMs >= SYNC_INTERVAL_MS) {
            flushAndCheckpoint()
        }
    }

    /**
     * Force-flush buffered data to disk and return the number of PCM data bytes
     * safely persisted so far. Called by [RecordingService] during checkpointing.
     */
    fun flushAndCheckpoint(): Long {
        try {
            outputStream?.flush()
            outputStream?.fd?.sync()
            lastSyncTimeMs = System.currentTimeMillis()
        } catch (e: Exception) {
            Log.e(TAG, "flush/sync failed: ${e.message}", e)
        }
        return dataBytesWritten
    }

    /**
     * Finalize the recording: sync to disk, patch the WAV header with actual
     * data sizes, close the stream, and return the absolute path.
     */
    fun finalizeRecording(): String {
        flushAndCheckpoint()
        outputStream?.close()
        outputStream = null

        val wav = wavFile ?: return ""
        wavFile = null

        // Patch RIFF size and data chunk size in the header
        try {
            patchWavHeader(wav, dataBytesWritten)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to patch WAV header: ${e.message}", e)
        }

        Log.i(TAG, "Recording finalized: ${wav.absolutePath} (${dataBytesWritten} bytes PCM data)")
        return wav.absolutePath
    }

    // ── Crash recovery ────────────────────────────────────────────────────────

    /**
     * Attempt to resume appending to an existing WAV file whose header may
     * under-report the actual size (because the previous session crashed before
     * finalizeRecording() could patch the header).
     *
     * @return true if the file was successfully opened for appending.
     */
    fun resumeRecording(recordId: Long, existingWavPath: String): Boolean {
        val existingFile = File(existingWavPath)
        if (!existingFile.exists()) {
            Log.w(TAG, "resumeRecording: file not found: $existingWavPath")
            return false
        }

        return try {
            val parsedDataSize = parseWavDataSize(existingFile)
            // The actual data may be shorter than header claims if the header was
            // already patched, or longer if a previous resume patched it.
            // Use the file system ground truth (what's actually on disk).
            val fileLength = existingFile.length()
            val headerSize = findDataOffset(existingFile)
            dataBytesWritten = (fileLength - headerSize).coerceAtLeast(0)

            recordAudioDir = existingFile.parentFile
            currentBaseName = existingFile.nameWithoutExtension
            wavFile = existingFile

            // Open in append mode — writes go after existing data
            outputStream = FileOutputStream(existingFile, true)
            lastSyncTimeMs = System.currentTimeMillis()

            Log.i(TAG, "Resumed recording: $existingWavPath, " +
                "headerDataSize=$parsedDataSize, actualDataBytes=$dataBytesWritten")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resume recording: ${e.message}", e)
            false
        }
    }

    /** Read the data chunk size from a WAV header (what the RIFF claims). */
    private fun parseWavDataSize(file: File): Long {
        RandomAccessFile(file, "r").use { raf ->
            if (raf.length() < 44) return 0
            val header = ByteArray(4)
            raf.read(header)
            if (String(header) != "RIFF") return 0
            raf.skipBytes(8) // skip RIFF size + "WAVE"
            val chunkHeader = ByteArray(8)
            while (raf.filePointer + 8 <= raf.length()) {
                raf.readFully(chunkHeader)
                val chunkId = String(chunkHeader, 0, 4)
                val chunkSize = readUint32LE(chunkHeader, 4)
                if (chunkId == "data") return chunkSize
                raf.seek(raf.filePointer + chunkSize)
            }
            return 0
        }
    }

    /** Find the byte offset where PCM data starts in a WAV file. */
    private fun findDataOffset(file: File): Long {
        RandomAccessFile(file, "r").use { raf ->
            if (raf.length() < 44) return 44
            raf.skipBytes(12) // RIFF header
            val chunkHeader = ByteArray(8)
            while (raf.filePointer + 8 <= raf.length()) {
                raf.readFully(chunkHeader)
                val chunkId = String(chunkHeader, 0, 4)
                val chunkSize = readUint32LE(chunkHeader, 4)
                if (chunkId == "data") return raf.filePointer
                raf.seek(raf.filePointer + chunkSize)
            }
            return 44 // fallback: assume standard 44-byte header
        }
    }

    // ── WAV header I/O ────────────────────────────────────────────────────────

    private fun writeWavHeader(stream: FileOutputStream, dataSize: Long) {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray())
        // RIFF chunk size = 36 + dataSize (capped to u32 max)
        header.putInt((dataSize + 36).coerceIn(0, 0xFFFFFFFFL).toInt())
        header.put("WAVE".toByteArray())
        header.put("fmt ".toByteArray())
        header.putInt(16)              // sub-chunk size
        header.putShort(1)             // PCM format
        header.putShort(1)             // mono
        header.putInt(16000)           // sample rate
        header.putInt(32000)           // byte rate (sampleRate * channels * bitsPerSample/8)
        header.putShort(2)             // block align
        header.putShort(16)            // bits per sample
        header.put("data".toByteArray())
        header.putInt(dataSize.coerceIn(0, 0xFFFFFFFFL).toInt())
        stream.write(header.array())
    }

    private fun patchWavHeader(wav: File, dataSize: Long) {
        RandomAccessFile(wav, "rw").use { raf ->
            val safeDataSize = dataSize.coerceIn(0, 0xFFFFFFFFL)
            // RIFF size at offset 4
            raf.seek(4)
            raf.write(intToLittleEndian((safeDataSize + 36).coerceIn(0, 0xFFFFFFFFL).toInt()))
            // data chunk size at offset 40
            raf.seek(40)
            raf.write(intToLittleEndian(safeDataSize.toInt()))
        }
    }

    // ── File management ──────────────────────────────────────────────────────

    fun deleteAudioFile(audioFilePath: String, transcriptFilePath: String = "") {
        if (audioFilePath.isBlank()) return
        val file = File(audioFilePath)
        if (file.exists()) file.delete()
        if (transcriptFilePath.isNotBlank()) {
            val txtFile = File(transcriptFilePath)
            if (txtFile.exists()) txtFile.delete()
        }
        file.parentFile?.delete() // remove empty directory
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun intToLittleEndian(value: Int): ByteArray {
        return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()
    }

    private fun readUint32LE(bytes: ByteArray, offset: Int): Long {
        return ((bytes[offset].toInt() and 0xFF).toLong() or
                ((bytes[offset + 1].toInt() and 0xFF).toLong() shl 8) or
                ((bytes[offset + 2].toInt() and 0xFF).toLong() shl 16) or
                ((bytes[offset + 3].toInt() and 0xFF).toLong() shl 24))
    }

    companion object {
        private const val TAG = "AudioFileManager"
        private const val SYNC_INTERVAL_MS = 30_000L  // fsync every 30 seconds
        private val dateFormatter = DateTimeFormatter.ofPattern("yyyyMMdd_HHmm")
            .withZone(ZoneId.systemDefault())
    }
}
