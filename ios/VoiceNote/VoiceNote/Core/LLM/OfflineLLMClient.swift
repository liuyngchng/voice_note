import Foundation
import UIKit
import os

/// 离线 LLM 客户端 — 通过 LlamaBridge (llama.cpp) 调用本地 GGUF 模型
/// 提供与 LLMClient 兼容的 generateSummary 接口
///
/// 与 OfflineASRClient 模式完全对齐：
/// - 推理队列串行化
/// - 按需加载/卸载模型
/// - 内存警告监听 + 延迟释放
final class OfflineLLMClient {
    private let inferenceQueue = DispatchQueue(label: "com.voicenote.offline-llm", qos: .utility)
    private let bridge = LlamaBridge()

    private var currentModelInfo: LLMModelInfo?
    private var isInitialized = false
    private var initError: String?

    // MARK: - 内存警告管理

    private var memoryObserver: NSObjectProtocol?
    /// 使用 os_unfair_lock 替代 NSLock，避免 Swift concurrency 的 Sendable 警告
    private var stateLock = os_unfair_lock()
    private var isInferring = false
    private var shouldReleaseAfterInference = false

    deinit {
        if let observer = memoryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        reset()
    }

    // MARK: - 初始化

    func ensureModel(_ modelInfo: LLMModelInfo) throws {
        if isInitialized && currentModelInfo == modelInfo { return }
        if isInitialized { reset() }

        guard LLMModelManager.isModelDownloaded(modelInfo) else {
            let msg = "离线 LLM 模型未下载 (\(modelInfo.displayName))，请先在设置中下载"
            initError = msg
            throw OfflineLLMError.modelNotDownloaded(modelInfo)
        }

        let modelPath = LLMModelManager.modelFilePath(modelInfo).path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            let msg = "模型文件不存在 (\(modelInfo.modelFilename))"
            initError = msg
            throw OfflineLLMError.modelNotDownloaded(modelInfo)
        }

        // 低内存设备使用 CPU only，避免 Metal GPU 内存压力
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let isLowMemory = physicalMemory < 3 * 1024 * 1024 * 1024  // < 3GB
        let gpuLayers: Int32 = isLowMemory ? 0 : 99
        let ctxLen: Int32 = 2048

        if isLowMemory {
            Log.llm("低内存设备 (\(physicalMemory / 1_048_576)MB)，使用 CPU-only 推理")
        } else {
            Log.llm("GPU offload: \(gpuLayers) layers")
        }

        // ObjC NSError** 在 Swift 侧自动转为 throws
        do {
            try bridge.loadModel(modelPath, gpuLayers: gpuLayers, contextLength: ctxLen)
        } catch {
            let msg = error.localizedDescription
            initError = msg
            Log.llm("[离线] 模型加载失败: \(msg)")
            throw OfflineLLMError.modelLoadFailed(msg)
        }

        isInitialized = true
        currentModelInfo = modelInfo
        initError = nil
        setupMemoryObserver()
        Log.llm("[离线] 模型就绪: \(modelInfo.rawValue), gpuLayers=\(gpuLayers)")
    }

    // MARK: - 推理

    func generateSummary(
        transcript: String,
        modelInfo: LLMModelInfo,
        customPrompt: String?
    ) async -> Result<RecordSummary, Error> {
        do {
            try ensureModel(modelInfo)
        } catch {
            return .failure(error)
        }

        os_unfair_lock_lock(&stateLock)
        isInferring = true
        os_unfair_lock_unlock(&stateLock)

        defer {
            var shouldRelease = false
            os_unfair_lock_lock(&stateLock)
            isInferring = false
            shouldRelease = shouldReleaseAfterInference
            shouldReleaseAfterInference = false
            os_unfair_lock_unlock(&stateLock)
            if shouldRelease {
                Log.llm("[离线] 推理完成，执行延迟的模型释放")
                reset()
            }
        }

        let prompt = customPrompt?.isEmpty == false ? customPrompt! : offlineDefaultPrompt
        let systemPrompt = "你是一个语音笔记助手，负责用简洁的文字总结转写文本。"

        return await withCheckedContinuation { continuation in
            inferenceQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(OfflineLLMError.clientDeallocated))
                    return
                }

                // ObjC NSError** → Swift throws
                let rawOutput: String?
                do {
                    rawOutput = try self.bridge.generate(
                        withPrompt: transcript,
                        systemPrompt: systemPrompt,
                        maxTokens: 512,
                        temperature: 0.3
                    )
                } catch {
                    Log.llm("[离线] 推理失败: \(error.localizedDescription)")
                    continuation.resume(returning: .failure(
                        OfflineLLMError.inferenceFailed(error.localizedDescription)))
                    return
                }

                guard let output = rawOutput, !output.isEmpty else {
                    Log.llm("[离线] 推理返回空结果")
                    continuation.resume(returning: .failure(OfflineLLMError.emptyResponse))
                    return
                }

                Log.llm("[离线] 推理完成: \(output.count) chars")
                Log.llm("[离线] 原始输出:\n\(output)")
                do {
                    let summary = try self.parseSummary(from: output)
                    Log.llm("[离线] 解析完成: \(summary.conclusions.first?.count ?? 0) 字符")
                    continuation.resume(returning: .success(summary))
                } catch {
                    Log.llm("[离线] 解析失败: \(error.localizedDescription)")
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - 生命周期

    func reset() {
        inferenceQueue.sync {
            bridge.unloadModel()
            isInitialized = false
            currentModelInfo = nil
        }
        Log.llm("[离线] LLM 模型已释放")
    }

    var isAvailable: Bool { isInitialized }
    var loadedModelInfo: LLMModelInfo? { currentModelInfo }

    // MARK: - 内存警告

    private func setupMemoryObserver() {
        if let existing = memoryObserver {
            NotificationCenter.default.removeObserver(existing)
            memoryObserver = nil
        }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            os_unfair_lock_lock(&self.stateLock)
            let inferring = self.isInferring
            if inferring {
                self.shouldReleaseAfterInference = true
            }
            os_unfair_lock_unlock(&self.stateLock)

            if inferring {
                Log.llm("[离线] 收到内存警告，推理进行中 — 将在完成后释放模型")
            } else {
                Log.llm("[离线] 收到内存警告，释放 LLM 模型")
                self.reset()
            }
        }
    }

    // MARK: - Prompt

    private let offlineDefaultPrompt = """
    你是一个语音笔记整理助手。请用一段简洁的文字总结以下转写文本，提取关键信息：

    总结应包含：
    - 讨论的主要议题
    - 得出的结论或决定
    - 待办事项和负责人（如有）

    直接输出总结文本，不要输出 JSON。

    转写文本：
    """

    // MARK: - 解析（离线模式：纯文本 → 作为结论）

    private func parseSummary(from text: String) throws -> RecordSummary {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OfflineLLMError.emptyResponse
        }
        return RecordSummary(
            topics: [],
            conclusions: [trimmed],
            todos: [],
            nextSteps: []
        )
    }
}

// MARK: - 错误

enum OfflineLLMError: LocalizedError {
    case modelNotDownloaded(LLMModelInfo)
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case emptyResponse
    case clientDeallocated

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let info):
            return "模型未下载 (\(info.displayName))，请先在设置中下载"
        case .modelLoadFailed(let msg):
            return "模型加载失败: \(msg)"
        case .inferenceFailed(let msg):
            return "本地推理失败: \(msg)"
        case .emptyResponse:
            return "LLM 返回空结果"
        case .clientDeallocated:
            return "LLM 客户端已释放"
        }
    }
}
