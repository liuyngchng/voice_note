package com.voicenote.app.ui.settings

import android.app.ActivityManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.voicenote.app.core.asr.DownloadStatus
import com.voicenote.app.core.asr.ModelDownloadManager
import com.voicenote.app.core.asr.ModelQuality
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.launch

@Composable
fun OfflineASRSettingsView(
    asrMode: String,
    asrUrl: String,
    modelQuality: String,
    onAsrModeChange: (String) -> Unit,
    onAsrUrlChange: (String) -> Unit,
    onModelQualityChange: (String) -> Unit,
    downloadManager: ModelDownloadManager
) {
    val downloadState by downloadManager.downloadState.collectAsState()
    val context = LocalContext.current

    val totalRamGB = remember {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memInfo = ActivityManager.MemoryInfo()
        am.getMemoryInfo(memInfo)
        memInfo.totalMem / (1024.0 * 1024 * 1024)
    }

    Column(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                "语音识别",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f)
            )
            Text(
                "离线",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (asrMode == "offline") FontWeight.Bold else FontWeight.Normal,
                color = if (asrMode == "offline") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
            )
            Spacer(modifier = Modifier.padding(start = 8.dp))
            Switch(
                checked = asrMode == "online",
                onCheckedChange = { checked -> onAsrModeChange(if (checked) "online" else "offline") }
            )
            Spacer(modifier = Modifier.padding(start = 8.dp))
            Text(
                "在线",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (asrMode == "online") FontWeight.Bold else FontWeight.Normal,
                color = if (asrMode == "online") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
            )
        }

        if (asrMode == "online") {
            Spacer(modifier = Modifier.height(12.dp))
            ScrollableOutlinedField(
                value = asrUrl,
                onValueChange = onAsrUrlChange,
                label = "WebSocket 地址",
                placeholder = "ws://192.168.240.29:10095",
                modifier = Modifier.fillMaxWidth()
            )
        }

        if (asrMode == "offline") {
            Spacer(modifier = Modifier.height(16.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "模型质量",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    "INT8",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = if (modelQuality == "int8") FontWeight.Bold else FontWeight.Normal,
                    color = if (modelQuality == "int8") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                )
                Spacer(modifier = Modifier.padding(start = 8.dp))
                Switch(
                    checked = modelQuality == "fp32",
                    onCheckedChange = { checked -> onModelQualityChange(if (checked) "fp32" else "int8") }
                )
                Spacer(modifier = Modifier.padding(start = 8.dp))
                Text(
                    "FP32",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = if (modelQuality == "fp32") FontWeight.Bold else FontWeight.Normal,
                    color = if (modelQuality == "fp32") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                )
            }

            if (modelQuality == "fp32" && totalRamGB < 4.0) {
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    "FP32 模型需要约 860MB 内存，当前设备内存仅 %.1f GB，可能无法正常加载，建议使用 INT8 模型。".format(totalRamGB),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error.copy(alpha = 0.8f)
                )
            }

            Spacer(modifier = Modifier.height(12.dp))

            val quality = if (modelQuality == "fp32") ModelQuality.FP32 else ModelQuality.INT8
            val isDownloaded = downloadManager.isModelDownloaded(quality)
            val scope = rememberCoroutineScope()
            val filePicker = rememberLauncherForActivityResult(
                contract = ActivityResultContracts.OpenDocument()
            ) { uri ->
                uri?.let {
                    scope.launch(Dispatchers.IO) {
                        downloadManager.uploadModel(quality, it)
                    }
                }
            }

            when (downloadState.status) {
                DownloadStatus.IDLE -> {
                    if (isDownloaded) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("模型已就绪", color = MaterialTheme.colorScheme.primary)
                            Spacer(modifier = Modifier.weight(1f))
                            OutlinedButton(onClick = { downloadManager.deleteModel(quality) }) {
                                Text("删除模型")
                            }
                        }
                    } else {
                        Button(
                            onClick = {
                                scope.launch(Dispatchers.IO) {
                                    downloadManager.downloadModel(quality)
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(8.dp)
                        ) {
                            Text("下载模型 (~${quality.estimatedSizeMB}MB)")
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        OutlinedButton(
                            onClick = { filePicker.launch(arrayOf("*/*")) },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(8.dp)
                        ) {
                            Text("上传模型")
                        }
                    }
                }
                DownloadStatus.DOWNLOADING -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.padding(start = 8.dp))
                        Text("处理中 ${(downloadState.progress * 100).toInt()}%")
                    }
                }
                DownloadStatus.EXTRACTING -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.padding(start = 8.dp))
                        Text("解压中...")
                    }
                }
                DownloadStatus.COMPLETED -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("模型已就绪", color = MaterialTheme.colorScheme.primary)
                        Spacer(modifier = Modifier.weight(1f))
                        OutlinedButton(onClick = {
                            downloadManager.deleteModel(quality)
                            downloadManager.resetState()
                        }) {
                            Text("删除模型")
                        }
                    }
                }
                DownloadStatus.FAILED -> {
                    Column {
                        Text("失败: ${downloadState.error ?: "未知错误"}", color = MaterialTheme.colorScheme.error)
                        Spacer(modifier = Modifier.height(8.dp))
                        Button(
                            onClick = {
                                downloadManager.resetState()
                                scope.launch(Dispatchers.IO) {
                                    downloadManager.downloadModel(quality)
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(8.dp)
                        ) {
                            Text("重试下载")
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        OutlinedButton(
                            onClick = { filePicker.launch(arrayOf("*/*")) },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(8.dp)
                        ) {
                            Text("上传模型")
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ScrollableOutlinedField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    placeholder: String,
    modifier: Modifier = Modifier,
    singleLine: Boolean = true,
    readOnly: Boolean = false,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    trailingIcon: @Composable (() -> Unit)? = null
) {
    val scrollState = rememberScrollState()
    val textStyle = MaterialTheme.typography.bodyLarge
    val interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }

    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.defaultMinSize(minHeight = 56.dp),
        singleLine = singleLine,
        readOnly = readOnly,
        textStyle = textStyle.copy(color = MaterialTheme.colorScheme.onSurface),
        visualTransformation = visualTransformation,
        interactionSource = interactionSource
    ) { innerTextField ->
        OutlinedTextFieldDefaults.DecorationBox(
            value = value,
            innerTextField = {
                Box(modifier = Modifier.horizontalScroll(scrollState)) {
                    innerTextField()
                }
            },
            enabled = true,
            singleLine = singleLine,
            visualTransformation = visualTransformation,
            interactionSource = interactionSource,
            label = { Text(label) },
            placeholder = { Text(placeholder) },
            trailingIcon = trailingIcon,
            colors = OutlinedTextFieldDefaults.colors()
        )
    }
}
