package com.voicenote.app.core.network

import com.google.gson.Gson
import com.google.gson.JsonObject
import com.voicenote.app.core.asr.ASRModelManager
import com.voicenote.app.core.asr.ModelQuality
import com.voicenote.app.core.llm.LLMModelInfo
import com.voicenote.app.core.llm.LLMModelManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ConnectivityChecker @Inject constructor(
    private val asrModelManager: ASRModelManager,
    private val llmModelManager: LLMModelManager
) {

    private val gson = Gson()

    suspend fun checkAsrConnection(url: String): Result<String> = withContext(Dispatchers.IO) {
        if (url.isBlank()) return@withContext Result.failure(Exception("ASR 地址不能为空"))

        val client = OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()

        val resultChannel = Channel<String>(Channel.CONFLATED)

        val request = Request.Builder().url(url).build()
        client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                // Immediately close after connected
                webSocket.close(1000, "connectivity test")
                client.dispatcher.executorService.shutdown()
                resultChannel.trySend("ok")
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                client.dispatcher.executorService.shutdown()
                val msg = if (response != null) {
                    "HTTP ${response.code}: ${response.message}"
                } else {
                    t.message ?: "连接失败"
                }
                resultChannel.trySend("fail:$msg")
            }
        })

        val result = resultChannel.receive()
        if (result == "ok") {
            Result.success("WebSocket 连接成功")
        } else {
            Result.failure(Exception(result.removePrefix("fail:")))
        }
    }

    suspend fun checkLlmConnection(
        url: String,
        apiKey: String,
        model: String
    ): Result<String> = withContext(Dispatchers.IO) {
        if (url.isBlank()) return@withContext Result.failure(Exception("API 地址不能为空"))
        if (apiKey.isBlank()) return@withContext Result.failure(Exception("API Key 不能为空"))

        val fullUrl = if (url.contains("/chat/completions")) url
            else "${url.trimEnd('/')}/v1/chat/completions"

        val client = OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .writeTimeout(5, TimeUnit.SECONDS)
            .build()

        try {
            val body = JsonObject().apply {
                addProperty("model", model)
                val messages = JsonObject().apply {
                    addProperty("role", "user")
                    addProperty("content", "test")
                }
                add("messages", com.google.gson.JsonArray().apply { add(messages) })
                addProperty("max_tokens", 1)
            }

            val requestBody = gson.toJson(body).toRequestBody("application/json".toMediaType())
            val request = Request.Builder()
                .url(fullUrl)
                .addHeader("Authorization", "Bearer $apiKey")
                .post(requestBody)
                .build()

            val response = client.newCall(request).execute()
            val responseBody = response.body?.string() ?: ""
            response.close()
            client.dispatcher.executorService.shutdown()

            if (response.isSuccessful) {
                Result.success("API 连接成功（HTTP ${response.code}）")
            } else {
                Result.failure(Exception("HTTP ${response.code}: ${responseBody.take(100)}"))
            }
        } catch (e: Exception) {
            client.dispatcher.executorService.shutdown()
            Result.failure(Exception(e.message ?: "请求失败"))
        }
    }

    fun checkAsrOffline(quality: String): Result<String> {
        val q = if (quality == "fp32") ModelQuality.FP32 else ModelQuality.INT8
        val modelFile = File(asrModelManager.modelFilePath(q))
        val tokensFile = File(asrModelManager.tokensFilePath())

        return when {
            !modelFile.exists() || modelFile.length() < 1_000_000 ->
                Result.failure(Exception("离线 ASR 模型未下载 (${q.displayName})，请先下载"))
            !tokensFile.exists() ->
                Result.failure(Exception("tokens.txt 未找到，请重新下载模型"))
            else ->
                Result.success("离线 ASR 模型就绪 (${q.displayName}, ${modelFile.length() / 1_048_576}MB)")
        }
    }

    fun checkLlmOffline(modelInfo: String): Result<String> {
        val info = LLMModelInfo.fromString(modelInfo)
        val modelFile = File(llmModelManager.modelFilePath(info))

        return when {
            !modelFile.exists() ->
                Result.failure(Exception("离线 LLM 模型未下载 (${info.displayName})，请先下载"))
            modelFile.length() < 10_000_000 ->
                Result.failure(Exception("离线 LLM 模型文件过小，可能无效"))
            else ->
                Result.success("离线 LLM 模型就绪 (${info.displayName}, ${modelFile.length() / 1_048_576}MB)")
        }
    }
}