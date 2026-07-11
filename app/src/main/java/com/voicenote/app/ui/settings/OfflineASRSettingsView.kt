package com.voicenote.app.ui.settings

import android.app.ActivityManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voicenote.app.core.asr.DownloadStatus
import com.voicenote.app.core.asr.ASRModelManager
import com.voicenote.app.core.asr.ModelQuality
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Composable
fun OfflineASRSettingsView(
    modelQuality: String,
    onModelQualityChange: (String) -> Unit,
    asrModelManager: ASRModelManager,
    onModelReady: (com.voicenote.app.core.asr.ModelQuality) -> Unit = {},
    onModelDeleted: () -> Unit = {}
) {
    val downloadState by asrModelManager.downloadState.collectAsState()
    val context = LocalContext.current
    val quality = if (modelQuality == "fp32") ModelQuality.FP32 else ModelQuality.INT8

    // Only reset state when quality changes if no operation is in progress
    LaunchedEffect(modelQuality) {
        val status = asrModelManager.downloadState.value.status
        if (status == DownloadStatus.IDLE || status == DownloadStatus.COMPLETED || status == DownloadStatus.FAILED) {
            asrModelManager.resetState()
        }
    }

    // Auto-load model into memory after download/import completes
    LaunchedEffect(downloadState.status) {
        if (downloadState.status == DownloadStatus.COMPLETED) {
            onModelReady(quality)
        }
    }

    val totalRamGB = remember {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memInfo = ActivityManager.MemoryInfo()
        am.getMemoryInfo(memInfo)
        memInfo.totalMem / (1024.0 * 1024 * 1024)
    }

    Column(modifier = Modifier.fillMaxWidth()) {

        // ── Header ───────────────────────────────────────────────────────
        Text(
            "语音识别",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            "离线 · SenseVoice",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Model quality segmented chips
        Text(
            "模型质量",
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.Medium
        )
        Spacer(modifier = Modifier.height(8.dp))
        val isBusy = downloadState.status != DownloadStatus.IDLE
            && downloadState.status != DownloadStatus.COMPLETED
            && downloadState.status != DownloadStatus.FAILED

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(
                selected = modelQuality == "int8",
                onClick = { onModelQualityChange("int8") },
                label = { Text("INT8") },
                enabled = !isBusy,
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                    selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer
                )
            )
            FilterChip(
                selected = modelQuality == "fp32",
                onClick = { onModelQualityChange("fp32") },
                label = { Text("FP32") },
                enabled = !isBusy,
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                    selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer
                )
            )
        }

        Spacer(modifier = Modifier.height(6.dp))
        Text(
            "约 ${quality.estimatedSizeMB}MB",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        // Low-memory warning
        if (modelQuality == "fp32" && totalRamGB < 4.0) {
            Spacer(modifier = Modifier.height(8.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp)
            ) {
                Icon(
                    Icons.Default.Error,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    "设备内存仅 %.1f GB，可能无法加载 FP32 模型".format(totalRamGB),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // ── Download / status section ─────────────────────────────────
        val isDownloaded = asrModelManager.isModelDownloaded(quality)
        val scope = rememberCoroutineScope()
        val filePicker = rememberLauncherForActivityResult(
            contract = ActivityResultContracts.OpenDocument()
        ) { uri ->
            uri?.let {
                scope.launch(Dispatchers.IO) { asrModelManager.uploadModel(quality, it) }
            }
        }

        when (downloadState.status) {
            DownloadStatus.IDLE -> {
                if (isDownloaded) {
                    ModelReadyCard(
                        onDelete = {
                            asrModelManager.deleteModel(quality)
                            onModelDeleted()
                            android.widget.Toast.makeText(context, "模型已删除", android.widget.Toast.LENGTH_SHORT).show()
                        }
                    )
                } else {
                    DownloadActionsCard(
                        onDownload = {
                            scope.launch(Dispatchers.IO) { asrModelManager.downloadModel(quality) }
                        },
                        onUpload = { filePicker.launch(arrayOf("*/*")) }
                    )
                }
            }

            DownloadStatus.DOWNLOADING,
            DownloadStatus.UPLOADING,
            DownloadStatus.EXTRACTING -> {
                DownloadProgressCard(
                    isUploading = downloadState.status == DownloadStatus.UPLOADING,
                    isExtracting = downloadState.status == DownloadStatus.EXTRACTING,
                    progress = downloadState.progress
                )
            }

            DownloadStatus.COMPLETED -> {
                ModelReadyCard(
                    onDelete = {
                        asrModelManager.deleteModel(quality)
                        asrModelManager.resetState()
                        onModelDeleted()
                        android.widget.Toast.makeText(context, "模型已删除", android.widget.Toast.LENGTH_SHORT).show()
                    }
                )
            }

            DownloadStatus.FAILED -> {
                DownloadFailedCard(
                    error = downloadState.error,
                    downloadUrl = downloadState.downloadUrl,
                    onRetry = {
                        asrModelManager.resetState()
                        scope.launch(Dispatchers.IO) { asrModelManager.downloadModel(quality) }
                    },
                    onUpload = { filePicker.launch(arrayOf("*/*")) }
                )
            }
        }
    }
}

// ── Reusable sub-composables ───────────────────────────────────────────────

@Composable
private fun ModelReadyCard(onDelete: () -> Unit) {
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
        Text(
            "模型已就绪",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.weight(1f)
        )
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
    onDownload: () -> Unit,
    onUpload: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Button(
            onClick = onDownload,
            modifier = Modifier.weight(1f).height(48.dp),
            shape = RoundedCornerShape(12.dp)
        ) {
            Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text("下载")
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
                        isExtracting -> "正在提取模型..."
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
        Spacer(modifier = Modifier.height(10.dp))
        if (isExtracting) {
            LinearProgressIndicator(
                modifier = Modifier.fillMaxWidth().height(6.dp),
                color = MaterialTheme.colorScheme.primary,
                trackColor = MaterialTheme.colorScheme.surfaceVariant,
            )
        } else {
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
    error: String?,
    downloadUrl: String?,
    onRetry: () -> Unit,
    onUpload: () -> Unit
) {
    val clipboardManager = androidx.compose.ui.platform.LocalClipboardManager.current
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
        if (downloadUrl != null) {
            Spacer(modifier = Modifier.height(8.dp))
            androidx.compose.foundation.text.selection.SelectionContainer {
                Text(
                    downloadUrl,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(modifier = Modifier.height(4.dp))
            OutlinedButton(
                onClick = {
                    clipboardManager.setText(androidx.compose.ui.text.AnnotatedString(downloadUrl))
                },
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.height(36.dp)
            ) {
                Text("复制链接", style = MaterialTheme.typography.labelSmall)
            }
        }
        Spacer(modifier = Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = onRetry,
                modifier = Modifier.weight(1f).height(48.dp),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text("重试")
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
