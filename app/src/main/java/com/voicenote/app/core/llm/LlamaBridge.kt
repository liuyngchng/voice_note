package com.voicenote.app.core.llm

import android.util.Log

object LlamaBridge {
    private const val TAG = "LlamaBridge"
    private var nativeLoaded = false

    init {
        try {
            System.loadLibrary("llama_jni")
            nativeLoaded = true
        } catch (_: UnsatisfiedLinkError) {
            nativeLoaded = false
        }
    }

    fun isAvailable(): Boolean = nativeLoaded

    external fun loadModel(path: String, gpuLayers: Int, contextLength: Int): Boolean

    fun generate(prompt: String, systemPrompt: String?, maxTokens: Int, temperature: Float): String? {
        Log.i(TAG, "开始推理: promptLen=${prompt.length}, maxTokens=$maxTokens, temperature=$temperature")
        val startMs = System.currentTimeMillis()
        val result = generateNative(prompt, systemPrompt, maxTokens, temperature)
        val elapsed = System.currentTimeMillis() - startMs
        if (result != null) {
            Log.i(TAG, "推理完成: ${result.length} chars, ${elapsed}ms")
        } else {
            Log.e(TAG, "推理失败: 返回 null, ${elapsed}ms")
        }
        return result
    }

    @JvmStatic private external fun generateNative(prompt: String, systemPrompt: String?, maxTokens: Int, temperature: Float): String?

    external fun unloadModel()
    external fun isLoaded(): Boolean
}
