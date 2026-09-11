package com.voicenote.app.ui.detail

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import com.voicenote.app.core.audio.WavParser
import com.voicenote.app.core.common.TimeUtil
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.io.RandomAccessFile

data class PlaybackViewState(
    val state: PlaybackState = PlaybackState.IDLE,
    val progress: Float = 0f,
    val positionFormatted: String = "00:00",
    val durationFormatted: String = "00:00"
)

enum class PlaybackState { IDLE, PLAYING, PAUSED }

/**
 * 音频播放控制器，从 [DetailViewModel] 中抽离。
 * 管理 AudioTrack 生命周期：play/pause/seek/skip。
 */
class PlaybackController(
    private val scope: CoroutineScope
) {
    private val _state = MutableStateFlow(PlaybackViewState())
    val state: StateFlow<PlaybackViewState> = _state.asStateFlow()

    private var audioTrack: AudioTrack? = null
    private var playbackJob: Job? = null
    private var positionUpdateJob: Job? = null
    private var wavInfo: WavParser.WavInfo = WavParser.WavInfo()
    @Volatile private var playbackBaseFrame: Long = 0

    /** 存储当前文件路径，供 seek/skip 时 restartPlayback 使用 */
    private var currentFilePath: String? = null

    fun loadFile(filePath: String?): String {
        currentFilePath = filePath
        if (filePath.isNullOrBlank()) return "00:00"
        val file = File(filePath)
        if (!file.exists()) return "00:00"
        return try {
            wavInfo = WavParser.parse(file)
            val bytesPerSec = wavInfo.sampleRate.toLong() * wavInfo.channels * (wavInfo.bitsPerSample / 8)
            val duration = if (bytesPerSec > 0) TimeUtil.formatDuration(wavInfo.dataSize / bytesPerSec) else "00:00"
            _state.value = _state.value.copy(durationFormatted = duration)
            duration
        } catch (_: Exception) {
            "00:00"
        }
    }

    fun playPause() {
        val path = currentFilePath ?: return
        val file = File(path)
        if (!file.exists()) return

        when (_state.value.state) {
            PlaybackState.IDLE -> {
                wavInfo = WavParser.parse(file)
                if (wavInfo.totalFrames <= 0) return
                playbackBaseFrame = 0
                startPlayback(file)
            }
            PlaybackState.PAUSED -> startPlayback(file)
            PlaybackState.PLAYING -> pause()
        }
    }

    fun seekTo(fraction: Float) {
        playbackBaseFrame = (wavInfo.totalFrames * fraction).toLong().coerceIn(0, wavInfo.totalFrames)
        updatePositionUI()
        if (_state.value.state == PlaybackState.PLAYING) restartPlayback()
    }

    fun skipBack() {
        val frameDelta = (15L * wavInfo.sampleRate)
        playbackBaseFrame = (playbackBaseFrame - frameDelta).coerceAtLeast(0)
        updatePositionUI()
        if (_state.value.state == PlaybackState.PLAYING) restartPlayback()
    }

    fun skipForward() {
        val frameDelta = (15L * wavInfo.sampleRate)
        playbackBaseFrame = (playbackBaseFrame + frameDelta).coerceAtMost(wavInfo.totalFrames)
        updatePositionUI()
        if (_state.value.state == PlaybackState.PLAYING) restartPlayback()
    }

    fun release() {
        positionUpdateJob?.cancel()
        positionUpdateJob = null
        playbackJob?.cancel()
        playbackJob = null
        audioTrack?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        audioTrack = null
        playbackBaseFrame = 0
        _state.value = PlaybackViewState()
    }

    // ── Internals ──────────────────────────────────────

    private fun startPlayback(file: File) {
        playbackJob?.cancel()
        playbackJob = scope.launch {
            _state.value = _state.value.copy(state = PlaybackState.PLAYING)
            startPositionUpdates()
            runAudioPlayback(file)
            if (isActive) {
                _state.value = PlaybackViewState(state = PlaybackState.IDLE)
                playbackBaseFrame = 0
            }
        }
    }

    private fun pause() {
        positionUpdateJob?.cancel()
        positionUpdateJob = null
        playbackJob?.cancel()
        playbackJob = null
        _state.value = _state.value.copy(state = PlaybackState.PAUSED)
    }

    private fun restartPlayback() {
        val path = currentFilePath ?: return
        val file = File(path)
        if (!file.exists()) return
        playbackJob?.cancel()
        playbackJob = null
        audioTrack?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        audioTrack = null
        startPlayback(file)
    }

    private suspend fun runAudioPlayback(file: File) {
        val bytesPerFrame = wavInfo.channels * (wavInfo.bitsPerSample / 8)
        if (bytesPerFrame <= 0 || wavInfo.sampleRate <= 0) return

        val channelConfig = if (wavInfo.channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val encoding = if (wavInfo.bitsPerSample == 8) AudioFormat.ENCODING_PCM_8BIT else AudioFormat.ENCODING_PCM_16BIT

        val minBuf = AudioTrack.getMinBufferSize(wavInfo.sampleRate, channelConfig, encoding)
        val bufferSize = maxOf(minBuf, 4096)

        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(encoding).setSampleRate(wavInfo.sampleRate)
                    .setChannelMask(channelConfig).build())
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create AudioTrack", e)
            return
        }

        audioTrack = track
        try {
            track.play()
            RandomAccessFile(file, "r").use { raf ->
                val startByte = wavInfo.dataOffset + playbackBaseFrame * bytesPerFrame
                raf.seek(startByte)
                val buffer = ByteArray(bufferSize)
                while (currentCoroutineContext().isActive) {
                    val bytesRead = raf.read(buffer)
                    if (bytesRead <= 0) break
                    val written = track.write(buffer, 0, bytesRead)
                    if (written <= 0) break
                }
            }
        } finally {
            playbackBaseFrame += track.playbackHeadPosition.toLong()
            try { track.stop() } catch (_: Exception) {}
            track.release()
            audioTrack = null
        }
    }

    private fun getCurrentFrame(): Long {
        val t = audioTrack
        return if (t != null && t.state == AudioTrack.STATE_INITIALIZED)
            playbackBaseFrame + t.playbackHeadPosition.toLong() else playbackBaseFrame
    }

    private fun frameToSeconds(frames: Long): Long =
        if (wavInfo.sampleRate > 0) frames / wavInfo.sampleRate else 0

    private fun updatePositionUI() {
        val progress = if (wavInfo.totalFrames > 0) playbackBaseFrame.toFloat() / wavInfo.totalFrames.toFloat() else 0f
        _state.value = _state.value.copy(progress = progress, positionFormatted = TimeUtil.formatDuration(frameToSeconds(playbackBaseFrame)))
    }

    private fun startPositionUpdates() {
        positionUpdateJob?.cancel()
        positionUpdateJob = scope.launch {
            while (currentCoroutineContext().isActive) {
                if (_state.value.state == PlaybackState.PLAYING && wavInfo.totalFrames > 0) {
                    val cur = getCurrentFrame()
                    _state.value = _state.value.copy(
                        progress = cur.toFloat() / wavInfo.totalFrames.toFloat(),
                        positionFormatted = TimeUtil.formatDuration(frameToSeconds(cur))
                    )
                }
                delay(250)
            }
        }
    }

    companion object { private const val TAG = "PlaybackController" }
}