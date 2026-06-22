package com.voicenote.app.core.llm

enum class LLMMode(val displayName: String) {
    ONLINE("在线 (API)"),
    OFFLINE("离线 (本地模型)");

    companion object {
        fun fromString(value: String): LLMMode = when (value.lowercase()) {
            "offline" -> OFFLINE
            else -> ONLINE
        }
    }
}
