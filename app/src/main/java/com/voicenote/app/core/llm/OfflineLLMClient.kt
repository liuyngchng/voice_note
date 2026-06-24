package com.voicenote.app.core.llm

import android.app.ActivityManager
import android.content.Context
import android.util.Log
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.voicenote.app.core.common.MemoryWarningBus
import com.voicenote.app.domain.model.TodoItem
import com.voicenote.app.domain.model.VoiceRecordSummary
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OfflineLLMClient @Inject constructor(
    @ApplicationContext private val context: Context,
    private val modelManager: LLMModelManager
) {
    private val scope = CoroutineScope(Dispatchers.IO)
    private val stateLock = Mutex()
    private var isInitialized = false
    private var currentModelInfo: LLMModelInfo? = null
    private var isInferring = false
    private var shouldReleaseAfterInference = false

    init {
        scope.launch {
            MemoryWarningBus.events.collect { level ->
                handleMemoryWarning(level)
            }
        }
    }

    fun ensureModel(modelInfo: LLMModelInfo) {
        if (isInitialized && currentModelInfo == modelInfo) return
        if (isInitialized) reset()

        val modelPath = modelManager.modelFilePath(modelInfo)
        val modelFile = File(modelPath)
        check(modelFile.exists()) { "离线 LLM 模型未下载 (${modelInfo.displayName})，请先在设置中下载" }

        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memInfo = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memInfo)
        val totalMemMB = memInfo.totalMem / (1024 * 1024)
        val isLowMemory = totalMemMB < 3 * 1024  // < 3GB
        val gpuLayers = if (isLowMemory) 0 else 99
        val ctxLen = 2048

        if (isLowMemory) {
            Log.i(TAG, "低内存设备 (${totalMemMB}MB)，使用 CPU-only 推理")
        }

        if (!LlamaBridge.isAvailable()) {
            throw IllegalStateException("llama.cpp native library not available")
        }

        val success = LlamaBridge.loadModel(modelPath, gpuLayers, ctxLen)
        check(success) { "模型加载失败: $modelPath" }

        isInitialized = true
        currentModelInfo = modelInfo
        Log.i(TAG, "离线 LLM 模型就绪: ${modelInfo.name}, gpuLayers=$gpuLayers")
    }

    suspend fun generateSummary(
        transcript: String,
        modelInfo: LLMModelInfo,
        customPrompt: String? = null
    ): Result<VoiceRecordSummary> = withContext(Dispatchers.IO) {
        try {
            ensureModel(modelInfo)
        } catch (e: Exception) {
            return@withContext Result.failure(e)
        }

        stateLock.withLock { isInferring = true }

        return@withContext try {
            val prompt = customPrompt?.takeIf { it.isNotBlank() } ?: DEFAULT_PROMPT
            val systemPrompt = "你是一个语音笔记助手，负责用简洁的文字总结转写文本。"

            val rawOutput = LlamaBridge.generate(
                "$prompt\n\n$transcript",
                systemPrompt,
                512,
                0.3f
            )

            if (rawOutput.isNullOrBlank()) {
                Result.failure(Exception("离线 LLM 返回空结果"))
            } else {
                Log.i(TAG, "离线推理完成: ${rawOutput.length} chars")
                val summary = parseSummary(rawOutput)
                Result.success(summary)
            }
        } catch (e: Exception) {
            Log.e(TAG, "离线推理失败: ${e.message}", e)
            Result.failure(e)
        } finally {
            stateLock.withLock {
                isInferring = false
                shouldReleaseAfterInference = false
                // Always release model after inference to free memory
                Log.i(TAG, "推理完成，释放 LLM 模型")
                reset()
            }
        }
    }

    private fun parseSummary(text: String): VoiceRecordSummary {
        return try {
            val json = Gson().fromJson(text.trim(), JsonObject::class.java)
            val topics = json.getAsJsonArray("topics")?.map { it.asString } ?: emptyList()
            val conclusions = json.getAsJsonArray("conclusions")?.map { it.asString } ?: emptyList()
            val todos = json.getAsJsonArray("todos")?.map { item ->
                val obj = item.asJsonObject
                TodoItem(
                    task = obj.get("task")?.asString ?: "",
                    owner = obj.get("owner")?.asString ?: "",
                    deadline = obj.get("deadline")?.asString ?: ""
                )
            } ?: emptyList()
            val nextSteps = json.get("next_steps")?.asString ?: ""

            if (topics.isEmpty() && conclusions.isEmpty()) {
                VoiceRecordSummary(conclusions = listOf(text.trim()), nextSteps = "")
            } else {
                VoiceRecordSummary(topics, conclusions, todos, nextSteps)
            }
        } catch (_: Exception) {
            VoiceRecordSummary(conclusions = listOf(text.trim()), nextSteps = "")
        }
    }

    fun reset() {
        if (isInitialized) {
            LlamaBridge.unloadModel()
            isInitialized = false
            currentModelInfo = null
            Log.i(TAG, "离线 LLM 模型已释放")
        }
    }

    val isAvailable: Boolean get() = isInitialized

    private fun handleMemoryWarning(level: Int) {
        scope.launch {
            stateLock.withLock {
                if (isInferring) {
                    shouldReleaseAfterInference = true
                    Log.i(TAG, "收到内存警告 level=$level，推理进行中 — 将在完成后释放模型")
                } else {
                    Log.i(TAG, "收到内存警告 level=$level，释放 LLM 模型")
                    reset()
                }
            }
        }
    }

    companion object {
        private const val TAG = "OfflineLLMClient"

        private val DEFAULT_PROMPT = """
你是一个语音笔记整理助手。请用一段简洁的文字总结以下转写文本，提取关键信息：

总结应包含：
- 讨论的主要议题
- 得出的结论或决定
- 待办事项和负责人（如有）

以 JSON 格式返回：
{
  "topics": ["议题1", "议题2"],
  "conclusions": ["结论1", "结论2"],
  "todos": [{"task": "待办", "owner": "负责人", "deadline": "截止时间"}],
  "next_steps": "下一步计划"
}

转写文本：
""".trimIndent()
    }
}
