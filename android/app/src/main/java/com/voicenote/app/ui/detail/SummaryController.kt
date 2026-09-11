package com.voicenote.app.ui.detail

import android.util.Log
import com.voicenote.app.core.llm.LLMConfig
import com.voicenote.app.core.llm.OnlineLLMClient
import com.voicenote.app.domain.model.ProcessingStatus
import com.voicenote.app.domain.model.RecordSummary
import com.voicenote.app.domain.repository.VoiceRecordRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

data class SummaryViewState(
    val isGenerating: Boolean = false,
    val progressMessage: String = "",
    val error: String? = null
)

/**
 * AI 总结控制器，从 [DetailViewModel] 中抽离。
 * 负责调用在线 LLM 生成结构化会议总结。
 */
class SummaryController(
    private val scope: CoroutineScope,
    private val recordRepository: VoiceRecordRepository
) {
    private val _state = MutableStateFlow(SummaryViewState())
    val state: StateFlow<SummaryViewState> = _state.asStateFlow()

    private val onlineLLMClient = OnlineLLMClient()
    private var job: Job? = null

    fun generate(recordId: Long, transcriptFilePath: String?, config: LLMConfig, onDone: () -> Unit) {
        if (_state.value.isGenerating) return
        val path = transcriptFilePath
        if (path.isNullOrBlank()) {
            _state.value = _state.value.copy(error = "没有转写文本，无法生成总结")
            return
        }
        val file = File(path)
        if (!file.exists()) {
            _state.value = _state.value.copy(error = "转写文件不存在")
            return
        }
        val transcript: String
        try {
            transcript = file.readText()
        } catch (e: Exception) {
            _state.value = _state.value.copy(error = "读取转写文本失败: ${e.message}")
            return
        }
        if (transcript.isBlank()) {
            _state.value = _state.value.copy(error = "转写内容为空，无法生成总结")
            return
        }

        _state.value = _state.value.copy(isGenerating = true, progressMessage = "正在连接 LLM...", error = null)
        job = scope.launch {
            recordRepository.updateSummaryStatus(recordId, ProcessingStatus.PROCESSING)
            try {
                if (!config.isValid) {
                    recordRepository.updateSummaryStatus(recordId, ProcessingStatus.UNAVAILABLE)
                    _state.value = _state.value.copy(
                        isGenerating = false, progressMessage = "",
                        error = "请在设置中配置在线大语言模型的 API 地址和密钥"
                    )
                    onDone()
                    return@launch
                }
                val result = onlineLLMClient.generateSummary(
                    transcript = transcript,
                    config = config,
                    onProgress = { msg -> _state.value = _state.value.copy(progressMessage = msg) }
                )
                result.onSuccess { summary ->
                    recordRepository.updateSummary(recordId, summary)
                    _state.value = _state.value.copy(isGenerating = false, progressMessage = "", error = null)
                    onDone()
                }.onFailure { e ->
                    recordRepository.updateSummaryStatus(recordId, ProcessingStatus.UNAVAILABLE)
                    _state.value = _state.value.copy(isGenerating = false, progressMessage = "", error = e.message ?: "总结生成失败")
                    onDone()
                }
            } catch (e: Exception) {
                recordRepository.updateSummaryStatus(recordId, ProcessingStatus.UNAVAILABLE)
                _state.value = _state.value.copy(isGenerating = false, progressMessage = "", error = e.message ?: "总结生成失败")
                onDone()
            } finally { job = null }
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
        _state.value = _state.value.copy(isGenerating = false, progressMessage = "")
    }
}