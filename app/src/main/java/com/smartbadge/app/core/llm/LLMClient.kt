package com.smartbadge.app.core.llm

import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.smartbadge.app.domain.model.TodoItem
import com.smartbadge.app.domain.model.VisitSummary
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

    suspend fun generateSummary(
        transcript: String,
        apiUrl: String,
        apiKey: String,
        model: String = "gpt-4o-mini",
        customPrompt: String? = null
    ): Result<VisitSummary> = withContext(Dispatchers.IO) {
        try {
            val systemPrompt = customPrompt ?: buildDefaultPrompt()

            val messages = JsonArray().apply {
                add(JsonObject().apply {
                    addProperty("role", "system")
                    addProperty("content", systemPrompt)
                })
                add(JsonObject().apply {
                    addProperty("role", "user")
                    addProperty("content", "以下是客户拜访的对话转写文本，请提取结构化信息：\n\n$transcript")
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
                .url(apiUrl)
                .addHeader("Authorization", "Bearer $apiKey")
                .post(requestBody)
                .build()

            val response = client.newCall(request).execute()
            val responseBody = response.body?.string() ?: ""
            response.close()

            if (!response.isSuccessful) {
                return@withContext Result.failure(Exception("LLM API error: ${response.code} $responseBody"))
            }

            val parsed = parseResponse(responseBody)
            Result.success(parsed)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun parseResponse(responseBody: String): VisitSummary {
        val root = gson.fromJson(responseBody, JsonObject::class.java)
        val content = root
            .getAsJsonArray("choices")
            ?.get(0)?.asJsonObject
            ?.getAsJsonObject("message")
            ?.get("content")?.asString ?: "{}"

        val contentObj = gson.fromJson(content, JsonObject::class.java)

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

        return VisitSummary(topics, conclusions, todos, nextSteps)
    }

    private fun buildDefaultPrompt(): String = """
你是一个专业的商务会议助理。请根据客户拜访对话内容，提取以下结构化信息，以 JSON 格式返回：

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
