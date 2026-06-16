package com.smartbadge.app.ui.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Topic
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.smartbadge.app.domain.model.Visit
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(
    visitId: Long,
    onBack: () -> Unit,
    viewModel: DetailViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()

    LaunchedEffect(visitId) {
        viewModel.loadVisit(visitId)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("拜访详情") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "返回")
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
            uiState.visit == null -> {
                Box(modifier = Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                    Text("记录未找到", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
                }
            }
            else -> {
                VisitDetailContent(uiState.visit!!, modifier = Modifier.padding(padding))
            }
        }
    }
}

@Composable
private fun VisitDetailContent(visit: Visit, modifier: Modifier = Modifier) {
    val timeFormatter = DateTimeFormatter.ofPattern("yyyy/MM/dd HH:mm:ss").withZone(ZoneId.systemDefault())

    Column(
        modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Basic info
        Card(shape = RoundedCornerShape(12.dp)) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(visit.clientName, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                if (visit.clientCompany.isNotBlank()) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(visit.clientCompany, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f))
                }
                Spacer(modifier = Modifier.height(8.dp))
                InfoRow("开始", timeFormatter.format(visit.startTime))
                visit.endTime?.let {
                    Spacer(modifier = Modifier.height(2.dp))
                    InfoRow("结束", timeFormatter.format(it))
                }
                Spacer(modifier = Modifier.height(2.dp))
                InfoRow("目的", visit.purpose.ifBlank { "-" })
                if (visit.participants.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(2.dp))
                    InfoRow("参与人", visit.participants.joinToString("、"))
                }
            }
        }

        // AI Summary
        visit.summary?.let { summary ->
            if (summary.topics.isNotEmpty() || summary.conclusions.isNotEmpty() ||
                summary.todos.isNotEmpty() || summary.nextSteps.isNotBlank()) {

                Text("AI 总结", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)

                Card(shape = RoundedCornerShape(12.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.3f))) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {

                        if (summary.topics.isNotEmpty()) {
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
                }
            }
        }

        // Full transcript
        if (visit.transcriptText.isNotBlank()) {
            Text("完整转写", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)

            Card(shape = RoundedCornerShape(12.dp)) {
                Text(
                    visit.transcriptText,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(16.dp)
                )
            }
        }

        Spacer(modifier = Modifier.height(32.dp))
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
private fun InfoRow(label: String, value: String) {
    Row {
        Text("$label: ", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}
