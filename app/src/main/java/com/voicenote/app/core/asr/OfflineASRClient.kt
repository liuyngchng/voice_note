package com.voicenote.app.core.asr

import android.util.Log
import com.voicenote.app.core.common.MemoryWarningBus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

enum class ModelStatus { UNKNOWN, MISSING, LOADING, READY, ERROR }

@Singleton
class OfflineASRClient @Inject constructor(
    private val asrModelManager: ASRModelManager
) {
    private val scope = CoroutineScope(Dispatchers.IO)
    private val stateLock = Mutex()
    private var isInitialized = false
    private var currentQuality: ModelQuality? = null
    private var isInferring = false
    private var shouldReleaseAfterInference = false
    private var recognizerPtr: Long = 0

    // ── VAD state ────────────────────────────────────────────────────────────
    private var vadPtr: Long = 0
    private var vadReady = false

    // ── Model status (observable by UI) ─────────────────────────────────────
    private val _modelStatus = MutableStateFlow(ModelStatus.UNKNOWN)
    val modelStatus: StateFlow<ModelStatus> = _modelStatus.asStateFlow()

    init {
        scope.launch {
            MemoryWarningBus.events.collect { level ->
                handleMemoryWarning(level)
            }
        }
    }

    // ── Recognizer ───────────────────────────────────────────────────────────

    @Synchronized
    fun ensureRecognizer(quality: ModelQuality) {
        if (isInitialized && currentQuality == quality) return
        if (isInitialized) reset()

        check(isNativeAvailable) { "sherpa-onnx 原生库未加载，无法使用离线 ASR" }

        val modelFile = File(asrModelManager.modelFilePath(quality))
        val tokensFile = File(asrModelManager.tokensFilePath())

        Log.i(TAG, "ensureRecognizer: quality=${quality.name}, model=${modelFile.absolutePath} exists=${modelFile.exists()} size=${modelFile.length()}, tokens=${tokensFile.absolutePath} exists=${tokensFile.exists()}")

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
        val modelPath = asrModelManager.modelFilePath(quality)
        val tokensPath = asrModelManager.tokensFilePath()

        recognizerPtr = nativeCreateRecognizer(modelPath, tokensPath)
        check(recognizerPtr != 0L) { "创建 SenseVoice 识别器失败" }
    }

    suspend fun processPCMChunk(pcmData: ByteArray): Result<String> {
        val floats = convertPCMToFloats(pcmData)
        return processFloats(floats)
    }

    /** Decode float samples directly, bypassing byte-to-float conversion. */
    suspend fun processFloats(samples: FloatArray): Result<String> {
        stateLock.withLock {
            check(isInitialized && recognizerPtr != 0L) { "识别器未初始化" }
            isInferring = true
        }

        return try {
            val text = nativeRecognize(recognizerPtr, samples)
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

    // ── Voice Activity Detection ─────────────────────────────────────────────

    /** Returns true if VAD was successfully initialized. */
    fun ensureVad(): Boolean {
        if (vadReady) return true
        if (!isNativeAvailable) return false

        val vadModelPath = asrModelManager.vadModelFilePath()
        val vadModelFile = File(vadModelPath)

        if (!vadModelFile.exists()) {
            Log.w(TAG, "VAD 模型未下载，跳过语音活动检测")
            return false
        }

        try {
            vadPtr = nativeCreateVad(vadModelPath)
            if (vadPtr == 0L) return false
        } catch (e: Exception) {
            Log.e(TAG, "创建 VAD 检测器失败: ${e.message}")
            return false
        }

        vadReady = true
        Log.i(TAG, "VAD 初始化完成")
        return true
    }

    /** Feed raw PCM-16 audio to the VAD for speech detection. */
    fun vadAcceptPCM(pcmData: ByteArray) {
        if (!vadReady || vadPtr == 0L) return
        val floats = convertPCMToFloats(pcmData)
        nativeVadAcceptWaveform(vadPtr, floats, floats.size)
    }

    /** Feed audio samples to the VAD for speech detection. */
    fun vadAcceptWaveform(samples: FloatArray) {
        if (!vadReady || vadPtr == 0L) return
        nativeVadAcceptWaveform(vadPtr, samples, samples.size)
    }

    /** Whether the VAD has completed speech segments ready for decoding. */
    fun vadHasSpeechSegment(): Boolean {
        if (!vadReady || vadPtr == 0L) return false
        return !nativeVadEmpty(vadPtr)
    }

    /** Pull and decode all completed speech segments from the VAD. */
    suspend fun vadDecodeSpeechSegments(): List<String> {
        if (!vadReady || vadPtr == 0L) return emptyList()

        val results = mutableListOf<String>()
        while (!nativeVadEmpty(vadPtr)) {
            val segment = nativeVadFront(vadPtr)
            if (segment != null && segment.isNotEmpty()) {
                val result = processFloats(segment)
                result.onSuccess { text ->
                    if (text.isNotBlank()) results.add(text)
                }
            }
            nativeVadPop(vadPtr)
        }
        return results
    }

    /**
     * Feed silence to the VAD to force completion of any in-progress speech segment.
     * Call this when audio capture stops to avoid losing the tail of speech.
     */
    fun vadFlush() {
        if (!vadReady || vadPtr == 0L) return
        // VAD min_silence_duration is 0.5s at 16000 Hz → 8000 samples. Feed 0.6s for margin.
        val silenceSamples = 16000 * 0.6f
        val silence = FloatArray(silenceSamples.toInt()) // all zeros
        nativeVadAcceptWaveform(vadPtr, silence, silence.size)
        Log.i(TAG, "VAD flushed with ${silence.size} silence samples")
    }

    /** Whether the VAD is currently detecting speech. */
    fun vadIsDetected(): Boolean {
        if (!vadReady || vadPtr == 0L) return false
        return nativeVadIsDetected(vadPtr)
    }

    // ── Offline Punctuation Restoration ──────────────────────────────────────

    private var punctPtr: Long = 0
    private var punctReady = false

    /** Returns true if punctuation model was successfully loaded. */
    fun ensurePunctuation(): Boolean {
        if (punctReady) return true
        if (!isNativeAvailable) return false

        val punctModelPath = asrModelManager.punctuationModelFilePath()
        val punctModelFile = File(punctModelPath)

        if (!punctModelFile.exists()) {
            Log.w(TAG, "标点模型未下载，跳过标点恢复")
            return false
        }

        try {
            punctPtr = nativeCreatePunctuation(punctModelPath)
            if (punctPtr == 0L) return false
        } catch (e: Exception) {
            Log.e(TAG, "创建标点处理器失败: ${e.message}")
            return false
        }

        punctReady = true
        Log.i(TAG, "标点处理器初始化完成")
        return true
    }

    /** Add punctuation to a complete text. Returns punctuated text. */
    fun addPunctuation(text: String): String {
        if (!punctReady || punctPtr == 0L || text.isBlank()) return text

        return try {
            val result = nativeAddPunctuation(punctPtr, text)
            result ?: text
        } catch (e: Exception) {
            Log.w(TAG, "标点恢复失败: ${e.message}")
            text
        }
    }

    private fun destroyPunctuation() {
        if (punctPtr != 0L) {
            nativeDestroyPunctuation(punctPtr)
            punctPtr = 0
            punctReady = false
            Log.i(TAG, "标点处理器已释放")
        }
    }

    private fun destroyVad() {
        if (vadPtr != 0L) {
            nativeDestroyVad(vadPtr)
            vadPtr = 0
            vadReady = false
            Log.i(TAG, "VAD 已释放")
        }
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    @Synchronized
    fun reset() {
        if (recognizerPtr != 0L) {
            nativeDestroyRecognizer(recognizerPtr)
            recognizerPtr = 0
            isInitialized = false
            currentQuality = null
            _modelStatus.value = ModelStatus.UNKNOWN
            Log.i(TAG, "离线 ASR 模型已释放")
        }
        destroyVad()
        destroyPunctuation()
    }

    val isAvailable: Boolean get() = isInitialized

    /** Check model files and preload into memory. Idempotent — no-op if already loaded. */
    fun preloadIfAvailable(quality: ModelQuality) {
        if (isInitialized && currentQuality == quality) {
            _modelStatus.value = ModelStatus.READY
            return
        }

        val modelFile = File(asrModelManager.modelFilePath(quality))
        val tokensFile = File(asrModelManager.tokensFilePath())

        if (!modelFile.exists() || !tokensFile.exists()) {
            _modelStatus.value = ModelStatus.MISSING
            Log.i(TAG, "Model files not found for ${quality.name}, needs download")
            return
        }

        _modelStatus.value = ModelStatus.LOADING
        scope.launch {
            try {
                ensureRecognizer(quality)
                asrModelManager.ensureVadModelAvailable()
                ensureVad()
                ensurePunctuation()
                _modelStatus.value = ModelStatus.READY
                Log.i(TAG, "Preload complete: ${quality.name}")
            } catch (e: Exception) {
                Log.e(TAG, "Preload failed: ${e.message}", e)
                _modelStatus.value = ModelStatus.ERROR
            }
        }
    }

    fun refreshModelStatus(quality: ModelQuality) {
        if (isInitialized && currentQuality == quality) {
            _modelStatus.value = ModelStatus.READY
            return
        }
        val modelFile = File(asrModelManager.modelFilePath(quality))
        val tokensFile = File(asrModelManager.tokensFilePath())
        _modelStatus.value = if (modelFile.exists() && tokensFile.exists()) ModelStatus.READY
            else ModelStatus.MISSING
    }

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
                System.loadLibrary("onnxruntime")
            } catch (_: UnsatisfiedLinkError) {
                Log.w(TAG, "onnxruntime native library not available")
            }
            try {
                System.loadLibrary("sherpa-onnx-c-api")
            } catch (_: UnsatisfiedLinkError) {
                Log.w(TAG, "sherpa-onnx native library not available")
            }
            try {
                System.loadLibrary("sherpa_onnx_jni")
                isNativeAvailable = true
                Log.i(TAG, "sherpa-onnx JNI bridge loaded successfully")
            } catch (_: UnsatisfiedLinkError) {
                Log.w(TAG, "sherpa-onnx JNI bridge not available — offline ASR disabled")
            }
        }
    }

    // ── Native declarations ──────────────────────────────────────────────────

    private external fun nativeCreateRecognizer(modelPath: String, tokensPath: String): Long
    private external fun nativeRecognize(recognizerPtr: Long, samples: FloatArray): String?
    private external fun nativeDestroyRecognizer(recognizerPtr: Long)

    private external fun nativeCreateVad(modelPath: String): Long
    private external fun nativeDestroyVad(vadPtr: Long)
    private external fun nativeVadAcceptWaveform(vadPtr: Long, samples: FloatArray, n: Int)
    private external fun nativeVadEmpty(vadPtr: Long): Boolean
    private external fun nativeVadFront(vadPtr: Long): FloatArray?
    private external fun nativeVadPop(vadPtr: Long)
    private external fun nativeVadIsDetected(vadPtr: Long): Boolean

    private external fun nativeCreatePunctuation(modelPath: String): Long
    private external fun nativeAddPunctuation(punctPtr: Long, text: String): String?
    private external fun nativeDestroyPunctuation(punctPtr: Long)
}
