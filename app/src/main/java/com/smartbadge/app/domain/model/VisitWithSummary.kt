package com.smartbadge.app.domain.model

data class VisitWithSummary(
    val visit: Visit,
    val summary: VisitSummary?
)
