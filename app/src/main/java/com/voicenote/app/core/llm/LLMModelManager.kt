package com.voicenote.app.core.llm

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
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

data class LLMDownloadState(
    val status: LLMDownloadStatus = LLMDownloadStatus.IDLE,
    val progress: Float = 0f,
    val error: String? = null
)

enum class LLMDownloadStatus { IDLE, DOWNLOADING, UPLOADING, COMPLETED, FAILED }

@Singleton
class LLMModelManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val _downloadState = MutableStateFlow(LLMDownloadState())
    val downloadState: StateFlow<LLMDownloadState> = _downloadState.asStateFlow()

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(600, TimeUnit.SECONDS)
        .build()

    private val modelsDir: File
        get() = File(context.filesDir, "models/llm").also { it.mkdirs() }

    fun modelFilePath(info: LLMModelInfo): String =
        File(modelsDir, info.modelFilename).absolutePath

    fun isModelDownloaded(info: LLMModelInfo): Boolean =
        File(modelFilePath(info)).exists()

    fun downloadedModelSize(info: LLMModelInfo): Long =
        File(modelFilePath(info)).length()

    suspend fun downloadModel(info: LLMModelInfo): Result<Unit> = withContext(Dispatchers.IO) {
        val url = info.modelscopeDownloadURL
            ?: return@withContext Result.failure(Exception("该模型暂不支持直接下载"))

        try {
            _downloadState.value = LLMDownloadState(LLMDownloadStatus.DOWNLOADING, 0f)

            Log.i(TAG, "开始下载: ${info.name} from $url")

            val request = Request.Builder().url(url).build()
            val response = client.newCall(request).execute()

            if (!response.isSuccessful) {
                return@withContext Result.failure(Exception("HTTP ${response.code}"))
            }

            val body = response.body ?: return@withContext Result.failure(Exception("Empty response"))
            val totalBytes = body.contentLength()
            var downloadedBytes = 0L
            val targetFile = File(modelFilePath(info))
            targetFile.parentFile?.mkdirs()

            body.byteStream().use { input ->
                FileOutputStream(targetFile).use { output ->
                    val buffer = ByteArray(8192)
                    var bytesRead: Int
                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                        downloadedBytes += bytesRead
                        if (totalBytes > 0) {
                            _downloadState.value = LLMDownloadState(
                                LLMDownloadStatus.DOWNLOADING,
                                downloadedBytes.toFloat() / totalBytes
                            )
                        }
                    }
                }
            }

            // Verify
            val fileSize = targetFile.length()
            if (fileSize < 10_000_000) {
                targetFile.delete()
                return@withContext Result.failure(Exception("下载的文件过小，可能无效"))
            }

            _downloadState.value = LLMDownloadState(LLMDownloadStatus.COMPLETED, 1f)
            Log.i(TAG, "模型下载完成: ${info.name} (${fileSize / 1_048_576}MB)")

            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "下载失败: ${e.message}", e)
            _downloadState.value = LLMDownloadState(LLMDownloadStatus.FAILED, 0f, e.message)
            Result.failure(e)
        }
    }

    suspend fun uploadModel(info: LLMModelInfo, sourceUri: Uri): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            _downloadState.value = LLMDownloadState(LLMDownloadStatus.UPLOADING, 0f)

            // Query actual file size from content resolver
            var totalBytes = 0L
            context.contentResolver.query(sourceUri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (idx >= 0) totalBytes = cursor.getLong(idx)
                }
            }

            val targetFile = File(modelFilePath(info))
            targetFile.parentFile?.mkdirs()

            context.contentResolver.openInputStream(sourceUri)?.use { input ->
                FileOutputStream(targetFile).use { output ->
                    var copiedBytes = 0L
                    val buffer = ByteArray(32768)
                    var bytesRead: Int
                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                        copiedBytes += bytesRead
                        if (totalBytes > 0) {
                            _downloadState.value = LLMDownloadState(
                                LLMDownloadStatus.UPLOADING,
                                copiedBytes.toFloat() / totalBytes
                            )
                        }
                    }
                }
            } ?: return@withContext Result.failure(Exception("无法读取文件"))

            val fileSize = targetFile.length()
            if (fileSize < 10_000_000) {
                targetFile.delete()
                return@withContext Result.failure(Exception("上传的文件过小，可能无效"))
            }

            _downloadState.value = LLMDownloadState(LLMDownloadStatus.COMPLETED, 1f)
            Log.i(TAG, "模型上传完成: ${info.name} (${fileSize / 1_048_576}MB)")
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "上传失败: ${e.message}", e)
            _downloadState.value = LLMDownloadState(LLMDownloadStatus.FAILED, 0f, e.message)
            Result.failure(e)
        }
    }

    fun deleteModel(info: LLMModelInfo) {
        File(modelFilePath(info)).delete()
        if (modelsDir.listFiles()?.isEmpty() == true) {
            modelsDir.delete()
        }
        _downloadState.value = LLMDownloadState()
        Log.i(TAG, "模型已删除: ${info.name}")
    }

    fun resetState() {
        _downloadState.value = LLMDownloadState()
    }

    companion object {
        private const val TAG = "LLMModelManager"
    }
}
