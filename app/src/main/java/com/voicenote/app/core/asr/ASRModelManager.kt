package com.voicenote.app.core.asr

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
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

enum class DownloadStatus { IDLE, DOWNLOADING, UPLOADING, EXTRACTING, COMPLETED, FAILED }

@Singleton
class ASRModelManager @Inject constructor(
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
        File(modelFilePath(quality)).exists()

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

        val targetModelFile = quality.modelFilename
        var foundModel = false
        var foundTokens = false

        val isCompressed = archiveFile.name.endsWith(".tar.bz2") || archiveFile.name.endsWith(".tar.gz") || archiveFile.name.endsWith(".bz2")
        Log.i(TAG, "开始解压: ${archiveFile.name} (${archiveFile.length() / 1_048_576}MB), compressed=$isCompressed, 目标模型: $targetModelFile")
        android.util.Log.e("REC_CRASH", "EXTRACT: starting, archive=${archiveFile.length()} bytes, compressed=$isCompressed, target=$targetModelFile")

        val rawInput = BufferedInputStream(FileInputStream(archiveFile))
        val decompressedInput = if (isCompressed) BZip2CompressorInputStream(rawInput) else rawInput

        decompressedInput.use { input ->
            TarArchiveInputStream(input).use { tarIn ->
                var entry = tarIn.nextTarEntry
                while (entry != null) {
                    val shortName = entry.name.substringAfterLast("/").ifBlank { entry.name }
                    android.util.Log.e("REC_CRASH", "EXTRACT: tar entry: $shortName (size=${entry.realSize})")

                    when {
                        shortName == targetModelFile -> {
                            Log.i(TAG, "正在提取模型: $targetModelFile (entry size=${entry.realSize})")
                            val outFile = File(modelsDir, targetModelFile)
                            FileOutputStream(outFile).use { out ->
                                tarIn.copyTo(out)
                            }
                            foundModel = true
                            android.util.Log.e("REC_CRASH", "EXTRACT: model extracted, file size=${outFile.length()} bytes")
                            Log.i(TAG, "模型提取完成: $targetModelFile")
                        }
                        shortName == "tokens.txt" -> {
                            val outFile = File(modelsDir, "tokens.txt")
                            FileOutputStream(outFile).use { out ->
                                tarIn.copyTo(out)
                            }
                            foundTokens = true
                            android.util.Log.e("REC_CRASH", "EXTRACT: tokens.txt extracted, size=${outFile.length()}")
                            Log.i(TAG, "tokens.txt 提取完成")
                        }
                    }

                    if (foundModel && foundTokens) break
                    entry = tarIn.nextTarEntry
                }
            }
        }

        android.util.Log.e("REC_CRASH", "EXTRACT: done, foundModel=$foundModel, foundTokens=$foundTokens")
        if (!foundModel) throw Exception("归档中未找到 $targetModelFile")
        if (!foundTokens) throw Exception("归档中未找到 tokens.txt")
    }

    suspend fun uploadModel(quality: ModelQuality, sourceUri: Uri): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val (fileName, fileSize) = queryFileInfo(sourceUri)
            android.util.Log.e("REC_CRASH", "UPLOAD: fileName=$fileName, fileSize=$fileSize")

            val isArchive = fileName?.endsWith(".tar.bz2") == true || fileName?.endsWith(".tar.gz") == true || fileName?.endsWith(".tar") == true
            val isModel = fileName?.endsWith(".onnx") == true

            if (!isArchive && !isModel) {
                val msg = "不支持的文件格式：${fileName ?: "未知"}。请上传 .tar.bz2、.tar.gz、.tar 归档或 .onnx 模型文件。"
                _downloadState.value = DownloadState(DownloadStatus.FAILED, 0f, msg)
                return@withContext Result.failure(Exception(msg))
            }

            _downloadState.value = DownloadState(DownloadStatus.UPLOADING, 0f)

            if (isArchive) {
                android.util.Log.e("REC_CRASH", "UPLOAD: archive detected, calling uploadArchive")
                uploadArchive(quality, sourceUri, fileName!!, fileSize)
            } else {
                android.util.Log.e("REC_CRASH", "UPLOAD: single file, calling uploadSingleFile")
                uploadSingleFile(quality, sourceUri, fileSize)
            }

            _downloadState.value = DownloadState(DownloadStatus.COMPLETED, 1f)
            android.util.Log.e("REC_CRASH", "UPLOAD: uploadModel COMPLETED for ${quality.name}")
            Log.i(TAG, "模型上传完成: ${quality.name}")
            Result.success(Unit)
        } catch (e: Exception) {
            android.util.Log.e("REC_CRASH", "UPLOAD: uploadModel FAILED: ${e.message}", e)
            Log.e(TAG, "上传失败: ${e.message}", e)
            _downloadState.value = DownloadState(DownloadStatus.FAILED, 0f, e.message)
            Result.failure(e)
        }
    }

    private fun queryFileInfo(uri: Uri): Pair<String?, Long> {
        var name: String? = null
        var size = 0L
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIdx >= 0) name = cursor.getString(nameIdx)
                val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIdx >= 0) size = cursor.getLong(sizeIdx)
            }
        }
        return name to size
    }

    private fun uploadArchive(quality: ModelQuality, sourceUri: Uri, fileName: String, fileSize: Long) {
        val tempDir = File(context.cacheDir, "model-upload").also { it.mkdirs() }
        val archiveFile = File(tempDir, fileName)

        try {
            // Copy archive to temp with progress
            android.util.Log.e("REC_CRASH", "UPLOAD: copying archive to temp, fileSize=$fileSize")
            var copiedBytes = 0L
            context.contentResolver.openInputStream(sourceUri)?.use { input ->
                FileOutputStream(archiveFile).use { output ->
                    val buffer = ByteArray(32768)
                    var bytesRead: Int
                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                        copiedBytes += bytesRead
                        if (fileSize > 0) {
                            _downloadState.value = DownloadState(DownloadStatus.UPLOADING, copiedBytes.toFloat() / fileSize)
                        }
                    }
                }
            } ?: throw Exception("无法读取文件")

            android.util.Log.e("REC_CRASH", "UPLOAD: copy done, copiedBytes=$copiedBytes, archiveFile.length=${archiveFile.length()}")
            if (!fileName.endsWith(".tar.bz2") && !fileName.endsWith(".tar")) {
                throw Exception("仅支持 .tar.bz2 或 .tar 归档格式")
            }

            Log.i(TAG, "上传归档文件: $fileName (${archiveFile.length()} bytes)")

            // Extract
            android.util.Log.e("REC_CRASH", "UPLOAD: starting extraction")
            _downloadState.value = DownloadState(DownloadStatus.EXTRACTING, 0.5f)
            extractArchive(archiveFile, quality)
            android.util.Log.e("REC_CRASH", "UPLOAD: extraction done")

            if (!isModelDownloaded(quality)) {
                throw Exception("归档中未找到模型文件 ${quality.modelFilename}")
            }

            Log.i(TAG, "归档上传完成: model=${quality.modelFilename}, tokens=${File(tokensFilePath()).exists()}")
            android.util.Log.e("REC_CRASH", "UPLOAD: archive upload complete, modelSize=${File(modelFilePath(quality)).length()}, tokensExists=${File(tokensFilePath()).exists()}")
        } finally {
            archiveFile.delete()
            tempDir.deleteRecursively()
        }
    }

    private suspend fun uploadSingleFile(quality: ModelQuality, sourceUri: Uri, fileSize: Long) {
        val targetFile = File(modelFilePath(quality))
        targetFile.parentFile?.mkdirs()

        context.contentResolver.openInputStream(sourceUri)?.use { input ->
            FileOutputStream(targetFile).use { output ->
                var copiedBytes = 0L
                val buffer = ByteArray(32768)
                var bytesRead: Int
                while (input.read(buffer).also { bytesRead = it } != -1) {
                    output.write(buffer, 0, bytesRead)
                    copiedBytes += bytesRead
                    if (fileSize > 0) {
                        _downloadState.value = DownloadState(
                            DownloadStatus.UPLOADING,
                            copiedBytes.toFloat() / fileSize
                        )
                    }
                }
            }
        } ?: throw Exception("无法读取文件")

        if (targetFile.length() < 1_000_000) {
            targetFile.delete()
            throw Exception("上传的文件过小，可能无效")
        }

        // Auto-fetch tokens.txt if missing
        ensureTokensExist()
    }

    private suspend fun ensureTokensExist() {
        if (File(tokensFilePath()).exists()) return

        Log.i(TAG, "tokens.txt 缺失，自动从网络获取...")
        try {
            val quality = ModelQuality.INT8
            val archiveFilename = quality.archiveFilename
            val url = "$BASE_URL/$archiveFilename"

            val tempDir = File(context.cacheDir, "tokens-fetch").also { it.mkdirs() }
            val archiveFile = File(tempDir, archiveFilename)

            val request = Request.Builder().url(url).build()
            val response = client.newCall(request).execute()

            if (!response.isSuccessful) {
                throw Exception("tokens.txt 下载失败: HTTP ${response.code}")
            }

            response.body?.byteStream()?.use { input ->
                FileOutputStream(archiveFile).use { output ->
                    input.copyTo(output)
                }
            }

            Log.i(TAG, "下载完成，提取 tokens.txt")

            BZip2CompressorInputStream(BufferedInputStream(FileInputStream(archiveFile))).use { bzIn ->
                TarArchiveInputStream(bzIn).use { tarIn ->
                    var entry = tarIn.nextTarEntry
                    while (entry != null) {
                        val shortName = entry.name.substringAfterLast("/").ifBlank { entry.name }
                        if (shortName == "tokens.txt") {
                            FileOutputStream(File(tokensFilePath())).use { out -> tarIn.copyTo(out) }
                            Log.i(TAG, "tokens.txt 提取成功")
                            break
                        }
                        entry = tarIn.nextTarEntry
                    }
                }
            }

            archiveFile.delete()
            tempDir.deleteRecursively()
        } catch (e: Exception) {
            Log.e(TAG, "自动获取 tokens.txt 失败: ${e.message}", e)
            throw Exception("tokens.txt 未找到且自动下载失败，请先上传完整的 .tar.bz2 归档")
        }
    }

    fun deleteModel(quality: ModelQuality) {
        val modelPath = modelFilePath(quality)
        val deleted = File(modelPath).delete()
        android.util.Log.e("REC_CRASH", "DELETE: asr model=${quality.name}, path=$modelPath, deleted=$deleted")

        val otherQuality = if (quality == ModelQuality.INT8) ModelQuality.FP32 else ModelQuality.INT8
        if (!isModelDownloaded(otherQuality)) {
            val tokensDeleted = File(tokensFilePath()).delete()
            val dirDeleted = modelsDir.deleteRecursively()
            android.util.Log.e("REC_CRASH", "DELETE: no other model, tokensDeleted=$tokensDeleted, dirDeleted=$dirDeleted")
        }

        _downloadState.value = DownloadState()
        Log.i(TAG, "模型已删除: ${quality.name}")
    }

    fun resetState() {
        _downloadState.value = DownloadState()
    }

    companion object {
        private const val TAG = "ASRModelManager"
        private const val BASE_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
    }
}
