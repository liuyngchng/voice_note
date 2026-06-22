package com.voicenote.app.domain.repository

import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.model.VoiceRecordSummary
import kotlinx.coroutines.flow.Flow

interface VoiceRecordRepository {
    fun getAllRecordsFlow(): Flow<List<VoiceRecord>>
    fun searchRecordsFlow(query: String): Flow<List<VoiceRecord>>
    fun getRecordsByDateRangeFlow(fromEpochMillis: Long, toEpochMillis: Long): Flow<List<VoiceRecord>>
    suspend fun getRecordById(id: Long): VoiceRecord?
    fun getRecordByIdFlow(id: Long): Flow<VoiceRecord?>
    suspend fun createRecord(record: VoiceRecord): Long
    suspend fun updateRecord(record: VoiceRecord)
    suspend fun updateTranscript(id: Long, text: String)
    suspend fun updateTranscriptWithFile(id: Long, text: String, transcriptFilePath: String)
    suspend fun updateSummary(id: Long, summary: VoiceRecordSummary)
    suspend fun updateTranscriptStatus(id: Long, status: com.voicenote.app.domain.model.ProcessingStatus)
    suspend fun updateSummaryStatus(id: Long, status: com.voicenote.app.domain.model.ProcessingStatus)
    suspend fun updateAudioFilePath(id: Long, path: String, endTime: java.time.Instant)
    suspend fun deleteRecord(id: Long)
    suspend fun getAllTitles(): List<String>
}
