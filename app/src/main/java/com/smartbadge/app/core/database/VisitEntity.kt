package com.smartbadge.app.core.database

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.smartbadge.app.domain.model.LocationPoint
import com.smartbadge.app.domain.model.TodoItem
import com.smartbadge.app.domain.model.Visit
import com.smartbadge.app.domain.model.VisitSummary

@Entity(tableName = "visits")
data class VisitEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val clientName: String,
    val clientCompany: String,
    val purpose: String,
    val participantsJson: String,       // JSON array of strings
    val startTime: Long,                // epoch millis
    val endTime: Long?,                 // epoch millis
    val locationPointsJson: String,     // JSON array of LocationPoint
    val transcriptText: String,
    val topicsJson: String,             // JSON array of strings
    val conclusionsJson: String,        // JSON array of strings
    val todosJson: String,              // JSON array of TodoItem
    val nextSteps: String,
    val audioFilePath: String,
    val createdAt: Long                 // epoch millis
) {
    companion object {
        private val gson = Gson()

        fun fromDomain(visit: Visit): VisitEntity = VisitEntity(
            id = visit.id,
            clientName = visit.clientName,
            clientCompany = visit.clientCompany,
            purpose = visit.purpose,
            participantsJson = gson.toJson(visit.participants),
            startTime = visit.startTime.toEpochMilli(),
            endTime = visit.endTime?.toEpochMilli(),
            locationPointsJson = gson.toJson(visit.locationPoints),
            transcriptText = visit.transcriptText,
            topicsJson = gson.toJson(visit.summary?.topics ?: emptyList<String>()),
            conclusionsJson = gson.toJson(visit.summary?.conclusions ?: emptyList<String>()),
            todosJson = gson.toJson(visit.summary?.todos ?: emptyList<TodoItem>()),
            nextSteps = visit.summary?.nextSteps ?: "",
            audioFilePath = visit.audioFilePath,
            createdAt = visit.createdAt.toEpochMilli()
        )
    }

    fun toDomain(): Visit {
        val topics: List<String> = try {
            gson.fromJson(topicsJson, object : TypeToken<List<String>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val conclusions: List<String> = try {
            gson.fromJson(conclusionsJson, object : TypeToken<List<String>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val todos: List<TodoItem> = try {
            gson.fromJson(todosJson, object : TypeToken<List<TodoItem>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val participants: List<String> = try {
            gson.fromJson(participantsJson, object : TypeToken<List<String>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val locationPoints: List<LocationPoint> = try {
            gson.fromJson(locationPointsJson, object : TypeToken<List<LocationPoint>>() {}.type)
        } catch (_: Exception) { emptyList() }

        val hasSummary = topics.isNotEmpty() || conclusions.isNotEmpty() || todos.isNotEmpty() || nextSteps.isNotEmpty()

        return Visit(
            id = id,
            clientName = clientName,
            clientCompany = clientCompany,
            purpose = purpose,
            participants = participants,
            startTime = java.time.Instant.ofEpochMilli(startTime),
            endTime = endTime?.let { java.time.Instant.ofEpochMilli(it) },
            locationPoints = locationPoints,
            transcriptText = transcriptText,
            summary = if (hasSummary) VisitSummary(topics, conclusions, todos, nextSteps) else null,
            audioFilePath = audioFilePath,
            createdAt = java.time.Instant.ofEpochMilli(createdAt)
        )
    }
}
