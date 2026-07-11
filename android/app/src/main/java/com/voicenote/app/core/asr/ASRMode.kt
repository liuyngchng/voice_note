package com.voicenote.app.core.asr

enum class ASRMode(val displayName: String) {
    OFFLINE("离线 (SenseVoice)");

    companion object {
        fun fromString(value: String): ASRMode = OFFLINE
    }
}
