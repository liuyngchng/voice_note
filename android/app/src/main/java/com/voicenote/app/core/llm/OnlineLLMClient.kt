package com.voicenote.app.core.llm

import com.google.gson.Gson
import com.google.gson.JsonParser
import com.voicenote.app.domain.model.RecordSummary
import com.voicenote.app.domain.model.TodoItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit
import android.util.Log

/**
 * 在线 LLM 配置
 */
data class LLMConfig(
    val apiEndpoint: String = "https://api.deepseek.com",
    val apiKey: String = "",
    val modelName: String = "deepseek-chat"
) {
    val isValid: Boolean get() = apiEndpoint.isNotBlank() && apiKey.isNotBlank()
}

/**
 * 在线 LLM 客户端 — OpenAI 兼容 API
 * 将转写文本发送给在线大模型，返回结构化的会议总结。
 */
class OnlineLLMClient(
    private val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()
) {
    private val gson = Gson()
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    /**
     * 构建完整的 API URL：如果 endpoint 不以 /chat/completions 结尾，自动追加 /v1/chat/completions
     */
    private fun buildUrl(endpoint: String): String {
        val trimmed = endpoint.trimEnd('/')
        return if (trimmed.endsWith("/chat/completions")) {
            trimmed
        } else {
            "$trimmed/v1/chat/completions"
        }
    }

    /**
     * 生成会议总结
     * @param transcript 转写全文
     * @param config LLM 配置（endpoint, key, model）
     * @return Result<RecordSummary>
     */
    suspend fun generateSummary(
        transcript: String,
        config: LLMConfig
    ): Result<RecordSummary> = withContext(Dispatchers.IO) {
        try {
            if (!config.isValid) {
                return@withContext Result.failure(IllegalArgumentException("LLM 配置不完整，请在设置中配置 API 地址和密钥"))
            }

            val systemPrompt = buildString {
                append("你是一个专业的会议记录总结助手。")
                append("请从以下会议转写文本中提取关键信息，以 JSON 格式返回。")
                append("JSON 格式要求：\n")
                append("{\n")
                append("  \"topics\": [\"议题1\", \"议题2\"],\n")
                append("  \"conclusions\": [\"结论1\", \"结论2\"],\n")
                append("  \"todos\": [{\"task\": \"待办事项\", \"owner\": \"负责人\", \"deadline\": \"截止时间\"}],\n")
                append("  \"nextSteps\": [\"后续步骤1\", \"后续步骤2\"]\n")
                append("}\n")
                append("注意：\n")
                append("1. 只返回 JSON，不要包含任何其他文字\n")
                append("2. 如果某个字段没有相关内容，返回空数组 []\n")
                append("3. todos 中的 owner 和 deadline 如果未提及则为空字符串\n")
                append("4. 请确保 JSON 格式正确，可以被直接解析")
            }

            val userPrompt = "以下是会议转写内容，请总结：\n\n$transcript"

            val requestBody = mapOf(
                "model" to config.modelName,
                "messages" to listOf(
                    mapOf("role" to "system", "content" to systemPrompt),
                    mapOf("role" to "user", "content" to userPrompt)
                ),
                "temperature" to 0.3,
                "max_tokens" to 2048
            )

            val jsonBody = gson.toJson(requestBody)
            val url = buildUrl(config.apiEndpoint)
            Log.i(TAG, "generateSummary: sending request to $url, model=${config.modelName}, transcriptLength=${transcript.length}")

            val request = Request.Builder()
                .url(url)
                .addHeader("Authorization", "Bearer ${config.apiKey}")
                .addHeader("Content-Type", "application/json")
                .post(jsonBody.toRequestBody(jsonMediaType))
                .build()

            val response = okHttpClient.newCall(request).execute()

            val responseBody = response.body?.string() ?: ""
            Log.i(TAG, "generateSummary: response code=${response.code}, bodyLength=${responseBody.length}")

            if (!response.isSuccessful) {
                val errorMsg = try {
                    val errObj = JsonParser.parseString(responseBody).asJsonObject
                    errObj.getAsJsonObject("error")?.get("message")?.asString ?: "HTTP ${response.code}"
                } catch (_: Exception) {
                    "HTTP ${response.code}: ${responseBody.take(200)}"
                }
                return@withContext Result.failure(Exception("API 请求失败: $errorMsg"))
            }

            val result = parseResponse(responseBody)
            result
        } catch (e: Exception) {
            Log.e(TAG, "generateSummary failed", e)
            Result.failure(e)
        }
    }

    /**
     * 测试 API 连接
     * @return Result 包含测试结果消息
     */
    suspend fun testConnection(config: LLMConfig): Result<String> = withContext(Dispatchers.IO) {
        try {
            if (!config.isValid) {
                return@withContext Result.failure(IllegalArgumentException("API 地址或密钥未配置"))
            }

            val requestBody = mapOf(
                "model" to config.modelName,
                "messages" to listOf(
                    mapOf("role" to "user", "content" to "你好，请回复'连接成功'")
                ),
                "max_tokens" to 20
            )

            val jsonBody = gson.toJson(requestBody)

            val url = buildUrl(config.apiEndpoint)

            val request = Request.Builder()
                .url(url)
                .addHeader("Authorization", "Bearer ${config.apiKey}")
                .addHeader("Content-Type", "application/json")
                .post(jsonBody.toRequestBody(jsonMediaType))
                .build()

            val response = okHttpClient.newCall(request).execute()

            if (response.isSuccessful) {
                val body = response.body?.string() ?: ""
                Log.i(TAG, "testConnection: success, body=$body")
                Result.success("连接成功 (${config.modelName})")
            } else {
                val body = response.body?.string() ?: ""
                Log.w(TAG, "testConnection: failed, code=${response.code}, body=$body")
                val errorMsg = try {
                    val errObj = JsonParser.parseString(body).asJsonObject
                    errObj.getAsJsonObject("error")?.get("message")?.asString ?: "HTTP ${response.code}"
                } catch (_: Exception) {
                    "HTTP ${response.code}"
                }
                Result.failure(Exception("连接失败: $errorMsg"))
            }
        } catch (e: Exception) {
            Log.e(TAG, "testConnection failed", e)
            Result.failure(e)
        }
    }

    /**
     * 解析 LLM 返回的 JSON 为 RecordSummary
     */
    private fun parseResponse(responseBody: String): Result<RecordSummary> {
        return try {
            // 提取 choices[0].message.content
            val root = JsonParser.parseString(responseBody).asJsonObject
            val choices = root.getAsJsonArray("choices")
                ?: return Result.failure(Exception("响应中没有 choices 字段"))
            if (choices.size() == 0) {
                return Result.failure(Exception("响应 choices 为空"))
            }
            val message = choices[0].asJsonObject.getAsJsonObject("message")
                ?: return Result.failure(Exception("响应中没有 message 字段"))
            val content = message.get("content")?.asString
                ?: return Result.failure(Exception("响应内容为空"))

            Log.i(TAG, "parseResponse: content length=${content.length}")

            // content 可能是纯 JSON 或包含 markdown 代码块
            val jsonStr = extractJson(content)

            val summary = gson.fromJson(jsonStr, RecordSummary::class.java)
            Log.i(TAG, "parseResponse: topics=${summary.topics.size}, conclusions=${summary.conclusions.size}, todos=${summary.todos.size}, nextSteps=${summary.nextSteps.size}")
            Result.success(summary)
        } catch (e: Exception) {
            Log.e(TAG, "parseResponse failed", e)
            Result.failure(Exception("解析总结结果失败: ${e.message}"))
        }
    }

    /**
     * 从 LLM 返回内容中提取 JSON 字符串
     * 处理可能被包裹在 ```json ... ``` 中的情况
     */
    private fun extractJson(content: String): String {
        val trimmed = content.trim()
        // 尝试匹配 ```json ... ``` 代码块
        val codeBlockRegex = Regex("```(?:json)?\\s*([\\s\\S]*?)```", RegexOption.MULTILINE)
        val match = codeBlockRegex.find(trimmed)
        if (match != null) {
            return match.groupValues[1].trim()
        }
        // 尝试匹配 { ... } 直接 JSON
        val firstBrace = trimmed.indexOf('{')
        val lastBrace = trimmed.lastIndexOf('}')
        if (firstBrace >= 0 && lastBrace > firstBrace) {
            return trimmed.substring(firstBrace, lastBrace + 1)
        }
        return trimmed
    }

    companion object {
        private const val TAG = "OnlineLLMClient"
    }
}
