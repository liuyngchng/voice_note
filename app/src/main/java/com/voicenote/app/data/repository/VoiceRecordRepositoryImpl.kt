package com.voicenote.app.data.repository

import com.voicenote.app.core.database.VoiceRecordDao
import com.voicenote.app.core.database.VoiceRecordEntity
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.model.VoiceRecordSummary
import com.voicenote.app.domain.repository.VoiceRecordRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class VoiceRecordRepositoryImpl @Inject constructor(
    private val voiceRecordDao: VoiceRecordDao
) : VoiceRecordRepository {

    override fun getAllRecordsFlow(): Flow<List<VoiceRecord>> =
        voiceRecordDao.getAllFlow().map { entities -> entities.map { it.toDomain() } }

    override fun searchRecordsFlow(query: String): Flow<List<VoiceRecord>> =
        voiceRecordDao.searchFlow(query).map { entities -> entities.map { it.toDomain() } }

    override fun getRecordsByDateRangeFlow(fromEpochMillis: Long, toEpochMillis: Long): Flow<List<VoiceRecord>> =
        voiceRecordDao.getByDateRangeFlow(fromEpochMillis, toEpochMillis).map { entities ->
            entities.map { it.toDomain() }
        }

    override suspend fun getRecordById(id: Long): VoiceRecord? =
        voiceRecordDao.getById(id)?.toDomain()

    override fun getRecordByIdFlow(id: Long): Flow<VoiceRecord?> =
        voiceRecordDao.getByIdFlow(id).map { it?.toDomain() }

    override suspend fun createRecord(record: VoiceRecord): Long =
        voiceRecordDao.insert(VoiceRecordEntity.fromDomain(record))

    override suspend fun updateRecord(record: VoiceRecord) {
        voiceRecordDao.update(VoiceRecordEntity.fromDomain(record))
    }

    override suspend fun updateTranscript(id: Long, text: String) {
        val entity = voiceRecordDao.getById(id) ?: return
        voiceRecordDao.update(entity.copy(transcriptText = text))
    }

    override suspend fun updateTranscriptWithFile(id: Long, text: String, transcriptFilePath: String) {
        val entity = voiceRecordDao.getById(id) ?: return
        voiceRecordDao.update(entity.copy(transcriptText = text, transcriptFilePath = transcriptFilePath))
    }

    override suspend fun updateSummary(id: Long, summary: VoiceRecordSummary) {
        val entity = voiceRecordDao.getById(id) ?: return
        voiceRecordDao.update(
            entity.copy(
                topicsJson = com.google.gson.Gson().toJson(summary.topics),
                conclusionsJson = com.google.gson.Gson().toJson(summary.conclusions),
                todosJson = com.google.gson.Gson().toJson(summary.todos),
                nextSteps = summary.nextSteps,
                summaryStatus = com.voicenote.app.domain.model.ProcessingStatus.COMPLETED.name
            )
        )
    }

    override suspend fun updateTranscriptStatus(id: Long, status: com.voicenote.app.domain.model.ProcessingStatus) {
        val entity = voiceRecordDao.getById(id) ?: return
        voiceRecordDao.update(entity.copy(transcriptStatus = status.name))
    }

    override suspend fun updateSummaryStatus(id: Long, status: com.voicenote.app.domain.model.ProcessingStatus) {
        val entity = voiceRecordDao.getById(id) ?: return
        voiceRecordDao.update(entity.copy(summaryStatus = status.name))
    }

    override suspend fun updateAudioFilePath(id: Long, path: String, endTime: java.time.Instant) {
        val entity = voiceRecordDao.getById(id) ?: return
        voiceRecordDao.update(
            entity.copy(
                audioFilePath = path,
                endTime = endTime.toEpochMilli()
            )
        )
    }

    override suspend fun deleteRecord(id: Long) {
        voiceRecordDao.deleteById(id)
    }

    override suspend fun getAllTitles(): List<String> =
        voiceRecordDao.getAllTitles()
}
