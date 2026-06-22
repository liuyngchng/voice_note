package com.voicenote.app.core.database

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface VoiceRecordDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(record: VoiceRecordEntity): Long

    @Update
    suspend fun update(record: VoiceRecordEntity)

    @Query("SELECT * FROM voice_records WHERE id = :id")
    suspend fun getById(id: Long): VoiceRecordEntity?

    @Query("SELECT * FROM voice_records WHERE id = :id")
    fun getByIdFlow(id: Long): Flow<VoiceRecordEntity?>

    @Query("SELECT * FROM voice_records ORDER BY startTime DESC")
    fun getAllFlow(): Flow<List<VoiceRecordEntity>>

    @Query("SELECT * FROM voice_records ORDER BY startTime DESC")
    suspend fun getAll(): List<VoiceRecordEntity>

    @Query("SELECT * FROM voice_records WHERE title LIKE '%' || :query || '%' OR memo LIKE '%' || :query || '%' OR description LIKE '%' || :query || '%' OR transcriptText LIKE '%' || :query || '%' ORDER BY startTime DESC")
    fun searchFlow(query: String): Flow<List<VoiceRecordEntity>>

    @Query("SELECT * FROM voice_records WHERE startTime BETWEEN :from AND :to ORDER BY startTime DESC")
    fun getByDateRangeFlow(from: Long, to: Long): Flow<List<VoiceRecordEntity>>

    @Query("DELETE FROM voice_records WHERE id = :id")
    suspend fun deleteById(id: Long)

    @Query("SELECT DISTINCT title FROM voice_records ORDER BY title")
    suspend fun getAllTitles(): List<String>
}
