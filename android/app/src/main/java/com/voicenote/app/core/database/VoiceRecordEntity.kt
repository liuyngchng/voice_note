package com.voicenote.app.core.database

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.voicenote.app.domain.model.VoiceRecord

@Entity(tableName = "voice_records")
data class VoiceRecordEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val title: String,
    val memo: String,
    val description: String,
    val speakersJson: String,
    val sourceType: String = "RECORDING",
    val startTime: Long,
    val endTime: Long?,
    val audioFilePath: String,
    val transcriptFilePath: String = "",
    val transcriptStatus: String = "PENDING",
    val createdAt: Long,
    // AI 总结（在线 LLM）
    val summaryJson: String = "",
    val summaryStatus: String = "PENDING",
    val summaryGeneratedAt: Long? = null,
    // 服务器上传记录 ID（非空表示已上传到服务器）
    val serverRecordId: String = ""
) {
    companion object {
        private val gson = Gson()

        fun fromDomain(record: VoiceRecord): VoiceRecordEntity = VoiceRecordEntity(
            id = record.id,
            title = record.title,
            memo = record.memo,
            description = record.description,
            speakersJson = gson.toJson(record.speakers),
            sourceType = record.sourceType,
            startTime = record.startTime.toEpochMilli(),
            endTime = record.endTime?.toEpochMilli(),
            audioFilePath = record.audioFilePath,
            transcriptFilePath = record.transcriptFilePath,
            transcriptStatus = record.transcriptStatus.name,
            createdAt = record.createdAt.toEpochMilli(),
            summaryJson = record.summary?.let { gson.toJson(it) } ?: "",
            summaryStatus = record.summaryStatus.name,
            summaryGeneratedAt = record.summaryGeneratedAt?.toEpochMilli(),
            serverRecordId = record.serverRecordId
        )
    }

    fun toDomain(): VoiceRecord {
        val speakers: List<String> = try {
            gson.fromJson(speakersJson, object : TypeToken<List<String>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val summary: com.voicenote.app.domain.model.RecordSummary? = try {
            if (summaryJson.isNotBlank()) gson.fromJson(summaryJson, com.voicenote.app.domain.model.RecordSummary::class.java)
            else null
        } catch (_: Exception) { null }

        return VoiceRecord(
            id = id,
            title = title,
            memo = memo,
            description = description,
            speakers = speakers,
            sourceType = sourceType,
            startTime = java.time.Instant.ofEpochMilli(startTime),
            endTime = endTime?.let { java.time.Instant.ofEpochMilli(it) },
            transcriptStatus = try { com.voicenote.app.domain.model.ProcessingStatus.valueOf(transcriptStatus) } catch (_: Exception) { com.voicenote.app.domain.model.ProcessingStatus.PENDING },
            audioFilePath = audioFilePath,
            transcriptFilePath = transcriptFilePath,
            createdAt = java.time.Instant.ofEpochMilli(createdAt),
            summaryStatus = try { com.voicenote.app.domain.model.ProcessingStatus.valueOf(summaryStatus) } catch (_: Exception) { com.voicenote.app.domain.model.ProcessingStatus.PENDING },
            summary = summary,
            summaryGeneratedAt = summaryGeneratedAt?.let { java.time.Instant.ofEpochMilli(it) },
            serverRecordId = serverRecordId
        )
    }
}
