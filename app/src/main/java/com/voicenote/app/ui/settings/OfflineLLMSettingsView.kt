package com.voicenote.app.ui.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voicenote.app.core.llm.LLMDownloadStatus
import com.voicenote.app.core.llm.LLMModelInfo
import com.voicenote.app.core.llm.LLMModelManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Composable
fun OfflineLLMSettingsView(
    llmMode: String,
    llmUrl: String,
    llmKey: String,
    llmModel: String,
    llmModelInfo: String,
    onLlmModeChange: (String) -> Unit,
    onLlmUrlChange: (String) -> Unit,
    onLlmKeyChange: (String) -> Unit,
    onLlmModelChange: (String) -> Unit,
    onLlmModelInfoChange: (String) -> Unit,
    modelManager: LLMModelManager
) {
    val downloadState by modelManager.downloadState.collectAsState()
    var keyVisible by remember { mutableStateOf(false) }

    // Only reset state when model changes if no operation is in progress
    LaunchedEffect(llmModelInfo) {
        val status = modelManager.downloadState.value.status
        if (status == LLMDownloadStatus.IDLE || status == LLMDownloadStatus.COMPLETED || status == LLMDownloadStatus.FAILED) {
            modelManager.resetState()
        }
    }

    Column(modifier = Modifier.fillMaxWidth()) {

        // ── Header row: title + online/offline switch ──────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "AI 总结",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    if (llmMode == "online") "在线 · OpenAI 兼容接口" else "离线 · llama.cpp",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Text(
                "在线",
                style = MaterialTheme.typography.labelLarge,
                color = if (llmMode == "online") MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.width(8.dp))
            Switch(
                checked = llmMode == "online",
                onCheckedChange = { onLlmModeChange(if (it) "online" else "offline") }
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        // ── Online: API fields ─────────────────────────────────────────────
        if (llmMode == "online") {
            OutlinedTextField(
                value = llmUrl,
                onValueChange = onLlmUrlChange,
                label = { Text("API 地址") },
                placeholder = { Text("https://api.deepseek.com") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            )
            Spacer(modifier = Modifier.height(10.dp))
            OutlinedTextField(
                value = llmKey,
                onValueChange = onLlmKeyChange,
                label = { Text("API Key") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                visualTransformation = if (keyVisible) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { keyVisible = !keyVisible }) {
                        Icon(
                            imageVector = if (keyVisible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                            contentDescription = if (keyVisible) "隐藏" else "显示"
                        )
                    }
                }
            )
            Spacer(modifier = Modifier.height(10.dp))
            OutlinedTextField(
                value = llmModel,
                onValueChange = onLlmModelChange,
                label = { Text("模型") },
                placeholder = { Text("gpt-4o-mini") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            )
        }

        // ── Offline: model selection + download ────────────────────────────
        if (llmMode == "offline") {

            Text(
                "模型选择",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Medium
            )
            Spacer(modifier = Modifier.height(4.dp))

            val isBusy = downloadState.status != LLMDownloadStatus.IDLE
                && downloadState.status != LLMDownloadStatus.COMPLETED
                && downloadState.status != LLMDownloadStatus.FAILED

            val models = listOf(
                "qwen2_5_0_5b_q4km" to LLMModelInfo.QWEN2_5_0_5B,
                "qwen2_5_1_5b_q4km" to LLMModelInfo.QWEN2_5_1_5B,
                "custom" to LLMModelInfo.CUSTOM
            )

            Column {
                models.forEachIndexed { index, (key, info) ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(if (!isBusy) Modifier.clickable { onLlmModelInfoChange(key) } else Modifier)
                            .padding(vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(
                            selected = llmModelInfo == key,
                            onClick = { onLlmModelInfoChange(key) }
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            info.displayName,
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = if (llmModelInfo == key) FontWeight.SemiBold else FontWeight.Normal,
                            modifier = Modifier.weight(1f)
                        )
                        if (key != "custom") {
                            Text(
                                "${info.estimatedSizeMB}MB",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    if (index < models.lastIndex) {
                        HorizontalDivider(modifier = Modifier.padding(start = 48.dp))
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // ── Download / status section ─────────────────────────────────
            val info = LLMModelInfo.fromString(llmModelInfo)
            val isDownloaded = modelManager.isModelDownloaded(info)
            val scope = rememberCoroutineScope()
            val filePicker = rememberLauncherForActivityResult(
                contract = ActivityResultContracts.OpenDocument()
            ) { uri ->
                uri?.let {
                    scope.launch(Dispatchers.IO) { modelManager.uploadModel(info, it) }
                }
            }

            when (downloadState.status) {
                LLMDownloadStatus.IDLE -> {
                    if (isDownloaded) {
                        ModelReadyCard(
                            sizeMB = modelManager.downloadedModelSize(info) / 1_048_576,
                            onDelete = { modelManager.deleteModel(info) }
                        )
                    } else {
                        DownloadActionsCard(
                            showDownload = info != LLMModelInfo.CUSTOM,
                            onDownload = {
                                scope.launch(Dispatchers.IO) { modelManager.downloadModel(info) }
                            },
                            onUpload = { filePicker.launch(arrayOf("*/*")) }
                        )
                    }
                }

                LLMDownloadStatus.DOWNLOADING,
                LLMDownloadStatus.UPLOADING -> {
                    DownloadProgressCard(
                        isUploading = downloadState.status == LLMDownloadStatus.UPLOADING,
                        isExtracting = false,
                        progress = downloadState.progress
                    )
                }

                LLMDownloadStatus.COMPLETED -> {
                    ModelReadyCard(
                        sizeMB = modelManager.downloadedModelSize(info) / 1_048_576,
                        onDelete = {
                            modelManager.deleteModel(info)
                            modelManager.resetState()
                        }
                    )
                }

                LLMDownloadStatus.FAILED -> {
                    DownloadFailedCard(
                        showRetry = info != LLMModelInfo.CUSTOM,
                        error = downloadState.error,
                        onRetry = {
                            modelManager.resetState()
                            scope.launch(Dispatchers.IO) { modelManager.downloadModel(info) }
                        },
                        onUpload = { filePicker.launch(arrayOf("*/*")) }
                    )
                }
            }
        }
    }
}

// ── Reusable sub-composables (shared with ASR view) ────────────────────────

@Composable
private fun ModelReadyCard(
    sizeMB: Long = 0,
    onDelete: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            Icons.Default.CheckCircle,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(22.dp)
        )
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                "模型已就绪",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.primary
            )
            if (sizeMB > 0) {
                Text(
                    "${sizeMB}MB",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        OutlinedButton(
            onClick = onDelete,
            shape = RoundedCornerShape(10.dp)
        ) {
            Text("删除")
        }
    }
}

@Composable
private fun DownloadActionsCard(
    showDownload: Boolean = true,
    onDownload: () -> Unit,
    onUpload: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (showDownload) {
            Button(
                onClick = onDownload,
                modifier = Modifier.weight(1f).height(48.dp),
                shape = RoundedCornerShape(12.dp)
            ) {
                Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(6.dp))
                Text("下载")
            }
        }
        OutlinedButton(
            onClick = onUpload,
            modifier = Modifier.weight(1f).height(48.dp),
            shape = RoundedCornerShape(12.dp)
        ) {
            Icon(Icons.Default.UploadFile, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text("上传")
        }
    }
}

@Composable
private fun DownloadProgressCard(isUploading: Boolean, isExtracting: Boolean, progress: Float) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.primary
            )
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    when {
                        isUploading -> "正在复制模型..."
                        isExtracting -> "正在解压模型..."
                        else -> "正在下载模型..."
                    },
                    style = MaterialTheme.typography.bodyMedium
                )
                if (!isExtracting) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        "${(progress * 100).toInt()}%",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
        if (!isExtracting) {
            Spacer(modifier = Modifier.height(10.dp))
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth().height(6.dp),
                color = MaterialTheme.colorScheme.primary,
                trackColor = MaterialTheme.colorScheme.surfaceVariant,
            )
        }
    }
}

@Composable
private fun DownloadFailedCard(
    showRetry: Boolean = true,
    error: String?,
    onRetry: () -> Unit,
    onUpload: () -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Default.Error,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                error ?: "下载失败",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
        Spacer(modifier = Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (showRetry) {
                Button(
                    onClick = onRetry,
                    modifier = Modifier.weight(1f).height(48.dp),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text("重试")
                }
            }
            OutlinedButton(
                onClick = onUpload,
                modifier = Modifier.weight(1f).height(48.dp),
                shape = RoundedCornerShape(12.dp)
            ) {
                Icon(Icons.Default.UploadFile, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(6.dp))
                Text("上传")
            }
        }
    }
}
