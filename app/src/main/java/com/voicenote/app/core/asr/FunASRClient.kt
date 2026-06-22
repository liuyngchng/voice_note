package com.voicenote.app.core.asr

import com.google.gson.Gson
import com.google.gson.JsonObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.Channel.Factory.UNLIMITED
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume

sealed class AsrEvent {
    data class Partial(val text: String, val isFinal: Boolean) : AsrEvent()
    data class Final(val text: String) : AsrEvent()
    data class Error(val message: String) : AsrEvent()
    data object Connected : AsrEvent()
    data object Disconnected : AsrEvent()
}

@Singleton
class FunASRClient @Inject constructor() {

    private var webSocket: WebSocket? = null
    private val gson = Gson()
    private val eventChannel = Channel<AsrEvent>(UNLIMITED)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var serverUrl: String? = null
    private var intentionalDisconnect = false
    private var reconnectAttempt = 0
    private var reconnectJob: kotlinx.coroutines.Job? = null

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    companion object {
        private const val MAX_RECONNECT_ATTEMPTS = 3
        private val RECONNECT_DELAYS = listOf(2000L, 4000L, 8000L)
        private const val OFFLINE_CHUNK_SIZE = 64000
        private const val OFFLINE_CHUNK_DELAY_MS = 5L
    }

    fun connect(serverUrl: String): Flow<AsrEvent> {
        this.serverUrl = serverUrl
        intentionalDisconnect = false
        reconnectAttempt = 0
        openWebSocket(serverUrl)
        return eventChannel.receiveAsFlow()
    }

    private fun openWebSocket(url: String) {
        val request = Request.Builder().url(url).build()
        webSocket = client.newWebSocket(request, createListener())
    }

    private fun createListener() = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            eventChannel.trySend(AsrEvent.Connected)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            try {
                val json = gson.fromJson(text, JsonObject::class.java)
                val resultText = json.get("text")?.asString ?: ""
                val isFinal = json.get("is_final")?.asBoolean ?: false

                if (resultText.isNotBlank()) {
                    if (isFinal) {
                        eventChannel.trySend(AsrEvent.Final(resultText))
                    } else {
                        eventChannel.trySend(AsrEvent.Partial(resultText, false))
                    }
                }
            } catch (_: Exception) {}
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            eventChannel.trySend(AsrEvent.Disconnected)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            eventChannel.trySend(AsrEvent.Disconnected)
            if (!intentionalDisconnect) scheduleReconnect()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            eventChannel.trySend(AsrEvent.Error(t.message ?: "WebSocket error"))
            if (!intentionalDisconnect) scheduleReconnect()
        }
    }

    private fun scheduleReconnect() {
        if (reconnectAttempt >= MAX_RECONNECT_ATTEMPTS) return
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            val url = serverUrl ?: return@launch
            val delay = RECONNECT_DELAYS[reconnectAttempt]
            reconnectAttempt++
            delay(delay)
            try {
                openWebSocket(url)
            } catch (_: Exception) {
                eventChannel.trySend(AsrEvent.Error("ASR reconnection failed after ${reconnectAttempt} attempts"))
            }
        }
    }

    fun sendHandshake(chunkSize: List<Int> = listOf(5, 10, 5)) {
        val handshake = mapOf(
            "mode" to "2pass",
            "chunk_size" to chunkSize,
            "wav_name" to "streaming",
            "is_speaking" to true
        )
        webSocket?.send(gson.toJson(handshake))
    }

    fun sendAudio(data: ByteArray) {
        webSocket?.send(data.toByteString())
    }

    fun sendEnd() {
        val endMsg = mapOf("is_speaking" to false)
        webSocket?.send(gson.toJson(endMsg))
    }

    fun disconnect() {
        intentionalDisconnect = true
        reconnectJob?.cancel()
        try {
            webSocket?.close(1000, "user stop")
        } catch (_: Exception) {}
        webSocket = null
    }

    suspend fun processFile(audioFilePath: String, serverUrl: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            val file = File(audioFilePath)
            if (!file.exists()) return@withContext Result.failure(Exception("Audio file not found: $audioFilePath"))

            val pcmData = file.inputStream().use { input ->
                input.skip(44)
                input.readBytes()
            }
            if (pcmData.isEmpty()) return@withContext Result.failure(Exception("Empty audio data"))

            val fileClient = OkHttpClient.Builder()
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .build()

            suspendCancellableCoroutine<Result<String>> { continuation ->
                val transcript = StringBuilder()
                var ws: WebSocket? = null

                val request = Request.Builder().url(serverUrl).build()
                ws = fileClient.newWebSocket(request, object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        val handshake = mapOf(
                            "mode" to "offline",
                            "wav_name" to file.name,
                            "is_speaking" to true
                        )
                        webSocket.send(gson.toJson(handshake))

                        var offset = 0
                        while (offset < pcmData.size) {
                            val end = minOf(offset + OFFLINE_CHUNK_SIZE, pcmData.size)
                            webSocket.send(pcmData.copyOfRange(offset, end).toByteString())
                            offset = end
                            Thread.sleep(OFFLINE_CHUNK_DELAY_MS)
                        }

                        val endMsg = mapOf("is_speaking" to false)
                        webSocket.send(gson.toJson(endMsg))
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        try {
                            val json = gson.fromJson(text, JsonObject::class.java)
                            val resultText = json.get("text")?.asString ?: ""
                            if (resultText.isNotBlank()) {
                                transcript.append(resultText)
                            }
                        } catch (_: Exception) {}
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        resumeFromWs()
                    }

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        resumeFromWs()
                    }

                    private fun resumeFromWs() {
                        if (continuation.isActive) {
                            if (transcript.isBlank()) {
                                continuation.resume(Result.failure(Exception("No transcript received")))
                            } else {
                                continuation.resume(Result.success(transcript.toString()))
                            }
                        }
                    }
                })

                continuation.invokeOnCancellation {
                    try { ws?.close(1000, "cancelled") } catch (_: Exception) {}
                }
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
