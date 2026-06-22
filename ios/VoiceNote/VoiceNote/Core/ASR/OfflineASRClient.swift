import Foundation
import UIKit
import os

/// 离线 ASR 客户端 — 通过 sherpa-onnx C API 调用 SenseVoice 模型
/// 提供与 FunASRClient 兼容的 processPCMChunk 接口
///
/// 关于 kCFRunLoopCommonModes 警告:
/// onnxruntime 内部线程池在创建线程时可能调用 CFRunLoopRunSpecific，
/// 并以 kCFRunLoopCommonModes（模式集合，非可运行模式）作为参数。
/// 这是 onnxruntime 的已知行为，不影响功能。
/// 本客户端将 num_threads 设为 1，避免创建线程池，从而规避该警告。
///
/// FP32 模型约 886MB，低内存设备可能触发内存警告。
/// 推理进行中收到警告时会延迟释放，确保当前推理能完成。
final class OfflineASRClient {
    private let inferenceQueue = DispatchQueue(label: "com.voicenote.offline-asr", qos: .utility)
    private var recognizer: OpaquePointer?
    private var currentQuality: ModelQuality?
    private var isInitialized = false
    private var initError: String?

    // MARK: - 内存警告管理

    /// Block-based observer 的 token，用于正确移除
    private var memoryObserver: NSObjectProtocol?

    /// 保护 isInferring / shouldReleaseAfterInference 的锁
    private let stateLock = NSLock()
    private var isInferring = false
    private var shouldReleaseAfterInference = false

    deinit {
        if let observer = memoryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        reset()
    }

    // MARK: - 初始化

    func ensureRecognizer(quality: ModelQuality) throws {
        if isInitialized, currentQuality == quality { return }
        if isInitialized { reset() }

        guard ModelDownloadManager.isModelDownloaded(quality) else {
            let msg = "离线模型未下载 (\(quality.rawValue))，请先在设置中下载"
            initError = msg
            throw OfflineASRError.modelNotDownloaded(quality)
        }

        let modelSize = ModelDownloadManager.downloadedModelSize(quality)
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
            setupMemoryObserver()
            Log.asr("离线 ASR 初始化完成: \(quality.rawValue) (\(modelSize / 1_048_576)MB)")
        } catch {
            initError = error.localizedDescription
            throw error
        }
    }

    private func initRecognizer(quality: ModelQuality) throws {
        let modelPath = ModelDownloadManager.modelFilePath(quality).path
        let tokensPath = ModelDownloadManager.tokensFilePath().path

        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: tokensPath)
        else {
            throw OfflineASRError.modelNotDownloaded(quality)
        }

        var config = SherpaOnnxOfflineRecognizerConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80

        // strdup returns UnsafeMutablePointer<CChar> — cast to UnsafePointer for const char* fields
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
        config.model_config.num_threads = 1  // 单线程，避免 onnxruntime 线程池触发 CFRunLoop 警告
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

        stateLock.lock()
        isInferring = true
        stateLock.unlock()

        defer {
            var shouldRelease = false
            stateLock.lock()
            isInferring = false
            shouldRelease = shouldReleaseAfterInference
            shouldReleaseAfterInference = false
            stateLock.unlock()
            if shouldRelease {
                Log.asr("推理完成，执行延迟的模型释放")
                reset()
            }
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

    // MARK: - 生命周期

    func reset() {
        inferenceQueue.sync {
            if let rec = recognizer {
                SherpaOnnxDestroyOfflineRecognizer(rec)
                recognizer = nil
            }
            isInitialized = false
            currentQuality = nil
        }
        Log.asr("离线 ASR 模型已释放")
    }

    var isAvailable: Bool { isInitialized }
    var loadedQuality: ModelQuality? { currentQuality }

    // MARK: - 内存警告

    private func setupMemoryObserver() {
        // 正确移除旧的 block-based observer（必须用 token）
        if let existing = memoryObserver {
            NotificationCenter.default.removeObserver(existing)
            memoryObserver = nil
        }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            self.stateLock.lock()
            let inferring = self.isInferring
            if inferring {
                self.shouldReleaseAfterInference = true
            }
            self.stateLock.unlock()

            if inferring {
                Log.asr("收到内存警告，推理进行中 — 将在完成后释放模型")
            } else {
                Log.asr("收到内存警告，释放离线 ASR 模型")
                self.reset()
            }
        }
    }
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
