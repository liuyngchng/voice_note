package com.voicenote.app.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voicenote.app.core.llm.LLMDownloadStatus
import com.voicenote.app.core.llm.LLMModelInfo
import com.voicenote.app.core.llm.LLMModelManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Composable
fun OfflineLLMSettingsView(
    llmMode: String,
    llmModelInfo: String,
    onLlmModeChange: (String) -> Unit,
    onLlmModelInfoChange: (String) -> Unit,
    modelManager: LLMModelManager
) {
    val downloadState by modelManager.downloadState.collectAsState()

    Column(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Text("LLM 模式", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)

        Spacer(modifier = Modifier.height(8.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ModeChip(
                label = "在线 (API)",
                selected = llmMode == "online",
                onClick = { onLlmModeChange("online") },
                modifier = Modifier.weight(1f)
            )
            ModeChip(
                label = "离线 (本地模型)",
                selected = llmMode == "offline",
                onClick = { onLlmModeChange("offline") },
                modifier = Modifier.weight(1f)
            )
        }

        if (llmMode == "offline") {
            Spacer(modifier = Modifier.height(16.dp))

            Text("模型选择", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(8.dp))

            val models = listOf(
                "qwen2_5_0_5b_q4km" to LLMModelInfo.QWEN2_5_0_5B,
                "qwen2_5_1_5b_q4km" to LLMModelInfo.QWEN2_5_1_5B,
                "custom" to LLMModelInfo.CUSTOM
            )

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                models.forEach { (key, info) ->
                    ModelChip(
                        label = info.displayName,
                        selected = llmModelInfo == key,
                        onClick = { onLlmModelInfoChange(key) },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            val info = LLMModelInfo.fromString(llmModelInfo)
            val isDownloaded = modelManager.isModelDownloaded(info)

            when (downloadState.status) {
                LLMDownloadStatus.IDLE -> {
                    if (isDownloaded) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("模型已下载 (${modelManager.downloadedModelSize(info) / 1_048_576}MB)", color = MaterialTheme.colorScheme.primary)
                            Spacer(modifier = Modifier.weight(1f))
                            OutlinedButton(onClick = { modelManager.deleteModel(info) }) {
                                Text("删除模型")
                            }
                        }
                    } else {
                        Button(
                            onClick = {
                                CoroutineScope(Dispatchers.IO).launch {
                                    modelManager.downloadModel(info)
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(8.dp)
                        ) {
                            Text("下载模型 (~${info.estimatedSizeMB}MB)")
                        }
                    }
                }
                LLMDownloadStatus.DOWNLOADING -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.padding(start = 8.dp))
                        Text("下载中 ${(downloadState.progress * 100).toInt()}%")
                    }
                }
                LLMDownloadStatus.COMPLETED -> {
                    Text("模型已就绪", color = MaterialTheme.colorScheme.primary)
                }
                LLMDownloadStatus.FAILED -> {
                    Column {
                        Text("下载失败: ${downloadState.error ?: "未知错误"}", color = MaterialTheme.colorScheme.error)
                        Spacer(modifier = Modifier.height(8.dp))
                        Button(
                            onClick = {
                                modelManager.resetState()
                                CoroutineScope(Dispatchers.IO).launch {
                                    modelManager.downloadModel(info)
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(8.dp)
                        ) {
                            Text("重试")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ModeChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Button(
        onClick = onClick,
        modifier = modifier.height(40.dp),
        shape = RoundedCornerShape(8.dp),
        colors = if (selected)
            ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary)
        else
            ButtonDefaults.outlinedButtonColors()
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
private fun ModelChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Button(
        onClick = onClick,
        modifier = modifier.height(40.dp),
        shape = RoundedCornerShape(8.dp),
        colors = if (selected)
            ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary)
        else
            ButtonDefaults.outlinedButtonColors()
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
        )
    }
}
