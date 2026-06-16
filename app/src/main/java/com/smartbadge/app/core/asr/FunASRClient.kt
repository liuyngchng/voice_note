package com.smartbadge.app.core.asr

import com.google.gson.Gson
import com.google.gson.JsonObject
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.Channel.Factory.UNLIMITED
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

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

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    fun connect(serverUrl: String): Flow<AsrEvent> {
        val request = Request.Builder().url(serverUrl).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                eventChannel.trySend(AsrEvent.Connected)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val json = gson.fromJson(text, JsonObject::class.java)
                    val mode = json.get("mode")?.asString ?: ""
                    val resultText = json.get("text")?.asString ?: ""
                    val isFinal = json.get("is_final")?.asBoolean ?: false

                    if (resultText.isNotBlank()) {
                        if (isFinal) {
                            eventChannel.trySend(AsrEvent.Final(resultText))
                        } else {
                            eventChannel.trySend(AsrEvent.Partial(resultText, false))
                        }
                    }
                } catch (_: Exception) {
                    // ignore parse errors
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
                eventChannel.trySend(AsrEvent.Disconnected)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                eventChannel.trySend(AsrEvent.Disconnected)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                eventChannel.trySend(AsrEvent.Error(t.message ?: "WebSocket error"))
            }
        })
        return eventChannel.receiveAsFlow()
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
        try {
            webSocket?.close(1000, "user stop")
        } catch (_: Exception) {}
        webSocket = null
    }
}
