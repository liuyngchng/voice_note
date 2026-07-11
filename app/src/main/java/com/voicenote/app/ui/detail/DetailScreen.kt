package com.voicenote.app.ui.detail

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.voicenote.app.domain.model.VoiceRecord
import java.io.File
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(
    recordId: Long,
    onBack: () -> Unit,
    viewModel: DetailViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }
    var selectedTab by remember { mutableIntStateOf(0) }

    LaunchedEffect(recordId) {
        viewModel.loadRecord(recordId)
    }

    LaunchedEffect(uiState.isDeleted) {
        if (uiState.isDeleted) onBack()
    }

    DisposableEffect(Unit) {
        onDispose { viewModel.releasePlayer() }
    }

    LaunchedEffect(uiState.error) {
        uiState.error?.let { error ->
            snackbarHostState.showSnackbar(error)
            viewModel.clearError()
        }
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text("录音详情") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    IconButton(onClick = viewModel::showDeleteConfirm) {
                        Icon(
                            Icons.Default.Delete,
                            contentDescription = "删除记录",
                            tint = MaterialTheme.colorScheme.onPrimary
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    titleContentColor = MaterialTheme.colorScheme.onPrimary,
                    navigationIconContentColor = MaterialTheme.colorScheme.onPrimary
                )
            )
        }
    ) { padding ->
        when {
            uiState.isLoading -> {
                Box(modifier = Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
            uiState.record == null -> {
                Box(modifier = Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                    Text("记录未找到", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
                }
            }
            else -> {
                val record = uiState.record!!
                Column(modifier = Modifier.fillMaxSize().padding(padding)) {
                    // Segmented tab selector — 2 tabs only
                    SingleChoiceSegmentedButtonRow(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp)
                    ) {
                        SegmentedButton(
                            selected = selectedTab == 0,
                            onClick = { selectedTab = 0 },
                            shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2)
                        ) { Text("音频") }
                        SegmentedButton(
                            selected = selectedTab == 1,
                            onClick = { selectedTab = 1 },
                            shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2)
                        ) { Text("转写") }
                    }

                    when (selectedTab) {
                        0 -> AudioTab(
                            record = record,
                            playbackState = uiState.playbackState,
                            playbackProgress = uiState.playbackProgress,
                            playbackPositionFormatted = uiState.playbackPositionFormatted,
                            playbackDurationFormatted = uiState.playbackDurationFormatted,
                            onPlayPause = viewModel::playPause,
                            onSeek = viewModel::seekTo,
                            onSkipBack = viewModel::skipBack,
                            onSkipForward = viewModel::skipForward,
                            onShare = viewModel::shareAudio
                        )
                        1 -> TranscriptTab(
                            record = record,
                            isRetrying = uiState.isRetryingTranscript,
                            retryProgress = uiState.retryProgress,
                            onRetry = viewModel::retryTranscript,
                            onCancel = viewModel::cancelRetryTranscript,
                            onShareTranscript = viewModel::shareTranscript,
                            onPreview = viewModel::openTranscriptPreview
                        )
                    }
                }
            }
        }
    }

    // Delete confirmation dialog
    if (uiState.showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = viewModel::dismissDeleteConfirm,
            title = { Text("删除确认") },
            text = { Text("确定要删除这条录音记录及其录音文件吗？此操作不可撤销。") },
            confirmButton = {
                TextButton(
                    onClick = viewModel::deleteRecord,
                    enabled = !uiState.isDeleting
                ) {
                    if (uiState.isDeleting) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp))
                    } else {
                        Text("删除", color = MaterialTheme.colorScheme.error)
                    }
                }
            },
            dismissButton = {
                TextButton(onClick = viewModel::dismissDeleteConfirm) {
                    Text("取消")
                }
            }
        )
    }

    // Transcript preview dialog
    if (uiState.showTranscriptPreview) {
        val transcriptText = uiState.transcriptPreviewText
        AlertDialog(
            onDismissRequest = viewModel::dismissTranscriptPreview,
            title = { Text("转写内容") },
            text = {
                val scrollState = rememberScrollState()
                SelectionContainer {
                    Box {
                        Column(
                            modifier = Modifier
                                .verticalScroll(scrollState)
                                .padding(end = 10.dp)
                        ) {
                            Text(
                                transcriptText.ifBlank { "转写内容为空" },
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                        if (scrollState.maxValue > 0) {
                            val onSurface = MaterialTheme.colorScheme.onSurface
                            Canvas(
                                modifier = Modifier
                                    .align(Alignment.CenterEnd)
                                    .fillMaxHeight()
                                    .width(4.dp)
                            ) {
                                val viewportHeight = size.height
                                val totalHeight = viewportHeight + scrollState.maxValue
                                val thumbHeight = viewportHeight / totalHeight * viewportHeight
                                val scrollFraction =
                                    scrollState.value.toFloat() / scrollState.maxValue.toFloat()
                                val thumbOffset =
                                    scrollFraction * (viewportHeight - thumbHeight)
                                drawRoundRect(
                                    color = onSurface.copy(alpha = 0.35f),
                                    topLeft = Offset(0f, thumbOffset),
                                    size = Size(size.width, thumbHeight),
                                    cornerRadius = CornerRadius(2.dp.toPx())
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = viewModel::dismissTranscriptPreview) {
                    Text("关闭")
                }
            }
        )
    }
}

// MARK: - Tab 0: Audio

@Composable
private fun AudioTab(
    record: VoiceRecord,
    playbackState: PlaybackState,
    playbackProgress: Float,
    playbackPositionFormatted: String,
    playbackDurationFormatted: String,
    onPlayPause: () -> Unit,
    onSeek: (Float) -> Unit,
    onSkipBack: () -> Unit,
    onSkipForward: () -> Unit,
    onShare: () -> Unit
) {
    val timeFormatter = DateTimeFormatter.ofPattern("yyyy/MM/dd HH:mm:ss").withZone(ZoneId.systemDefault())

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Basic info card
        Card(shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(record.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                if (record.memo.isNotBlank()) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(record.memo, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f))
                }
                Spacer(modifier = Modifier.height(8.dp))
                InfoRow("开始", timeFormatter.format(record.startTime))
                record.endTime?.let {
                    Spacer(modifier = Modifier.height(2.dp))
                    InfoRow("结束", timeFormatter.format(it))
                }
                val duration = record.endTime?.let { it.toEpochMilli() - record.startTime.toEpochMilli() }
                if (duration != null && duration > 0) {
                    Spacer(modifier = Modifier.height(2.dp))
                    InfoRow("时长", formatDurationSec(duration / 1000))
                }
                Spacer(modifier = Modifier.height(2.dp))
                InfoRow("描述", record.description.ifBlank { "-" })
                if (record.speakers.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(2.dp))
                    InfoRow("说话人", record.speakers.joinToString("、"))
                }
            }
        }

        // Audio player
        if (record.audioFilePath.isNotBlank()) {
            Text("录音回放", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Card(shape = RoundedCornerShape(12.dp)) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Slider(
                        value = playbackProgress,
                        onValueChange = onSeek,
                        enabled = playbackState != PlaybackState.IDLE,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            if (playbackState != PlaybackState.IDLE) playbackPositionFormatted else "00:00",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                        )
                        Text(playbackDurationFormatted, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
                    }
                    Spacer(modifier = Modifier.height(8.dp))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = onSkipBack, modifier = Modifier.size(40.dp)) {
                            Icon(Icons.Default.SkipPrevious, contentDescription = "后退15秒", modifier = Modifier.size(28.dp))
                        }

                        IconButton(
                            onClick = onPlayPause,
                            modifier = Modifier.size(52.dp)
                        ) {
                            Icon(
                                imageVector = if (playbackState == PlaybackState.PLAYING) Icons.Default.Pause else Icons.Default.PlayArrow,
                                contentDescription = if (playbackState == PlaybackState.PLAYING) "暂停" else "播放",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(36.dp)
                            )
                        }

                        IconButton(onClick = onSkipForward, modifier = Modifier.size(40.dp)) {
                            Icon(Icons.Default.SkipNext, contentDescription = "前进15秒", modifier = Modifier.size(28.dp))
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End
                    ) {
                        IconButton(onClick = onShare) {
                            Icon(Icons.Default.Share, contentDescription = "分享录音")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tab 1: Transcript

@Composable
private fun TranscriptTab(
    record: VoiceRecord,
    isRetrying: Boolean,
    retryProgress: String,
    onRetry: () -> Unit,
    onCancel: () -> Unit,
    onShareTranscript: () -> Unit,
    onPreview: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        when (record.transcriptStatus) {
            com.voicenote.app.domain.model.ProcessingStatus.PENDING -> {
                val statusMsg by com.voicenote.app.core.service.RecordingService.statusMessage.collectAsState()
                val isRec by com.voicenote.app.core.service.RecordingService.isRecording.collectAsState()
                Box(modifier = Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (isRec && statusMsg.isNotBlank()) {
                            Text(statusMsg, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
                        } else {
                            Text("转写准备中...", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
                        }
                    }
                }
            }
            com.voicenote.app.domain.model.ProcessingStatus.PROCESSING -> {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            retryProgress.ifBlank { "正在转写..." },
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                        )
                    }
                    TextButton(onClick = onCancel) {
                        Text("取消", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
            com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE -> {
                Box(modifier = Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("转写失败", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
                        Text(
                            "服务暂时不可用，请重试",
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }
            }
            com.voicenote.app.domain.model.ProcessingStatus.COMPLETED -> {
                // File card — tap to preview full text
                if (record.transcriptFilePath.isNotBlank()) {
                    val fileName = File(record.transcriptFilePath).name
                    Card(
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth().clickable { onPreview() }
                    ) {
                        Row(
                            modifier = Modifier.padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                Icons.Default.CheckCircle,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(20.dp)
                            )
                            Spacer(modifier = Modifier.width(10.dp))
                            Text(
                                fileName,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            Icon(
                                Icons.Default.ChevronRight,
                                contentDescription = "查看内容",
                                tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.3f)
                            )
                        }
                    }
                } else {
                    Box(modifier = Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                        Text("转写内容为空", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
                    }
                }
            }
        }

        // Retry + Export buttons
        if (record.transcriptStatus == com.voicenote.app.domain.model.ProcessingStatus.COMPLETED
            || record.transcriptStatus == com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE
        ) {
            HorizontalDivider()
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center
            ) {
                TextButton(onClick = onRetry, enabled = !isRetrying) {
                    if (isRetrying) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("重试中...")
                    } else {
                        Icon(Icons.Default.Replay, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("重新转写")
                    }
                }

                if (record.transcriptFilePath.isNotBlank() && File(record.transcriptFilePath).exists()) {
                    Spacer(modifier = Modifier.width(16.dp))
                    TextButton(onClick = onShareTranscript) {
                        Icon(Icons.Default.Share, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("导出")
                    }
                }
            }
        }
    }
}

// MARK: - Shared components

@Composable
private fun InfoRow(label: String, value: String) {
    Row {
        Text("$label: ", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}

private fun formatDurationSec(seconds: Long): String {
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    val s = seconds % 60
    return if (h > 0) "%d时%02d分%02d秒".format(h, m, s) else "%02d分%02d秒".format(m, s)
}
