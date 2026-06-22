package com.voicenote.app.core.asr

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

data class DownloadState(
    val status: DownloadStatus = DownloadStatus.IDLE,
    val progress: Float = 0f,
    val error: String? = null
)

enum class DownloadStatus { IDLE, DOWNLOADING, EXTRACTING, COMPLETED, FAILED }

@Singleton
class ModelDownloadManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val _downloadState = MutableStateFlow(DownloadState())
    val downloadState: StateFlow<DownloadState> = _downloadState.asStateFlow()

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(300, TimeUnit.SECONDS)
        .build()

    private val modelsDir: File
        get() = File(context.filesDir, "models/sense-voice").also { it.mkdirs() }

    fun tokensFilePath(): String = File(modelsDir, "tokens.txt").absolutePath
    fun modelFilePath(quality: ModelQuality): String = File(modelsDir, quality.modelFilename).absolutePath

    fun isModelDownloaded(quality: ModelQuality): Boolean =
        File(modelFilePath(quality)).exists() && File(tokensFilePath()).exists()

    fun downloadedModelSize(quality: ModelQuality): Long =
        File(modelFilePath(quality)).length()

    suspend fun downloadModel(quality: ModelQuality): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            _downloadState.value = DownloadState(DownloadStatus.DOWNLOADING, 0f)

            val archiveFilename = quality.archiveFilename
            val url = "$BASE_URL/$archiveFilename"

            Log.i(TAG, "开始下载模型: ${quality.name} from $url")

            val tempDir = File(context.cacheDir, "model-download").also { it.mkdirs() }
            val archiveFile = File(tempDir, archiveFilename)

            // Download
            val request = Request.Builder().url(url).build()
            val response = client.newCall(request).execute()

            if (!response.isSuccessful) {
                return@withContext Result.failure(Exception("HTTP ${response.code}"))
            }

            val body = response.body ?: return@withContext Result.failure(Exception("Empty response"))
            val totalBytes = body.contentLength()
            var downloadedBytes = 0L

            body.byteStream().use { input ->
                FileOutputStream(archiveFile).use { output ->
                    val buffer = ByteArray(8192)
                    var bytesRead: Int
                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                        downloadedBytes += bytesRead
                        if (totalBytes > 0) {
                            _downloadState.value = DownloadState(
                                DownloadStatus.DOWNLOADING,
                                downloadedBytes.toFloat() / totalBytes
                            )
                        }
                    }
                }
            }

            Log.i(TAG, "下载完成: $archiveFilename")

            // Extract
            _downloadState.value = DownloadState(DownloadStatus.EXTRACTING, 0.5f)
            extractArchive(archiveFile, quality)

            // Verify
            if (!isModelDownloaded(quality)) {
                return@withContext Result.failure(Exception("验证失败，文件缺失"))
            }

            // Cleanup
            tempDir.deleteRecursively()
            _downloadState.value = DownloadState(DownloadStatus.COMPLETED, 1f)
            Log.i(TAG, "模型安装完成: ${quality.name}")

            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "下载失败: ${e.message}", e)
            _downloadState.value = DownloadState(DownloadStatus.FAILED, 0f, e.message)
            Result.failure(e)
        }
    }

    private fun extractArchive(archiveFile: File, quality: ModelQuality) {
        modelsDir.mkdirs()

        val tarFile = File(archiveFile.parent, archiveFile.name.removeSuffix(".bz2"))

        // bzip2 → tar
        BZip2CompressorInputStream(BufferedInputStream(FileInputStream(archiveFile))).use { bzIn ->
            FileOutputStream(tarFile).use { bzOut ->
                bzIn.copyTo(bzOut)
            }
        }

        Log.i(TAG, "bzip2 解压完成")

        // Extract from tar
        val targetModelFile = quality.modelFilename
        var foundModel = false
        var foundTokens = false

        TarArchiveInputStream(FileInputStream(tarFile)).use { tarIn ->
            var entry = tarIn.nextTarEntry
            while (entry != null) {
                val shortName = entry.name.substringAfterLast("/").ifBlank { entry.name }

                when {
                    shortName == targetModelFile -> {
                        FileOutputStream(File(modelsDir, targetModelFile)).use { out ->
                            tarIn.copyTo(out)
                        }
                        foundModel = true
                        Log.i(TAG, "提取完成: $targetModelFile")
                    }
                    shortName == "tokens.txt" -> {
                        FileOutputStream(File(modelsDir, "tokens.txt")).use { out ->
                            tarIn.copyTo(out)
                        }
                        foundTokens = true
                        Log.i(TAG, "提取完成: tokens.txt")
                    }
                }

                if (foundModel && foundTokens) break
                entry = tarIn.nextTarEntry
            }
        }

        // Cleanup tar
        tarFile.delete()

        if (!foundModel) throw Exception("归档中未找到 $targetModelFile")
        if (!foundTokens) throw Exception("归档中未找到 tokens.txt")
    }

    fun deleteModel(quality: ModelQuality) {
        File(modelFilePath(quality)).delete()

        val otherQuality = if (quality == ModelQuality.INT8) ModelQuality.FP32 else ModelQuality.INT8
        if (!isModelDownloaded(otherQuality)) {
            File(tokensFilePath()).delete()
            modelsDir.deleteRecursively()
        }

        _downloadState.value = DownloadState()
        Log.i(TAG, "模型已删除: ${quality.name}")
    }

    fun resetState() {
        _downloadState.value = DownloadState()
    }

    companion object {
        private const val TAG = "ModelDownloadManager"
        private const val BASE_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
    }
}
