package com.voicenote.app.core.asr

enum class ASRMode(val displayName: String) {
    ONLINE("在线 (FunASR)"),
    OFFLINE("离线 (SenseVoice)");

    companion object {
        fun fromString(value: String): ASRMode = when (value.lowercase()) {
            "offline" -> OFFLINE
            else -> ONLINE
        }
    }
}
