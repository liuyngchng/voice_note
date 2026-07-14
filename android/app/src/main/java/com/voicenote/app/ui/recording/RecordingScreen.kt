package com.voicenote.app.ui.recording

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import kotlin.math.sqrt

private val RecordingRed = Color(0xFFD32F2F)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordingScreen(
    reconnectRecordId: Long = 0,
    onBack: () -> Unit,
    onRecordComplete: (Long) -> Unit,
    viewModel: RecordingViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }

    // Reconnect to existing recording or start fresh
    LaunchedEffect(Unit) {
        if (reconnectRecordId > 0) {
            viewModel.reconnect(reconnectRecordId)
        } else {
            viewModel.startRecording()
        }
    }

    // Battery optimization check — shown as Snackbar on recording start
    LaunchedEffect(Unit) {
        viewModel.checkBatteryOptimization()
    }
    LaunchedEffect(uiState.showBatteryOptDialog) {
        if (uiState.showBatteryOptDialog) {
            snackbarHostState.showSnackbar("长时间录音需要开启电池优化")
            viewModel.dismissBatteryOptDialog()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("录音中") },
                navigationIcon = {
                    IconButton(onClick = {
                        viewModel.stopRecording()
                        onBack()
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = RecordingRed,
                    titleContentColor = Color.White,
                    navigationIconContentColor = Color.White
                )
            )
        },
        snackbarHost = {
            SnackbarHost(hostState = snackbarHostState) { data ->
                Snackbar(
                    snackbarData = data,
                    containerColor = MaterialTheme.colorScheme.inverseSurface,
                    contentColor = MaterialTheme.colorScheme.inverseOnSurface,
                    shape = RoundedCornerShape(12.dp)
                )
            }
        }
    ) { padding ->
        RecordingContent(
            uiState = uiState,
            onStopRecording = viewModel::stopRecording,
            modifier = Modifier.padding(padding)
        )

        LaunchedEffect(uiState.isRecording, uiState.isStopping) {
            if (!uiState.isRecording && !uiState.isStopping && uiState.currentRecordId > 0) {
                onRecordComplete(uiState.currentRecordId)
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

        // Audio waveform visualization (aligned with iOS AudioWaveformView)
        WaveformView(
            levels = uiState.audioLevelHistory,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
        )

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
                // Status indicator during recording
                if (uiState.statusMessage.isNotBlank()) {
                    Text(
                        uiState.statusMessage,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                        modifier = Modifier.padding(bottom = 8.dp)
                    )
                }

                if (uiState.transcript.isBlank()) {
                    Text(
                        if (uiState.statusMessage.isBlank()) "语音识别结果将在此显示"
                        else "等待语音输入...",
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
                    Text("正在保存...", color = Color.White)
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

// MARK: - Audio waveform visualization

private const val BAR_COUNT = 42
private const val MAX_BAR_HEIGHT_DP = 44f
private const val MIN_BAR_HEIGHT_DP = 4f
private const val BAR_WIDTH_DP = 3f

@Composable
private fun WaveformView(
    levels: List<Float>,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier.height(48.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        for (i in 0 until BAR_COUNT) {
            val historyIndex = levels.size - BAR_COUNT + i
            val rawLevel = if (historyIndex >= 0 && historyIndex < levels.size) {
                maxOf(0.03f, levels[historyIndex])
            } else {
                0.03f // minimum height so waveform is always visible
            }
            WaveformBar(level = rawLevel)
            if (i < BAR_COUNT - 1) {
                Spacer(modifier = Modifier.width(2.dp))
            }
        }
    }
}

@Composable
private fun WaveformBar(level: Float) {
    // Scale with sqrt curve to boost mid/low visual height (matching iOS)
    val boosted = sqrt(maxOf(0f, level))
    val targetHeight = maxOf(MIN_BAR_HEIGHT_DP, boosted * MAX_BAR_HEIGHT_DP)

    // Smooth animation — single per-bar animation using animateFloatAsState
    // is efficient because Compose skips bars whose target hasn't changed
    val animatedHeight by animateFloatAsState(
        targetValue = targetHeight,
        animationSpec = tween(durationMillis = 220),
        label = "barHeight"
    )

    val barColor = when {
        level < 0.25f -> Color(0xFF4CAF50)  // green
        level < 0.50f -> Color(0xFFFFEB3B)  // yellow
        else           -> Color(0xFFF44336)  // red
    }

    Box(
        modifier = Modifier
            .width(BAR_WIDTH_DP.dp)
            .height(animatedHeight.dp)
            .clip(RoundedCornerShape(50))
            .background(barColor)
    )
}

private fun formatDuration(seconds: Long): String {
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    val s = seconds % 60
    return if (h > 0) "%02d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}
