package com.smartbadge.app.domain.model

data class VisitSummary(
    val topics: List<String> = emptyList(),
    val conclusions: List<String> = emptyList(),
    val todos: List<TodoItem> = emptyList(),
    val nextSteps: String = ""
)

data class TodoItem(
    val task: String,
    val owner: String = "",
    val deadline: String = ""
)
