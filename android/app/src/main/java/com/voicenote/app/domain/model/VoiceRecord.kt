package com.voicenote.app.domain.model

import java.time.Instant

enum class ProcessingStatus {
    PENDING,
    PROCESSING,
    COMPLETED,
    UNAVAILABLE
}

data class VoiceRecord(
    val id: Long = 0,
    val title: String,
    val memo: String = "",
    val description: String,
    val speakers: List<String> = emptyList(),
    val sourceType: String = "RECORDING",
    val startTime: Instant = Instant.now(),
    val endTime: Instant? = null,
    val transcriptStatus: ProcessingStatus = ProcessingStatus.PENDING,
    val audioFilePath: String = "",
    val transcriptFilePath: String = "",
    val createdAt: Instant = Instant.now()
)
