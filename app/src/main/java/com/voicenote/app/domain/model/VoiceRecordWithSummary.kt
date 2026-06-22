package com.voicenote.app.domain.model

data class VoiceRecordWithSummary(
    val record: VoiceRecord,
    val summary: VoiceRecordSummary?
)
