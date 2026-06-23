package com.voicenote.app.core.asr

import android.util.Log
import com.voicenote.app.core.common.MemoryWarningBus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OfflineASRClient @Inject constructor(
    private val downloadManager: ModelDownloadManager
) {
    private val scope = CoroutineScope(Dispatchers.IO)
    private val stateLock = Mutex()
    private var isInitialized = false
    private var currentQuality: ModelQuality? = null
    private var isInferring = false
    private var shouldReleaseAfterInference = false
    private var recognizerPtr: Long = 0

    init {
        scope.launch {
            MemoryWarningBus.events.collect { level ->
                handleMemoryWarning(level)
            }
        }
    }

    @Synchronized
    fun ensureRecognizer(quality: ModelQuality) {
        if (isInitialized && currentQuality == quality) return
        if (isInitialized) reset()

        check(isNativeAvailable) { "sherpa-onnx 原生库未加载，无法使用离线 ASR" }

        val modelFile = File(downloadManager.modelFilePath(quality))
        val tokensFile = File(downloadManager.tokensFilePath())

        check(modelFile.exists() && modelFile.length() > 1_000_000) {
            "离线模型未下载 (${quality.name})，请先在设置中下载"
        }
        check(tokensFile.exists()) { "tokens.txt 未找到，请重新下载模型" }

        initRecognizer(quality)
        isInitialized = true
        currentQuality = quality
        Log.i(TAG, "离线 ASR 初始化完成: ${quality.name} (${modelFile.length() / 1_048_576}MB)")
    }

    private fun initRecognizer(quality: ModelQuality) {
        val modelPath = downloadManager.modelFilePath(quality)
        val tokensPath = downloadManager.tokensFilePath()

        recognizerPtr = nativeCreateRecognizer(modelPath, tokensPath)
        check(recognizerPtr != 0L) { "创建 SenseVoice 识别器失败" }
    }

    suspend fun processPCMChunk(pcmData: ByteArray): Result<String> {
        stateLock.withLock {
            check(isInitialized && recognizerPtr != 0L) { "识别器未初始化" }
            isInferring = true
        }

        return try {
            val floats = convertPCMToFloats(pcmData)
            val text = nativeRecognize(recognizerPtr, floats)
            if (text != null) Result.success(text)
            else Result.failure(Exception("识别失败"))
        } catch (e: Exception) {
            Result.failure(e)
        } finally {
            scope.launch {
                stateLock.withLock {
                    isInferring = false
                    if (shouldReleaseAfterInference) {
                        shouldReleaseAfterInference = false
                        Log.i(TAG, "推理完成，执行延迟的模型释放")
                        reset()
                    }
                }
            }
        }
    }

    private fun convertPCMToFloats(pcmData: ByteArray): FloatArray {
        val sampleCount = pcmData.size / 2
        val floats = FloatArray(sampleCount)
        var offset = 0
        for (i in 0 until sampleCount) {
            val sample = ((pcmData[offset + 1].toInt() shl 8) or
                          (pcmData[offset].toInt() and 0xFF)).toShort()
            floats[i] = sample.toFloat() / 32768.0f
            offset += 2
        }
        return floats
    }

    @Synchronized
    fun reset() {
        if (recognizerPtr != 0L) {
            nativeDestroyRecognizer(recognizerPtr)
            recognizerPtr = 0
        }
        isInitialized = false
        currentQuality = null
        Log.i(TAG, "离线 ASR 模型已释放")
    }

    val isAvailable: Boolean get() = isInitialized

    private fun handleMemoryWarning(level: Int) {
        scope.launch {
            stateLock.withLock {
                if (isInferring) {
                    shouldReleaseAfterInference = true
                    Log.i(TAG, "收到内存警告 level=$level，推理进行中 — 将在完成后释放模型")
                } else {
                    Log.i(TAG, "收到内存警告 level=$level，释放离线 ASR 模型")
                    reset()
                }
            }
        }
    }

    companion object {
        private const val TAG = "OfflineASRClient"
        private var isNativeAvailable = false

        init {
            try {
                System.loadLibrary("sherpa_onnx_jni")
                isNativeAvailable = true
            } catch (_: UnsatisfiedLinkError) {
                Log.w(TAG, "sherpa-onnx native library not available")
            }
        }
    }

    private external fun nativeCreateRecognizer(modelPath: String, tokensPath: String): Long
    private external fun nativeRecognize(recognizerPtr: Long, samples: FloatArray): String?
    private external fun nativeDestroyRecognizer(recognizerPtr: Long)
}
