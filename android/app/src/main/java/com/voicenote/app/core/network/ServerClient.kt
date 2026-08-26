package com.voicenote.app.core.network

import android.util.Log
import com.google.gson.Gson
import com.google.gson.JsonParser
import com.voicenote.app.domain.model.VoiceRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 上传结果。
 * @param serverRecordId 服务端分配的记录 ID
 * @param message 服务端返回的消息
 */
data class UploadResult(
    val serverRecordId: String,
    val message: String
)

/**
 * 服务器客户端 — 通过 HTTP 调用 server_j 的 REST API。
 *
 * API 契约（对齐 server_j NettyHttpServer）：
 * 1. POST /api/auth/login  → {username, password} → {token, username}
 * 2. POST /api/records     → multipart: metadata(JSON) + audio(file) → {record, transcript_status}
 *
 * 上传后服务端自动后台转写（阿里云百炼 qwen3-asr-flash），
 * 客户端仅上传即可。
 */
@Singleton
class ServerClient @Inject constructor() {

    private val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()

    private val gson = Gson()

    /** 缓存的服务端 token，用于后续上传请求 */
    @Volatile private var cachedToken: String? = null

    companion object {
        private const val TAG = "ServerClient"
        private const val API_LOGIN = "/api/auth/login"
        private const val API_RECORDS = "/api/records"
    }

    // ---- 公开接口 ----

    /**
     * 上传音频文件到服务器。
     * 服务器收到后自动后台转写，客户端无需等待转写结果。
     *
     * @param audioFile 本地音频文件
     * @param record  录音记录，用于提取元数据
     * @param serverUri 服务器 HTTP 地址，如 http://192.168.1.110:8080
     * @param onProgress 进度回调
     * @return Result<UploadResult> 包含服务端记录 ID
     */
    suspend fun uploadAudio(
        audioFile: File,
        record: VoiceRecord,
        serverUri: String,
        onProgress: ((String) -> Unit)? = null
    ): Result<UploadResult> = withContext(Dispatchers.IO) {
        if (serverUri.isBlank()) {
            return@withContext Result.failure(IllegalArgumentException("服务器地址未配置"))
        }
        if (!audioFile.exists()) {
            return@withContext Result.failure(IllegalArgumentException("音频文件不存在"))
        }

        try {
            onProgress?.invoke("正在连接服务器...")

            // 1. 确保已登录
            val token = ensureLoggedIn(serverUri)
            if (token == null) {
                return@withContext Result.failure(Exception("服务器登录失败"))
            }

            onProgress?.invoke("正在上传音频...")

            // 2. 上传音频
            doUpload(serverUri, token, audioFile, record, onProgress)
        } catch (e: Exception) {
            Log.e(TAG, "uploadAudio failed", e)
            Result.failure(e)
        }
    }

    // ---- 登录 ----

    /**
     * 自动登录服务端，使用默认管理员账号。
     */
    private suspend fun ensureLoggedIn(serverUri: String): String? {
        if (cachedToken != null) {
            return cachedToken
        }

        return try {
            val loginUrl = normalizeUrl(serverUri) + API_LOGIN
            val body = mapOf(
                "username" to "admin",
                "password" to "admin123"
            )
            val jsonBody = gson.toJson(body)

            val request = Request.Builder()
                .url(loginUrl)
                .header("Content-Type", "application/json")
                .post(jsonBody.toRequestBody("application/json".toMediaType()))
                .build()

            val response = okHttpClient.newCall(request).execute()
            val responseBody = response.body?.string() ?: ""

            if (!response.isSuccessful) {
                Log.e(TAG, "login failed: code=${response.code}, body=$responseBody")
                return null
            }

            val root = JsonParser.parseString(responseBody).asJsonObject
            val token = root.get("token")?.asString
            if (token != null) {
                cachedToken = token
                Log.i(TAG, "login success, token cached")
            }
            token
        } catch (e: Exception) {
            Log.e(TAG, "login failed: ${e.message}", e)
            null
        }
    }

    // ---- 上传 ----

    private suspend fun doUpload(
        serverUri: String,
        token: String,
        audioFile: File,
        record: VoiceRecord,
        onProgress: ((String) -> Unit)?
    ): Result<UploadResult> {
        val uploadUrl = normalizeUrl(serverUri) + API_RECORDS

        // 生成业务 ID（年月日时分秒+毫秒，保证可读且唯一）
        val businessId = generateBusinessId()

        // 构建 metadata JSON（对齐 Record.CreateRequest）
        val metadata = mapOf(
            "id" to businessId,
            "title" to record.title,
            "description" to record.description,
            "inspector_name" to (record.speakers.firstOrNull() ?: "手机用户"),
            "customer_name" to "未知",
            "customer_address" to "",
            "inspection_date" to java.time.Instant.now().toString(),
            "source_type" to record.sourceType
        )
        val metadataJson = gson.toJson(metadata)

        Log.i(TAG, "uploading: audio=${audioFile.absolutePath} (${audioFile.length()} bytes), metadata=$metadataJson")

        // 确定 MIME 类型
        val mimeType = when {
            audioFile.name.lowercase().endsWith(".mp3") -> "audio/mpeg"
            audioFile.name.lowercase().endsWith(".m4a") -> "audio/mp4"
            else -> "audio/wav"
        }

        val requestBody = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("metadata", null,
                metadataJson.toRequestBody("application/json".toMediaType()))
            .addFormDataPart("audio", audioFile.name,
                audioFile.asRequestBody(mimeType.toMediaType()))
            .build()

        val request = Request.Builder()
            .url(uploadUrl)
            .header("Authorization", "Bearer $token")
            .post(requestBody)
            .build()

        onProgress?.invoke("正在上传...")

        val response = okHttpClient.newCall(request).execute()
        val responseBody = response.body?.string() ?: ""

        if (!response.isSuccessful) {
            Log.e(TAG, "upload failed: code=${response.code}, body=$responseBody")
            if (response.code == 401) {
                cachedToken = null
            }
            val errorMsg = try {
                JsonParser.parseString(responseBody).asJsonObject
                    .get("error")?.asString ?: "HTTP ${response.code}"
            } catch (_: Exception) {
                "HTTP ${response.code}"
            }
            return Result.failure(Exception("上传失败: $errorMsg"))
        }

        Log.i(TAG, "upload success: $responseBody")

        // 优先使用客户端生成的业务 ID（服务端原样返回）
        return Result.success(UploadResult(
            serverRecordId = businessId,
            message = "上传成功，服务器正在后台转写..."
        ))
    }

    // ---- 工具方法 ----

    /**
     * 生成业务 ID，格式：yyyyMMddHHmmssSSS（年月日时分秒毫秒）
     */
    private fun generateBusinessId(): String {
        val now = java.time.Instant.now()
        val formatter = java.time.format.DateTimeFormatter
            .ofPattern("yyyyMMddHHmmss")
            .withZone(java.time.ZoneId.systemDefault())
        val millis = now.toEpochMilli() % 1000
        return formatter.format(now) + millis.toString().padStart(3, '0')
    }

    /**
     * 标准化 URL：去除尾部斜杠，确保以 http:// 或 https:// 开头。
     */
    private fun normalizeUrl(uri: String): String {
        val trimmed = uri.trimEnd('/')
        return if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
            trimmed
        } else {
            "http://$trimmed"
        }
    }
}