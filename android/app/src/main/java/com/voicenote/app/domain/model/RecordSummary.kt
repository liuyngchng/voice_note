package com.voicenote.app.domain.model

import java.util.UUID

/**
 * AI 生成的总结（在线 LLM API）
 * 对齐 iOS: RecordSummary
 */
data class RecordSummary(
    val topics: List<String> = emptyList(),
    val conclusions: List<String> = emptyList(),
    val todos: List<TodoItem> = emptyList(),
    val nextSteps: List<String> = emptyList()
)

/**
 * 待办事项
 * 对齐 iOS: TodoItem
 */
data class TodoItem(
    val id: String = UUID.randomUUID().toString(),
    val task: String = "",
    val owner: String = "",
    val deadline: String = ""
)
