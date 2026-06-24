package com.voicenote.app.ui.settings

import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.voicenote.app.BuildConfig
import com.voicenote.app.core.asr.ASRModelManager
import com.voicenote.app.core.llm.LLMModelManager
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface SettingsEntryPoint {
    fun asrModelManager(): ASRModelManager
    fun llmModelManager(): LLMModelManager
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val context = LocalContext.current
    val entryPoint = remember {
        EntryPointAccessors.fromApplication(context.applicationContext, SettingsEntryPoint::class.java)
    }
    val asrModelManager = remember { entryPoint.asrModelManager() }
    val llmModelManager = remember { entryPoint.llmModelManager() }
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(uiState.saveCount) {
        if (uiState.saveCount > 0) {
            snackbarHostState.showSnackbar(viewModel.buildSaveSummary())
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                    titleContentColor = MaterialTheme.colorScheme.onSurface
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
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {

            // ═══ ASR Settings Card ═══
            ElevatedCard(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp)
            ) {
                Column(modifier = Modifier.padding(20.dp)) {
                    OfflineASRSettingsView(
                        asrMode = uiState.asrMode,
                        asrUrl = uiState.asrUrl,
                        modelQuality = uiState.offlineModelQuality,
                        onAsrModeChange = viewModel::updateAsrMode,
                        onAsrUrlChange = viewModel::updateAsrUrl,
                        onModelQualityChange = viewModel::updateOfflineModelQuality,
                        asrModelManager = asrModelManager
                    )
                }
            }

            // ═══ LLM Settings Card ═══
            ElevatedCard(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp)
            ) {
                Column(modifier = Modifier.padding(20.dp)) {
                    OfflineLLMSettingsView(
                        llmMode = uiState.llmMode,
                        llmUrl = uiState.llmUrl,
                        llmKey = uiState.llmKey,
                        llmModel = uiState.llmModel,
                        llmModelInfo = uiState.llmModelInfo,
                        onLlmModeChange = viewModel::updateLlmMode,
                        onLlmUrlChange = viewModel::updateLlmUrl,
                        onLlmKeyChange = viewModel::updateLlmKey,
                        onLlmModelChange = viewModel::updateLlmModel,
                        onLlmModelInfoChange = viewModel::updateLlmModelInfo,
                        modelManager = llmModelManager
                    )
                }
            }

            // ═══ Actions ═══
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                // Save
                Button(
                    onClick = viewModel::save,
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                    shape = RoundedCornerShape(14.dp)
                ) {
                    Text("保存", style = MaterialTheme.typography.titleSmall)
                }

                // Test connection
                if (uiState.asrMode == "online" || uiState.llmMode == "online") {
                    Button(
                        onClick = viewModel::testConnection,
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                        enabled = !uiState.isTesting,
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.secondaryContainer,
                            contentColor = MaterialTheme.colorScheme.onSecondaryContainer
                        )
                    ) {
                        if (uiState.isTesting) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.dp
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("测试中...")
                        } else {
                            Text("测试连接")
                        }
                    }
                }
            }

            // ═══ Version ═══
            Text(
                text = "版本 ${BuildConfig.BUILD_TIMESTAMP}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.35f),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 16.dp),
                textAlign = TextAlign.Center
            )
        }
    }

    // ── Test results dialog ────────────────────────────────────────────────
    if (uiState.showResults) {
        AlertDialog(
            onDismissRequest = viewModel::dismissResults,
            title = { Text("连接测试结果") },
            text = {
                SelectionContainer {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        uiState.testResults.forEach { result ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    imageVector = if (result.success) Icons.Default.Check else Icons.Default.Close,
                                    contentDescription = null,
                                    tint = if (result.success) MaterialTheme.colorScheme.primary
                                            else MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(20.dp)
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Column {
                                    Text(
                                        result.name,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Bold
                                    )
                                    Text(
                                        result.message,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f)
                                    )
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = viewModel::dismissResults) {
                    Text("确定")
                }
            }
        )
    }
}
