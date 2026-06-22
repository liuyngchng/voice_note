package com.voicenote.app.core.database

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.voicenote.app.domain.model.TodoItem
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.model.VoiceRecordSummary

@Entity(tableName = "voice_records")
data class VoiceRecordEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val title: String,
    val memo: String,
    val description: String,
    val speakersJson: String,           // JSON array of strings
    val sourceType: String = "RECORDING",
    val startTime: Long,                // epoch millis
    val endTime: Long?,                 // epoch millis
    val transcriptText: String,
    val topicsJson: String,             // JSON array of strings
    val conclusionsJson: String,        // JSON array of strings
    val todosJson: String,              // JSON array of TodoItem
    val nextSteps: String,
    val audioFilePath: String,
    val transcriptFilePath: String = "",
    val transcriptStatus: String = "PENDING",
    val summaryStatus: String = "PENDING",
    val createdAt: Long                 // epoch millis
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
            transcriptText = record.transcriptText,
            topicsJson = gson.toJson(record.summary?.topics ?: emptyList<String>()),
            conclusionsJson = gson.toJson(record.summary?.conclusions ?: emptyList<String>()),
            todosJson = gson.toJson(record.summary?.todos ?: emptyList<TodoItem>()),
            nextSteps = record.summary?.nextSteps ?: "",
            audioFilePath = record.audioFilePath,
            transcriptFilePath = record.transcriptFilePath,
            transcriptStatus = record.transcriptStatus.name,
            summaryStatus = record.summaryStatus.name,
            createdAt = record.createdAt.toEpochMilli()
        )
    }

    fun toDomain(): VoiceRecord {
        val topics: List<String> = try {
            gson.fromJson(topicsJson, object : TypeToken<List<String>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val conclusions: List<String> = try {
            gson.fromJson(conclusionsJson, object : TypeToken<List<String>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val todos: List<TodoItem> = try {
            gson.fromJson(todosJson, object : TypeToken<List<TodoItem>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val speakers: List<String> = try {
            gson.fromJson(speakersJson, object : TypeToken<List<String>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val hasSummary = topics.isNotEmpty() || conclusions.isNotEmpty() || todos.isNotEmpty() || nextSteps.isNotEmpty()

        return VoiceRecord(
            id = id,
            title = title,
            memo = memo,
            description = description,
            speakers = speakers,
            sourceType = sourceType,
            startTime = java.time.Instant.ofEpochMilli(startTime),
            endTime = endTime?.let { java.time.Instant.ofEpochMilli(it) },
            transcriptText = transcriptText,
            transcriptStatus = try { com.voicenote.app.domain.model.ProcessingStatus.valueOf(transcriptStatus) } catch (_: Exception) { com.voicenote.app.domain.model.ProcessingStatus.PENDING },
            summary = if (hasSummary) VoiceRecordSummary(topics, conclusions, todos, nextSteps) else null,
            summaryStatus = try { com.voicenote.app.domain.model.ProcessingStatus.valueOf(summaryStatus) } catch (_: Exception) { com.voicenote.app.domain.model.ProcessingStatus.PENDING },
            audioFilePath = audioFilePath,
            transcriptFilePath = transcriptFilePath,
            createdAt = java.time.Instant.ofEpochMilli(createdAt)
        )
    }
}
