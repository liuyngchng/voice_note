package com.voicenote.app.core.common

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

object MemoryWarningBus {
    private val _events = MutableSharedFlow<Int>(replay = 0, extraBufferCapacity = 4)
    val events: SharedFlow<Int> = _events.asSharedFlow()

    fun dispatch(level: Int) {
        _events.tryEmit(level)
    }
}
