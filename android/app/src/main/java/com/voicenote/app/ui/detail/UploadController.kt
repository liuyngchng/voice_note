package com.voicenote.app.ui.detail

import android.util.Log
import com.voicenote.app.core.di.SettingsDataStore
import com.voicenote.app.core.network.ServerClient
import com.voicenote.app.domain.model.VoiceRecord
import com.voicenote.app.domain.repository.VoiceRecordRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.io.File

data class UploadViewState(
    val isUploading: Boolean = false,
    val progressMessage: String = "",
    val error: String? = null,
    val showConfirm: Boolean = false
)

/**
 * 服务器上传控制器，从 [DetailViewModel] 中抽离。
 */
class UploadController(
    private val scope: CoroutineScope,
    private val recordRepository: VoiceRecordRepository,
    private val serverClient: ServerClient,
    private val settingsDataStore: SettingsDataStore
) {
    private val _state = MutableStateFlow(UploadViewState())
    val state: StateFlow<UploadViewState> = _state.asStateFlow()

    fun onUploadClick(record: VoiceRecord?) {
        if (record == null || _state.value.isUploading) return
        if (record.serverRecordId.isNotBlank()) {
            _state.value = _state.value.copy(showConfirm = true)
            return
        }
        upload(record)
    }

    fun dismissConfirm() { _state.value = _state.value.copy(showConfirm = false) }
    fun dismissError() { _state.value = _state.value.copy(error = null) }

    fun confirmReUpload(record: VoiceRecord?) {
        _state.value = _state.value.copy(showConfirm = false)
        if (record != null) upload(record)
    }

    private fun upload(record: VoiceRecord) {
        if (_state.value.isUploading) return
        val audioPath = record.audioFilePath
        if (audioPath.isBlank()) {
            _state.value = _state.value.copy(error = "没有关联的音频文件，无法上传")
            return
        }
        val audioFile = File(audioPath)
        if (!audioFile.exists()) {
            _state.value = _state.value.copy(error = "音频文件不存在或已被删除")
            return
        }

        _state.value = _state.value.copy(isUploading = true, progressMessage = "准备上传...", error = null)
        scope.launch {
            try {
                val serverUri = settingsDataStore.settingsFlow.first().serverUri
                val result = serverClient.uploadAudio(
                    audioFile = audioFile,
                    record = record,
                    serverUri = serverUri,
                    onProgress = { msg -> _state.value = _state.value.copy(progressMessage = msg) }
                )
                result.onSuccess { r ->
                    if (r.serverRecordId.isNotBlank()) {
                        recordRepository.updateServerRecordId(record.id, r.serverRecordId)
                    }
                    _state.value = _state.value.copy(isUploading = false, progressMessage = "", error = null)
                }.onFailure { e ->
                    _state.value = _state.value.copy(isUploading = false, progressMessage = "", error = e.message ?: "上传失败")
                }
            } catch (e: Exception) {
                _state.value = _state.value.copy(isUploading = false, progressMessage = "", error = e.message ?: "上传失败")
            }
        }
    }
}