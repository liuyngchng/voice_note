package com.voicenote.app.core.llm

enum class LLMModelInfo(
    val displayName: String,
    val estimatedSizeMB: Int,
    val modelFilename: String,
    val modelscopeDownloadURL: String?,
    val modelscopePageURL: String?
) {
    QWEN2_5_1_5B(
        displayName = "Qwen2.5-1.5B (~986MB)",
        estimatedSizeMB = 986,
        modelFilename = "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        modelscopeDownloadURL = "https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf",
        modelscopePageURL = "https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF"
    ),
    QWEN2_5_0_5B(
        displayName = "Qwen2.5-0.5B (~352MB)",
        estimatedSizeMB = 352,
        modelFilename = "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        modelscopeDownloadURL = "https://modelscope.cn/models/qwen/Qwen2.5-0.5B-Instruct-gguf/resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf",
        modelscopePageURL = "https://modelscope.cn/models/qwen/Qwen2.5-0.5B-Instruct-gguf"
    ),
    CUSTOM(
        displayName = "自定义模型",
        estimatedSizeMB = 500,
        modelFilename = "custom.gguf",
        modelscopeDownloadURL = null,
        modelscopePageURL = null
    );

    companion object {
        fun fromString(value: String): LLMModelInfo = when (value.lowercase()) {
            "qwen2_5_0_5b_q4km" -> QWEN2_5_0_5B
            "custom" -> CUSTOM
            else -> QWEN2_5_1_5B
        }
    }
}
