import Foundation
import UIKit
import os

/// 离线 ASR 客户端 — 通过 sherpa-onnx C API 调用 SenseVoice 模型
/// 模型在 app 启动时加载，直到 app 关闭才释放
/// 关于 kCFRunLoopCommonModes 警告:
/// onnxruntime 内部线程池在创建线程时可能调用 CFRunLoopRunSpecific，
/// 并以 kCFRunLoopCommonModes（模式集合，非可运行模式）作为参数。
/// 这是 onnxruntime 的已知行为，不影响功能。
/// 本客户端将 num_threads 设为 1，避免创建线程池，从而规避该警告。
final class OfflineASRClient {
    private let inferenceQueue = DispatchQueue(label: "com.voicenote.offline-asr", qos: .utility)
    private var recognizer: OpaquePointer?
    private var currentQuality: ModelQuality?
    private var isInitialized = false
    private var initError: String?

    // MARK: - VAD state
    private var vad: OpaquePointer?
    private var vadReady = false

    deinit {
        reset()
    }

    // MARK: - 初始化

    func ensureRecognizer(quality: ModelQuality) throws {
        if isInitialized, currentQuality == quality { return }
        if isInitialized { reset() }

        guard ASRModelManager.isModelDownloaded(quality) else {
            let msg = "离线模型未下载 (\(quality.rawValue))，请先在设置中下载"
            initError = msg
            throw OfflineASRError.modelNotDownloaded(quality)
        }

        let modelSize = ASRModelManager.downloadedModelSize(quality)
        guard modelSize > 1_000_000 else {
            let msg = "模型文件异常 (\(modelSize) bytes)，请重新下载"
            initError = msg
            throw OfflineASRError.modelCorrupted(msg)
        }

        do {
            try initRecognizer(quality: quality)
            isInitialized = true
            currentQuality = quality
            initError = nil
            Log.asr("离线 ASR 初始化完成: \(quality.rawValue) (\(modelSize / 1_048_576)MB)")
        } catch {
            initError = error.localizedDescription
            throw error
        }
    }

    private func initRecognizer(quality: ModelQuality) throws {
        let modelPath = ASRModelManager.modelFilePath(quality).path
        let tokensPath = ASRModelManager.tokensFilePath().path

        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: tokensPath)
        else {
            throw OfflineASRError.modelNotDownloaded(quality)
        }

        var config = SherpaOnnxOfflineRecognizerConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80

        let modelStr = strdup(modelPath)!
        let langStr = strdup("auto")!
        let tokensStr = strdup(tokensPath)!
        let providerStr = strdup("cpu")!
        let decodeStr = strdup("greedy_search")!

        defer {
            free(modelStr)
            free(langStr)
            free(tokensStr)
            free(providerStr)
            free(decodeStr)
        }

        config.model_config.sense_voice.model = UnsafePointer(modelStr)
        config.model_config.sense_voice.language = UnsafePointer(langStr)
        config.model_config.sense_voice.use_itn = 1

        config.model_config.tokens = UnsafePointer(tokensStr)
        config.model_config.num_threads = 1
        config.model_config.provider = UnsafePointer(providerStr)
        config.model_config.debug = 0

        config.decoding_method = UnsafePointer(decodeStr)

        guard let rec = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw OfflineASRError.notInitialized("创建 SenseVoice 识别器失败")
        }
        recognizer = rec
    }

    // MARK: - 推理

    func processPCMChunk(pcmData: Data) async -> Result<String, Error> {
        guard isInitialized, let rec = recognizer else {
            return .failure(OfflineASRError.notInitialized(initError ?? "未知错误"))
        }

        return await withCheckedContinuation { continuation in
            inferenceQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(OfflineASRError.clientDeallocated))
                    return
                }
                do {
                    let floats = self.convertPCMToFloats(pcmData)
                    let text = try self.runInference(recognizer: rec, samples: floats)
                    continuation.resume(returning: .success(text))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    private func runInference(recognizer rec: OpaquePointer, samples: [Float]) throws -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(rec) else {
            throw OfflineASRError.notInitialized("创建离线流失败")
        }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, buffer.baseAddress, Int32(buffer.count))
        }

        SherpaOnnxDecodeOfflineStream(rec, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            SherpaOnnxDestroyOfflineStream(stream)
            throw OfflineASRError.notInitialized("获取识别结果失败")
        }

        let text = String(cString: result.pointee.text)

        SherpaOnnxDestroyOfflineRecognizerResult(result)
        SherpaOnnxDestroyOfflineStream(stream)

        return text
    }

    // MARK: - 音频转换

    private func convertPCMToFloats(_ pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        return pcmData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16s = ptr.bindMemory(to: Int16.self)
            var floats = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                floats[i] = Float(int16s[i]) / 32768.0
            }
            return floats
        }
    }

    // MARK: - VAD (语音活动检测)

    /// 初始化 VAD，对标 Android 端 silero_vad.onnx
    /// 返回 true 表示 VAD 就绪; false 表示 VAD 不可用，应回退到按时间分块
    func ensureVad() -> Bool {
        if vadReady { return true }

        // 确保 VAD 模型文件可用（从 Bundle 拷贝到 Documents）
        ASRModelManager.ensureVadModelAvailable()

        let vadPath = ASRModelManager.vadModelFilePath().path
        guard FileManager.default.fileExists(atPath: vadPath) else {
            Log.asr("VAD model not found at \(vadPath)")
            return false
        }

        var config = SherpaOnnxVadModelConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxVadModelConfig>.size)

        let modelStr = strdup(vadPath)!
        let providerStr = strdup("cpu")!
        defer {
            free(modelStr)
            free(providerStr)
        }

        config.silero_vad.model = UnsafePointer(modelStr)
        config.silero_vad.threshold = 0.5
        config.silero_vad.min_silence_duration = 0.5
        config.silero_vad.min_speech_duration = 0.25
        config.silero_vad.window_size = 512
        config.silero_vad.max_speech_duration = 20.0

        config.sample_rate = 16000
        config.num_threads = 1
        config.provider = UnsafePointer(providerStr)
        config.debug = 0

        // buffer_size_in_seconds: 30 秒滑动窗口
        guard let v = SherpaOnnxCreateVoiceActivityDetector(&config, 30.0) else {
            Log.asr("VAD 创建失败")
            return false
        }
        vad = v
        vadReady = true
        Log.asr("VAD 初始化完成 (silero_vad)")
        return true
    }

    /// 将音频采样送入 VAD
    func vadAcceptWaveform(samples: [Float]) {
        guard vadReady, let vad else { return }
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress, Int32(buf.count))
        }
    }

    /// 异步版: 将 VAD accept 派发到 inferenceQueue，避免阻塞调用线程（MainActor）
    func vadAcceptWaveformAsync(samples: [Float]) async {
        guard vadReady, vad != nil else { return }
        let sampleCount = Int32(samples.count)
        await withCheckedContinuation { continuation in
            inferenceQueue.async {
                guard let vad = self.vad else {
                    continuation.resume()
                    return
                }
                samples.withUnsafeBufferPointer { buf in
                    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress, sampleCount)
                }
                continuation.resume()
            }
        }
    }

    /// VAD 是否有已完成的语音段
    var vadHasSpeechSegment: Bool {
        guard vadReady, let vad else { return false }
        return SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0
    }

    /// 消费所有已检测到的语音段，逐个通过 ASR 推理
    /// 返回识别结果列表（在 inference queue 上执行，线程安全）
    func vadDecodeSpeechSegments() async -> [String] {
        guard vadReady, let vad, isInitialized, let rec = recognizer else { return [] }

        return await withCheckedContinuation { continuation in
            inferenceQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                var results: [String] = []
                while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                    guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
                    defer {
                        SherpaOnnxDestroySpeechSegment(segment)
                        SherpaOnnxVoiceActivityDetectorPop(vad)
                    }

                    let sampleCount = Int(segment.pointee.n)
                    guard sampleCount > 0 else { continue }
                    let samples = Array(UnsafeBufferPointer(start: segment.pointee.samples, count: sampleCount))

                    // 过短语音段跳过（< 0.5s = 8000 samples @16kHz）
                    guard sampleCount >= 8000 else {
                        Log.asrDebug("VAD 跳过过短语音段: \(sampleCount) samples")
                        continue
                    }

                    do {
                        let text = try self.runInference(recognizer: rec, samples: samples)
                        if !text.isEmpty {
                            results.append(text)
                            Log.asr("VAD 语音段识别完成: \"\(text.prefix(40))...\"")
                        }
                    } catch {
                        Log.asr("VAD 语音段识别失败: \(error.localizedDescription)")
                    }
                }
                continuation.resume(returning: results)
            }
        }
    }

    /// VAD 是否正在检测到语音
    var vadIsDetected: Bool {
        guard vadReady, let vad else { return false }
        return SherpaOnnxVoiceActivityDetectorDetected(vad) == 1
    }

    /// Flush VAD 尾部数据，强制输出最后的语音段
    func vadFlush() {
        guard vadReady, let vad else { return }
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        Log.asr("VAD flush 完成")
    }

    /// 异步版: 派发到 inferenceQueue，与 vadDecodeSpeechSegments 串行化
    func vadFlushAsync() async {
        guard vadReady, vad != nil else { return }
        await withCheckedContinuation { continuation in
            inferenceQueue.async {
                guard let vad = self.vad else {
                    continuation.resume()
                    return
                }
                SherpaOnnxVoiceActivityDetectorFlush(vad)
                Log.asr("VAD flush 完成")
                continuation.resume()
            }
        }
    }

    // MARK: - 生命周期

    /// 仅在 app 退出时调用（deinit），不在录音之间释放
    func reset() {
        inferenceQueue.sync {
            if let rec = recognizer {
                SherpaOnnxDestroyOfflineRecognizer(rec)
                recognizer = nil
            }
            isInitialized = false
            currentQuality = nil
        }

        // 销毁 VAD
        if let vad {
            SherpaOnnxDestroyVoiceActivityDetector(vad)
            self.vad = nil
            vadReady = false
            Log.asr("VAD 已销毁")
        }

        Log.asr("离线 ASR 模型已释放（app 退出）")
    }

    var isAvailable: Bool { isInitialized }
    var loadedQuality: ModelQuality? { currentQuality }
}

// MARK: - 错误

enum OfflineASRError: LocalizedError {
    case modelNotDownloaded(ModelQuality)
    case modelCorrupted(String)
    case notInitialized(String)
    case clientDeallocated

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let q):
            return "模型未下载 (\(q.rawValue))，请先在设置中下载"
        case .modelCorrupted(let msg):
            return msg
        case .notInitialized(let msg):
            return "识别器未初始化: \(msg)"
        case .clientDeallocated:
            return "识别器已释放"
        }
    }
}
