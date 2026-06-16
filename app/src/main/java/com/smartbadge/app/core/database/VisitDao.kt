package com.smartbadge.app.core.database

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface VisitDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(visit: VisitEntity): Long

    @Update
    suspend fun update(visit: VisitEntity)

    @Query("SELECT * FROM visits WHERE id = :id")
    suspend fun getById(id: Long): VisitEntity?

    @Query("SELECT * FROM visits ORDER BY startTime DESC")
    fun getAllFlow(): Flow<List<VisitEntity>>

    @Query("SELECT * FROM visits ORDER BY startTime DESC")
    suspend fun getAll(): List<VisitEntity>

    @Query("SELECT * FROM visits WHERE clientName LIKE '%' || :query || '%' OR clientCompany LIKE '%' || :query || '%' ORDER BY startTime DESC")
    fun searchFlow(query: String): Flow<List<VisitEntity>>

    @Query("SELECT * FROM visits WHERE startTime BETWEEN :from AND :to ORDER BY startTime DESC")
    fun getByDateRangeFlow(from: Long, to: Long): Flow<List<VisitEntity>>

    @Query("DELETE FROM visits WHERE id = :id")
    suspend fun deleteById(id: Long)

    @Query("SELECT DISTINCT clientName FROM visits ORDER BY clientName")
    suspend fun getAllClientNames(): List<String>
}
