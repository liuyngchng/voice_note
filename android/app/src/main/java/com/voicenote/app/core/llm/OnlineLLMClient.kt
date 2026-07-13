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
 * 长文本自动分段：分块摘要 → 汇总合并。
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

    companion object {
        private const val TAG = "OnlineLLMClient"

        /** 单块最大字符数（约 2000-3000 中文 token），超过则启用分段 */
        private const val MAX_CHUNK_CHARS = 8000
    }

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

    // ---- 公开接口 ----

    /**
     * 生成会议总结（自动判断是否需要分段）
     *
     * @param transcript 转写全文
     * @param config     LLM 配置
     * @param onProgress 进度回调（主线程），参数为中文进度描述
     * @return Result<RecordSummary>
     */
    suspend fun generateSummary(
        transcript: String,
        config: LLMConfig,
        onProgress: ((String) -> Unit)? = null
    ): Result<RecordSummary> = withContext(Dispatchers.IO) {
        try {
            if (!config.isValid) {
                return@withContext Result.failure(IllegalArgumentException("LLM 配置不完整，请在设置中配置 API 地址和密钥"))
            }

            if (transcript.length <= MAX_CHUNK_CHARS) {
                // 短文本：单次推理
                onProgress?.invoke("正在请求 AI 总结...")
                singlePassSummary(transcript, config)
            } else {
                // 长文本：分段 → 逐块摘要 → 汇总
                multiPassSummary(transcript, config, onProgress)
            }
        } catch (e: Exception) {
            Log.e(TAG, "generateSummary failed", e)
            Result.failure(e)
        }
    }

    /**
     * 测试 API 连接
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

            val response = callAPI(config, requestBody)

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

    // ---- 单次推理 ----

    private suspend fun singlePassSummary(
        transcript: String,
        config: LLMConfig
    ): Result<RecordSummary> {
        val systemPrompt = buildSummarySystemPrompt()
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

        Log.i(TAG, "singlePassSummary: transcriptLength=${transcript.length}")

        val response = callAPI(config, requestBody)
        return parseSummaryResponse(response)
    }

    // ---- 多轮分段 ----

    private suspend fun multiPassSummary(
        transcript: String,
        config: LLMConfig,
        onProgress: ((String) -> Unit)?
    ): Result<RecordSummary> {
        // 1. 分块
        val chunks = splitText(transcript, MAX_CHUNK_CHARS)
        val total = chunks.size
        Log.i(TAG, "multiPassSummary: ${transcript.length} chars → $total chunks (max=$MAX_CHUNK_CHARS)")

        // 2. 逐块摘要
        val chunkSummaries = mutableListOf<String>()
        for ((i, chunk) in chunks.withIndex()) {
            val current = i + 1
            onProgress?.invoke("正在分析片段 ($current/$total)...")

            val chunkPrompt = "用一两句话提取以下文本的关键信息，不要遗漏重要事项和决定：\n\n$chunk"

            val requestBody = mapOf(
                "model" to config.modelName,
                "messages" to listOf(
                    mapOf("role" to "user", "content" to chunkPrompt)
                ),
                "temperature" to 0.3,
                "max_tokens" to 256
            )

            try {
                val response = callAPI(config, requestBody)
                val text = extractTextContent(response)
                val trimmed = text.trim()
                if (trimmed.isNotBlank()) {
                    chunkSummaries.add(trimmed)
                    Log.i(TAG, "chunk $current/$total summary: ${trimmed.length} chars")
                }
            } catch (e: Exception) {
                Log.w(TAG, "chunk $current/$total failed, skipping: ${e.message}")
                // 跳过失败的块，继续处理其他块
            }
        }

        if (chunkSummaries.isEmpty()) {
            return Result.failure(Exception("所有分段摘要均失败"))
        }

        Log.i(TAG, "chunk summaries collected: ${chunkSummaries.size}/$total")

        // 3. 合并摘要
        onProgress?.invoke("正在整合摘要...")

        val mergedText: String
        if (chunkSummaries.size == 1) {
            mergedText = chunkSummaries[0]
        } else {
            val summariesText = chunkSummaries.mapIndexed { i, s ->
                "【片段 ${i + 1}】$s"
            }.joinToString("\n\n")

            val systemPrompt = buildSummarySystemPrompt()
            val mergePrompt = "以下是从长文本中提取的分段摘要，请整合为一个连贯的总结：\n\n$summariesText"

            val requestBody = mapOf(
                "model" to config.modelName,
                "messages" to listOf(
                    mapOf("role" to "system", "content" to systemPrompt),
                    mapOf("role" to "user", "content" to mergePrompt)
                ),
                "temperature" to 0.3,
                "max_tokens" to 2048
            )

            val response = callAPI(config, requestBody)
            mergedText = extractTextContent(response)
        }

        // 4. 解析合并后的 JSON
        return parseJsonContent(mergedText)
    }

    // ---- API 调用 ----

    private fun callAPI(config: LLMConfig, requestBody: Map<String, Any?>): okhttp3.Response {
        val jsonBody = gson.toJson(requestBody)
        val url = buildUrl(config.apiEndpoint)

        val request = Request.Builder()
            .url(url)
            .addHeader("Authorization", "Bearer ${config.apiKey}")
            .addHeader("Content-Type", "application/json")
            .post(jsonBody.toRequestBody(jsonMediaType))
            .build()

        val response = okHttpClient.newCall(request).execute()

        if (!response.isSuccessful) {
            val responseBody = response.body?.string() ?: ""
            Log.w(TAG, "API error: code=${response.code}, body=${responseBody.take(300)}")
            val errorMsg = try {
                val errObj = JsonParser.parseString(responseBody).asJsonObject
                errObj.getAsJsonObject("error")?.get("message")?.asString ?: "HTTP ${response.code}"
            } catch (_: Exception) {
                "HTTP ${response.code}: ${responseBody.take(200)}"
            }
            throw Exception("API 请求失败: $errorMsg")
        }

        return response
    }

    /** 从 API 响应中提取文本内容 */
    private fun extractTextContent(response: okhttp3.Response): String {
        val body = response.body?.string() ?: ""
        val root = JsonParser.parseString(body).asJsonObject
        val choices = root.getAsJsonArray("choices")
            ?: throw Exception("响应中没有 choices 字段")
        if (choices.size() == 0) throw Exception("响应 choices 为空")
        val message = choices[0].asJsonObject.getAsJsonObject("message")
            ?: throw Exception("响应中没有 message 字段")
        return message.get("content")?.asString ?: throw Exception("响应内容为空")
    }

    /** 解析 summary API 响应为 RecordSummary */
    private fun parseSummaryResponse(response: okhttp3.Response): Result<RecordSummary> {
        return try {
            val content = extractTextContent(response)
            parseJsonContent(content)
        } catch (e: Exception) {
            Log.e(TAG, "parseSummaryResponse failed", e)
            Result.failure(Exception("解析总结结果失败: ${e.message}"))
        }
    }

    /** 解析文本内容中的 JSON 为 RecordSummary */
    private fun parseJsonContent(content: String): Result<RecordSummary> {
        return try {
            Log.i(TAG, "parseJsonContent: content length=${content.length}")
            val jsonStr = extractJson(content)
            val summary = gson.fromJson(jsonStr, RecordSummary::class.java)
            Log.i(TAG, "parsed: topics=${summary.topics.size}, conclusions=${summary.conclusions.size}, todos=${summary.todos.size}, nextSteps=${summary.nextSteps.size}")
            Result.success(summary)
        } catch (e: Exception) {
            Log.e(TAG, "parseJsonContent failed", e)
            Result.failure(Exception("解析总结结果失败: ${e.message}"))
        }
    }

    // ---- 文本分块 ----

    /**
     * 将文本按句子边界分块，每块不超过 maxChars
     */
    private fun splitText(text: String, maxChars: Int): List<String> {
        if (text.length <= maxChars) return listOf(text)

        val chunks = mutableListOf<String>()
        val sentences = splitBySentences(text)
        var currentChunk = StringBuilder()

        for (sentence in sentences) {
            // 单个句子超过上限，硬截断
            if (sentence.length > maxChars) {
                // 先保存当前累积的块
                if (currentChunk.isNotEmpty()) {
                    chunks.add(currentChunk.toString().trim())
                    currentChunk = StringBuilder()
                }
                // 硬截断长句子
                var remaining = sentence
                while (remaining.length > maxChars) {
                    chunks.add(remaining.take(maxChars).trim())
                    remaining = remaining.drop(maxChars)
                }
                if (remaining.isNotEmpty()) {
                    currentChunk.append(remaining)
                }
                continue
            }

            // 加入当前句后会超出上限，先保存当前块
            if (currentChunk.length + sentence.length > maxChars) {
                if (currentChunk.isNotEmpty()) {
                    chunks.add(currentChunk.toString().trim())
                    currentChunk = StringBuilder()
                }
            }

            currentChunk.append(sentence)
        }

        // 最后一块
        if (currentChunk.isNotEmpty()) {
            chunks.add(currentChunk.toString().trim())
        }

        return chunks.ifEmpty { listOf(text) }
    }

    /**
     * 按句子边界分割文本
     */
    private fun splitBySentences(text: String): List<String> {
        // 在常见标点后分割，保留标点附在前一句末尾
        val regex = Regex("""[。！？!?\n]+""")
        val parts = regex.split(text)
        val delimiters = regex.findAll(text).map { it.value }.toList()

        val sentences = mutableListOf<String>()
        for ((i, part) in parts.withIndex()) {
            val trimmed = part.trim()
            if (trimmed.isEmpty() && i < delimiters.size) {
                // 空段落单独作为分隔保留
                sentences.add(delimiters[i])
                continue
            }
            val delimiter = if (i < delimiters.size) delimiters[i] else ""
            if (trimmed.isNotEmpty()) {
                sentences.add(trimmed + delimiter)
            }
        }
        return sentences
    }

    // ---- JSON 提取 + Prompt ----

    private fun buildSummarySystemPrompt(): String = buildString {
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
}
