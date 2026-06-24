package com.voicenote.app.ui.recording

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.voicenote.app.core.audio.AudioImporter
import com.voicenote.app.core.di.SettingsDataStore
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@EntryPoint
@InstallIn(SingletonComponent::class)
interface RecordingEntryPoint {
    fun audioImporter(): AudioImporter
    fun settingsDataStore(): SettingsDataStore
}

private val RecordingRed = Color(0xFFD32F2F)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordingScreen(
    onBack: () -> Unit,
    onRecordComplete: (Long) -> Unit,
    viewModel: RecordingViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var isImporting by remember { mutableStateOf(false) }

    val entryPoint = remember {
        EntryPointAccessors.fromApplication(context.applicationContext, RecordingEntryPoint::class.java)
    }
    val audioImporter = remember { entryPoint.audioImporter() }
    val settingsDataStore = remember { entryPoint.settingsDataStore() }

    val filePickerLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri != null) {
            isImporting = true
            scope.launch {
                val settings = settingsDataStore.settingsFlow.first()
                withContext(Dispatchers.IO) {
                    audioImporter.importAudio(uri, settings)
                }.onSuccess { recordId ->
                    withContext(Dispatchers.Main) {
                        isImporting = false
                        onRecordComplete(recordId)
                    }
                }.onFailure {
                    isImporting = false
                }
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (uiState.isRecording) "录音中" else "新建录音") },
                navigationIcon = {
                    IconButton(onClick = {
                        if (uiState.isRecording) viewModel.stopRecording()
                        onBack()
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = if (uiState.isRecording) RecordingRed else MaterialTheme.colorScheme.primary,
                    titleContentColor = Color.White,
                    navigationIconContentColor = Color.White
                )
            )
        }
    ) { padding ->
        if (!uiState.isRecording) {
            PreRecordingForm(
                uiState = uiState,
                isImporting = isImporting,
                onTitleChange = viewModel::updateTitle,
                onMemoChange = viewModel::updateMemo,
                onSpeakersChange = viewModel::updateSpeakers,
                onStartRecording = { viewModel.startRecording() },
                onImportAudio = { filePickerLauncher.launch(arrayOf("audio/*")) },
                modifier = Modifier.padding(padding)
            )
        } else {
            RecordingContent(
                uiState = uiState,
                onStopRecording = viewModel::stopRecording,
                modifier = Modifier.padding(padding)
            )
        }

        LaunchedEffect(uiState.isRecording, uiState.isStopping) {
            if (!uiState.isRecording && !uiState.isStopping && uiState.currentRecordId > 0) {
                onRecordComplete(uiState.currentRecordId)
            }
        }
    }
}

// MARK: - Pre-recording form

@Composable
private fun PreRecordingForm(
    uiState: RecordingUiState,
    isImporting: Boolean,
    onTitleChange: (String) -> Unit,
    onMemoChange: (String) -> Unit,
    onSpeakersChange: (String) -> Unit,
    onStartRecording: () -> Unit,
    onImportAudio: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        ElevatedCard(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp)
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                Text(
                    "录音信息",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(modifier = Modifier.height(16.dp))

                OutlinedTextField(
                    value = uiState.title,
                    onValueChange = onTitleChange,
                    label = { Text("标题") },
                    placeholder = { Text("录音名称（可选）") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp)
                )
                Spacer(modifier = Modifier.height(10.dp))
                OutlinedTextField(
                    value = uiState.memo,
                    onValueChange = onMemoChange,
                    label = { Text("备注") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp)
                )
                Spacer(modifier = Modifier.height(10.dp))
                OutlinedTextField(
                    value = uiState.speakers,
                    onValueChange = onSpeakersChange,
                    label = { Text("说话人（逗号分隔）") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp)
                )
            }
        }

        uiState.error?.let { error ->
            Text(
                error,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(start = 4.dp)
            )
        }

        Spacer(modifier = Modifier.height(8.dp))

        Button(
            onClick = onStartRecording,
            modifier = Modifier.fillMaxWidth().height(52.dp),
            enabled = !uiState.isStarting && !isImporting,
            shape = RoundedCornerShape(14.dp)
        ) {
            if (uiState.isStarting) {
                CircularProgressIndicator(
                    modifier = Modifier.size(22.dp),
                    color = MaterialTheme.colorScheme.onPrimary,
                    strokeWidth = 2.dp
                )
            } else {
                Icon(Icons.Default.Mic, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(modifier = Modifier.width(8.dp))
                Text("开始录音", style = MaterialTheme.typography.titleSmall)
            }
        }

        OutlinedButton(
            onClick = onImportAudio,
            enabled = !isImporting && !uiState.isStarting,
            modifier = Modifier.fillMaxWidth().height(48.dp),
            shape = RoundedCornerShape(14.dp)
        ) {
            if (isImporting) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text("导入中...")
            } else {
                Icon(Icons.Default.FileOpen, contentDescription = "导入音频", modifier = Modifier.size(20.dp))
                Spacer(modifier = Modifier.width(8.dp))
                Text("导入音频")
            }
        }
    }
}

// MARK: - Recording in progress

@Composable
private fun RecordingContent(
    uiState: RecordingUiState,
    onStopRecording: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxSize()) {
        // Recording indicator — pulsing red dot + duration
        RecordingIndicator(durationSeconds = uiState.durationSeconds)

        // Title / memo metadata
        if (uiState.title.isNotBlank()) {
            Text(
                uiState.title,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
            )
        }

        // Transcript area
        Text(
            "实时转写",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
            modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp)
        )

        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
        ) {
            val scrollState = rememberScrollState()

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(scrollState)
                    .padding(4.dp)
            ) {
                if (uiState.transcript.isBlank()) {
                    Text(
                        "语音识别结果将在此显示",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.25f),
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 80.dp)
                    )
                } else {
                    Text(
                        uiState.transcript,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.85f)
                    )
                }
            }

            LaunchedEffect(uiState.transcript) {
                scrollState.animateScrollTo(scrollState.maxValue)
            }
        }

        // Stop button
        Box(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 24.dp),
            contentAlignment = Alignment.Center
        ) {
            Button(
                onClick = onStopRecording,
                enabled = !uiState.isStopping,
                colors = ButtonDefaults.buttonColors(containerColor = RecordingRed),
                shape = RoundedCornerShape(26.dp),
                modifier = Modifier.fillMaxWidth().height(52.dp)
            ) {
                if (uiState.isStopping) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        color = Color.White,
                        strokeWidth = 2.dp
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("正在生成总结...", color = Color.White)
                } else {
                    Icon(Icons.Default.Stop, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("结束录音", style = MaterialTheme.typography.titleSmall, color = Color.White)
                }
            }
        }
    }
}

// MARK: - Recording indicator with pulsing dot

@Composable
private fun RecordingIndicator(durationSeconds: Long) {
    val infiniteTransition = rememberInfiniteTransition(label = "dotPulse")
    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 1.0f,
        targetValue = 2.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "pulseScale"
    )
    val pulseAlpha by infiniteTransition.animateFloat(
        initialValue = 0.4f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "pulseAlpha"
    )

    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(12.dp),
        shape = RoundedCornerShape(14.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Pulsing red dot (iOS Voice Memos style)
            Box(
                modifier = Modifier.size(22.dp),
                contentAlignment = Alignment.Center
            ) {
                // Pulse ring
                Box(
                    modifier = Modifier
                        .size(14.dp)
                        .scale(pulseScale)
                        .alpha(pulseAlpha)
                        .clip(CircleShape)
                        .background(RecordingRed)
                )
                // Solid dot
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(RecordingRed)
                )
            }
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                "录音中",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
                color = RecordingRed
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                formatDuration(durationSeconds),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )
        }
    }
}

private fun formatDuration(seconds: Long): String {
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    val s = seconds % 60
    return if (h > 0) "%02d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}
