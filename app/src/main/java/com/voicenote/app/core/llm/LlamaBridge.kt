package com.voicenote.app.core.llm

object LlamaBridge {
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
    external fun generate(prompt: String, systemPrompt: String?, maxTokens: Int, temperature: Float): String?
    external fun unloadModel()
    external fun isLoaded(): Boolean
}
