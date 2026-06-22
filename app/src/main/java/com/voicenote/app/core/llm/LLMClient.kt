package com.voicenote.app.core.llm

import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.voicenote.app.domain.model.TodoItem
import com.voicenote.app.domain.model.VoiceRecordSummary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LLMClient @Inject constructor() {

    private val gson = Gson()
    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    companion object {
        private const val MAX_CHUNK_CHARS = 6000
        private const val CHUNK_OVERLAP = 300
    }

    suspend fun generateSummary(
        transcript: String,
        apiUrl: String,
        apiKey: String,
        model: String = "gpt-4o-mini",
        customPrompt: String? = null
    ): Result<VoiceRecordSummary> = withContext(Dispatchers.IO) {
        try {
            val fullUrl = if (apiUrl.contains("/chat/completions")) apiUrl
                else "${apiUrl.trimEnd('/')}/v1/chat/completions"

            if (transcript.length > MAX_CHUNK_CHARS) {
                return@withContext generateChunkedSummary(fullUrl, apiKey, model, customPrompt, transcript)
            }

            val systemPrompt = customPrompt ?: buildDefaultPrompt()
            val userContent = "以下是录音的对话转写文本，请提取结构化信息：\n\n$transcript"
            val result = callLlm(fullUrl, apiKey, model, systemPrompt, userContent)
            if (result.isFailure) return@withContext Result.failure(result.exceptionOrNull()!!)
            Result.success(parseResponse(result.getOrThrow()))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private suspend fun callLlm(
        fullUrl: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userContent: String
    ): Result<String> = withContext(Dispatchers.IO) {
        try {
            val messages = JsonArray().apply {
                add(JsonObject().apply {
                    addProperty("role", "system")
                    addProperty("content", systemPrompt)
                })
                add(JsonObject().apply {
                    addProperty("role", "user")
                    addProperty("content", userContent)
                })
            }

            val body = JsonObject().apply {
                addProperty("model", model)
                add("messages", messages)
                addProperty("temperature", 0.3)
                add("response_format", JsonObject().apply {
                    addProperty("type", "json_object")
                })
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

            if (!response.isSuccessful) {
                return@withContext Result.failure(Exception("LLM API error: ${response.code} $responseBody"))
            }

            val root = gson.fromJson(responseBody, JsonObject::class.java)
            val content = root
                .getAsJsonArray("choices")
                ?.get(0)?.asJsonObject
                ?.getAsJsonObject("message")
                ?.get("content")?.asString ?: "{}"

            Result.success(content)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun chunkText(text: String): List<String> {
        val chunks = mutableListOf<String>()
        var start = 0
        while (start < text.length) {
            val end = minOf(start + MAX_CHUNK_CHARS, text.length)
            chunks.add(text.substring(start, end))
            start = end - CHUNK_OVERLAP
        }
        return chunks
    }

    private suspend fun generateChunkedSummary(
        fullUrl: String,
        apiKey: String,
        model: String,
        customPrompt: String?,
        transcript: String
    ): Result<VoiceRecordSummary> {
        val chunks = chunkText(transcript)

        // Step 1: summarize each chunk
        val chunkSummaries = mutableListOf<String>()
        for ((i, chunk) in chunks.withIndex()) {
            val systemPrompt = "你是一个专业的语音笔记助理。请简洁概括以下对话片段的要点。"
            val userContent = "以下是录音对话转写的第${i + 1}/${chunks.size}段，请用中文总结本段的关键信息（议题、结论、待办事项等）：\n\n$chunk"

            val result = callLlm(fullUrl, apiKey, model, systemPrompt, userContent)
            if (result.isFailure) return Result.failure(result.exceptionOrNull()!!)
            chunkSummaries.add(result.getOrThrow())
        }

        // Step 2: merge all chunk summaries into final structured result
        val systemPrompt = customPrompt ?: buildDefaultPrompt()
        val mergeContent = buildString {
            appendLine("以下是录音对话各段落的摘要（共${chunks.size}段），请根据这些摘要提取完整的结构化信息：")
            chunkSummaries.forEachIndexed { i, s ->
                appendLine()
                appendLine("【第${i + 1}段摘要】")
                appendLine(s)
            }
        }

        val result = callLlm(fullUrl, apiKey, model, systemPrompt, mergeContent)
        if (result.isFailure) return Result.failure(result.exceptionOrNull()!!)

        return Result.success(parseResponse(result.getOrThrow()))
    }

    private fun parseResponse(content: String): VoiceRecordSummary {
        val contentObj = try {
            gson.fromJson(content, JsonObject::class.java)
        } catch (_: Exception) {
            JsonObject()
        }

        val topics = contentObj.getAsJsonArray("topics")?.map { it.asString } ?: emptyList()
        val conclusions = contentObj.getAsJsonArray("conclusions")?.map { it.asString } ?: emptyList()
        val todos = contentObj.getAsJsonArray("todos")?.map { item ->
            val obj = item.asJsonObject
            TodoItem(
                task = obj.get("task")?.asString ?: "",
                owner = obj.get("owner")?.asString ?: "",
                deadline = obj.get("deadline")?.asString ?: ""
            )
        } ?: emptyList()
        val nextSteps = contentObj.get("next_steps")?.asString ?: ""

        return VoiceRecordSummary(topics, conclusions, todos, nextSteps)
    }

    private fun buildDefaultPrompt(): String = """
你是一个专业的语音笔记助理。请根据录音对话内容，提取以下结构化信息，以 JSON 格式返回：

{
  "topics": ["会谈议题1", "会谈议题2"],
  "conclusions": ["结论1", "结论2"],
  "todos": [
    {"task": "待办事项描述", "owner": "负责人", "deadline": "截止时间"}
  ],
  "next_steps": "下一步跟进计划描述"
}

要求：
1. topics: 列出本次会谈讨论的主要议题，每条简洁概括
2. conclusions: 列出达成的关键结论或共识
3. todos: 提取所有待办事项，包括任务内容、负责人和截止时间（如有提及）
4. next_steps: 总结下一步跟进计划

如果某个字段没有相关信息，返回空数组或空字符串。
""".trimIndent()
}
