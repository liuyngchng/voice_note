package com.voicenote.app.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.remember
import com.voicenote.app.BuildConfig
import com.voicenote.app.core.asr.ModelDownloadManager
import com.voicenote.app.core.llm.LLMModelManager
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface SettingsEntryPoint {
    fun modelDownloadManager(): ModelDownloadManager
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
    val downloadManager = remember { entryPoint.modelDownloadManager() }
    val llmModelManager = remember { entryPoint.llmModelManager() }
    var keyVisible by remember { mutableStateOf(false) }

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
                    containerColor = MaterialTheme.colorScheme.primary,
                    titleContentColor = MaterialTheme.colorScheme.onPrimary,
                    navigationIconContentColor = MaterialTheme.colorScheme.onPrimary
                )
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState())
        ) {
            // FunASR Settings
            SectionTitle("语音识别 (FunASR)")
            ScrollableOutlinedField(
                value = uiState.asrUrl,
                onValueChange = viewModel::updateAsrUrl,
                label = "WebSocket 地址",
                hint = "ws://192.168.1.100:10095",
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(24.dp))

            // LLM Settings
            SectionTitle("AI 总结 (OpenAI 兼容)")
            ScrollableOutlinedField(
                value = uiState.llmUrl,
                onValueChange = viewModel::updateLlmUrl,
                label = "API 地址",
                hint = "https://api.deepseek.com",
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(modifier = Modifier.height(8.dp))
            ScrollableOutlinedField(
                value = uiState.llmKey,
                onValueChange = viewModel::updateLlmKey,
                label = "API Key",
                modifier = Modifier.fillMaxWidth(),
                visualTransformation = if (keyVisible) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { keyVisible = !keyVisible }) {
                        Icon(
                            imageVector = if (keyVisible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                            contentDescription = if (keyVisible) "隐藏 API Key" else "显示 API Key"
                        )
                    }
                }
            )
            Spacer(modifier = Modifier.height(8.dp))
            OutlinedTextField(
                value = uiState.llmModel,
                onValueChange = viewModel::updateLlmModel,
                label = { Text("模型") },
                placeholder = { Text("gpt-4o-mini") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                shape = RoundedCornerShape(8.dp)
            )
            Spacer(modifier = Modifier.height(8.dp))
            OutlinedTextField(
                value = uiState.llmPrompt,
                onValueChange = viewModel::updateLlmPrompt,
                label = { Text("自定义 Prompt（可选）") },
                placeholder = { Text("留空使用默认 Prompt") },
                modifier = Modifier.fillMaxWidth().height(120.dp),
                maxLines = 6,
                shape = RoundedCornerShape(8.dp)
            )

            Spacer(modifier = Modifier.height(24.dp))

            // ASR Mode Switch (online/offline)
            HorizontalDivider()
            Spacer(modifier = Modifier.height(16.dp))
            OfflineASRSettingsView(
                asrMode = uiState.asrMode,
                modelQuality = uiState.offlineModelQuality,
                onAsrModeChange = viewModel::updateAsrMode,
                onModelQualityChange = viewModel::updateOfflineModelQuality,
                downloadManager = downloadManager
            )

            Spacer(modifier = Modifier.height(24.dp))

            // LLM Mode Switch (online/offline)
            HorizontalDivider()
            Spacer(modifier = Modifier.height(16.dp))
            OfflineLLMSettingsView(
                llmMode = uiState.llmMode,
                llmModelInfo = uiState.llmModelInfo,
                onLlmModeChange = viewModel::updateLlmMode,
                onLlmModelInfoChange = viewModel::updateLlmModelInfo,
                modelManager = llmModelManager
            )

            Spacer(modifier = Modifier.height(24.dp))

            // Save & Test button
            Button(
                onClick = viewModel::saveAndTest,
                modifier = Modifier.fillMaxWidth().height(48.dp),
                enabled = !uiState.isTesting,
                shape = RoundedCornerShape(12.dp)
            ) {
                if (uiState.isTesting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        color = MaterialTheme.colorScheme.onPrimary,
                        strokeWidth = 2.dp
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("正在测试连接...")
                } else {
                    Text("保存")
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Version
            Text(
                text = "版本: ${BuildConfig.BUILD_TIMESTAMP}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center
            )
        }
    }

    // Test results dialog
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
                                    tint = if (result.success) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
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

@Composable
private fun SectionTitle(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(bottom = 8.dp)
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScrollableOutlinedField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    hint: String = "",
    visualTransformation: VisualTransformation = VisualTransformation.None,
    trailingIcon: @Composable (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    var textFieldValue by remember { mutableStateOf(TextFieldValue(value, TextRange(value.length))) }

    LaunchedEffect(value) {
        if (value != textFieldValue.text) {
            textFieldValue = TextFieldValue(value, TextRange(textFieldValue.selection.start.coerceAtMost(value.length)))
        }
    }

    BasicTextField(
        value = textFieldValue,
        onValueChange = {
            textFieldValue = it
            onValueChange(it.text)
        },
        singleLine = true,
        visualTransformation = visualTransformation,
        modifier = modifier,
        decorationBox = { innerTextField ->
            OutlinedTextFieldDefaults.DecorationBox(
                value = value,
                innerTextField = innerTextField,
                enabled = true,
                singleLine = true,
                visualTransformation = visualTransformation,
                interactionSource = remember { MutableInteractionSource() },
                label = { Text(label) },
                placeholder = if (hint.isNotBlank()) { @Composable { Text(hint) } } else null,
                trailingIcon = trailingIcon ?: @Composable {},
                colors = OutlinedTextFieldDefaults.colors(),
                contentPadding = OutlinedTextFieldDefaults.contentPadding()
            )
        }
    )
}