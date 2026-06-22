package com.voicenote.app.ui.detail

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Topic
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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
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

    LaunchedEffect(recordId) {
        viewModel.loadRecord(recordId)
    }

    // Navigate back when deleted
    LaunchedEffect(uiState.isDeleted) {
        if (uiState.isDeleted) {
            onBack()
        }
    }

    // Release MediaPlayer when leaving the screen
    DisposableEffect(Unit) {
        onDispose {
            viewModel.releasePlayer()
        }
    }

    // Show error as snackbar
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
                VoiceRecordDetailContent(
                    record = uiState.record!!,
                    playbackState = uiState.playbackState,
                    playbackProgress = uiState.playbackProgress,
                    playbackPositionFormatted = uiState.playbackPositionFormatted,
                    playbackDurationFormatted = uiState.playbackDurationFormatted,
                    aiSummaryExpanded = uiState.aiSummaryExpanded,
                    onPlayPause = viewModel::playPause,
                    onSeek = viewModel::seekTo,
                    onShare = viewModel::shareAudio,
                    onDelete = viewModel::showDeleteConfirm,
                    onTranscriptClick = viewModel::openTranscriptPreview,
                    onToggleAiSummary = viewModel::toggleAiSummary,
                    modifier = Modifier.padding(padding)
                )
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
        val record = uiState.record
        val text = record?.transcriptText ?: ""
        val status = record?.transcriptStatus ?: com.voicenote.app.domain.model.ProcessingStatus.PENDING
        AlertDialog(
            onDismissRequest = viewModel::dismissTranscriptPreview,
            title = { Text("录音文本") },
            text = {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                ) {
                    when (status) {
                        com.voicenote.app.domain.model.ProcessingStatus.PENDING -> {
                            StatusPlaceholder("转录尚未开始")
                        }
                        com.voicenote.app.domain.model.ProcessingStatus.PROCESSING -> {
                            StatusProcessing("转录处理中...")
                        }
                        com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE -> {
                            StatusPlaceholder("服务暂时不可用，请采用离线方式")
                        }
                        com.voicenote.app.domain.model.ProcessingStatus.COMPLETED -> {
                            if (text.isBlank()) {
                                StatusPlaceholder("无有效信息")
                            } else {
                                Text(text, style = MaterialTheme.typography.bodyMedium)
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

@Composable
private fun VoiceRecordDetailContent(
    record: VoiceRecord,
    playbackState: PlaybackState,
    playbackProgress: Float,
    playbackPositionFormatted: String,
    playbackDurationFormatted: String,
    aiSummaryExpanded: Boolean,
    onPlayPause: () -> Unit,
    onSeek: (Float) -> Unit,
    onShare: () -> Unit,
    onDelete: () -> Unit,
    onTranscriptClick: () -> Unit,
    onToggleAiSummary: () -> Unit,
    modifier: Modifier = Modifier
) {
    val timeFormatter = DateTimeFormatter.ofPattern("yyyy/MM/dd HH:mm:ss").withZone(ZoneId.systemDefault())

    Column(
        modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Basic info
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
                Spacer(modifier = Modifier.height(2.dp))
                InfoRow("描述", record.description.ifBlank { "-" })
                if (record.speakers.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(2.dp))
                    InfoRow("说话人", record.speakers.joinToString("、"))
                }
            }
        }

        // Audio recording (always show if file exists)
        if (record.audioFilePath.isNotBlank()) {
            AudioPlayerSection(
                playbackState = playbackState,
                playbackProgress = playbackProgress,
                playbackPositionFormatted = playbackPositionFormatted,
                playbackDurationFormatted = playbackDurationFormatted,
                onPlayPause = onPlayPause,
                onSeek = onSeek,
                onShare = onShare,
                onDelete = onDelete
            )
        }

        // Transcript section
        Text("录音文本", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)

        TranscriptCard(
            record = record,
            onClick = onTranscriptClick
        )

        // AI Summary section
        val summary = record.summary
        val hasSummaryContent = summary != null && (
            summary.topics.isNotEmpty() || summary.conclusions.isNotEmpty() ||
            summary.todos.isNotEmpty() || summary.nextSteps.isNotBlank()
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggleAiSummary),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("AI 总结", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.weight(1f))
            Icon(
                imageVector = if (aiSummaryExpanded) Icons.Default.ExpandLess else Icons.Default.ArrowDropDown,
                contentDescription = if (aiSummaryExpanded) "收起" else "展开",
                tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
            )
        }

        AnimatedVisibility(
            visible = aiSummaryExpanded,
            enter = expandVertically(),
            exit = shrinkVertically()
        ) {
            Card(
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.3f)
                )
            ) {
                when (record.summaryStatus) {
                    com.voicenote.app.domain.model.ProcessingStatus.PENDING -> {
                        StatusPlaceholder("AI 总结尚未开始")
                    }
                    com.voicenote.app.domain.model.ProcessingStatus.PROCESSING -> {
                        StatusProcessing("AI 总结处理中...")
                    }
                    com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE -> {
                        StatusPlaceholder("服务不可用，无法生成总结")
                    }
                    com.voicenote.app.domain.model.ProcessingStatus.COMPLETED -> {
                        if (hasSummaryContent) {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                if (summary!!.topics.isNotEmpty()) {
                                    SectionHeader(Icons.Default.Topic, "会谈议题")
                                    summary.topics.forEach { topic ->
                                        Text("• $topic", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 8.dp))
                                    }
                                }

                                if (summary.conclusions.isNotEmpty()) {
                                    HorizontalDivider()
                                    SectionHeader(Icons.Default.CheckCircle, "关键结论")
                                    summary.conclusions.forEach { conclusion ->
                                        Text("• $conclusion", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 8.dp))
                                    }
                                }

                                if (summary.todos.isNotEmpty()) {
                                    HorizontalDivider()
                                    SectionHeader(Icons.Default.ChevronRight, "待办事项")
                                    summary.todos.forEach { todo ->
                                        Row(modifier = Modifier.padding(start = 8.dp)) {
                                            Text("• ${todo.task}", style = MaterialTheme.typography.bodyMedium)
                                            if (todo.owner.isNotBlank()) {
                                                Text(" (@${todo.owner})", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                                            }
                                            if (todo.deadline.isNotBlank()) {
                                                Text(" ${todo.deadline}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                                            }
                                        }
                                    }
                                }

                                if (summary.nextSteps.isNotBlank()) {
                                    HorizontalDivider()
                                    SectionHeader(Icons.Default.Lightbulb, "下一步计划")
                                    Text(summary.nextSteps, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 8.dp))
                                }
                            }
                        } else {
                            StatusPlaceholder("无有效信息")
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(32.dp))
    }
}

@Composable
private fun AudioPlayerSection(
    playbackState: PlaybackState,
    playbackProgress: Float,
    playbackPositionFormatted: String,
    playbackDurationFormatted: String,
    onPlayPause: () -> Unit,
    onSeek: (Float) -> Unit,
    onShare: () -> Unit,
    onDelete: () -> Unit
) {
    Text("录音", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)

    Card(shape = RoundedCornerShape(12.dp)) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.MusicNote, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Spacer(modifier = Modifier.width(8.dp))
                Text("录音文件", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Play/Pause button + seek bar + time
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(
                    onClick = onPlayPause,
                    modifier = Modifier.size(40.dp)
                ) {
                    Icon(
                        imageVector = if (playbackState == PlaybackState.PLAYING) Icons.Default.Pause else Icons.Default.PlayArrow,
                        contentDescription = if (playbackState == PlaybackState.PLAYING) "暂停" else "播放",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(24.dp)
                    )
                }

                Text(
                    playbackPositionFormatted,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.width(36.dp)
                )

                Slider(
                    value = playbackProgress,
                    onValueChange = onSeek,
                    modifier = Modifier.weight(1f).padding(horizontal = 4.dp),
                    enabled = playbackState != PlaybackState.IDLE
                )

                Text(
                    playbackDurationFormatted,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.width(36.dp)
                )
            }

            // Share & Delete buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End
            ) {
                IconButton(onClick = onShare) {
                    Icon(Icons.Default.Share, contentDescription = "分享")
                }
                IconButton(onClick = onDelete) {
                    Icon(
                        Icons.Default.Delete,
                        contentDescription = "删除",
                        tint = MaterialTheme.colorScheme.error
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(end = 4.dp))
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun TranscriptCard(
    record: VoiceRecord,
    onClick: () -> Unit
) {
    val fileName = if (record.transcriptFilePath.isNotBlank()) {
        File(record.transcriptFilePath).name
    } else {
        "录音文本.txt"
    }

    val subtitle = when (record.transcriptStatus) {
        com.voicenote.app.domain.model.ProcessingStatus.PENDING -> "转录尚未开始"
        com.voicenote.app.domain.model.ProcessingStatus.PROCESSING -> "转录处理中..."
        com.voicenote.app.domain.model.ProcessingStatus.UNAVAILABLE -> "服务暂时不可用，请采用离线方式"
        com.voicenote.app.domain.model.ProcessingStatus.COMPLETED -> "点击查看全文"
    }

    val enabled = record.transcriptStatus == com.voicenote.app.domain.model.ProcessingStatus.COMPLETED

    Card(
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.clickable(enabled = enabled, onClick = onClick)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (record.transcriptStatus == com.voicenote.app.domain.model.ProcessingStatus.PROCESSING) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp
                )
            } else {
                Icon(
                    Icons.Default.Description,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    fileName,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                )
            }
            Icon(
                Icons.Default.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.3f)
            )
        }
    }
}

@Composable
private fun StatusPlaceholder(text: String) {
    Box(
        modifier = Modifier.fillMaxWidth().padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
        )
    }
}

@Composable
private fun StatusProcessing(text: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(24.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            strokeWidth = 2.dp
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
        )
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row {
        Text("$label: ", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}