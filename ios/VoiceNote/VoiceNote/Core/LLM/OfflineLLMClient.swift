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
        let systemPrompt = "你是一个专业的语音笔记助手，负责总结转写文本。请严格从转写文本中提取信息，以 JSON 格式返回。"

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
                        maxTokens: 1024,
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
                    Log.llm("[离线] 解析成功: topics=\(summary.topics.count), conclusions=\(summary.conclusions.count), todos=\(summary.todos.count)")
                    continuation.resume(returning: .success(summary))
                } catch {
                    Log.llm("[离线] 解析失败: \(error.localizedDescription)")
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - JSON 解析（复用 LLMClient 策略）

    /// iOS 14 兼容: 用 NSRegularExpression 提取第一个 JSON 对象
    private func firstJSONObject(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\{[^}]*\\}") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return String(text[Range(match.range, in: text)!])
    }

    private func parseSummary(from text: String) throws -> RecordSummary {
        let jsonText: String
        if let jsonMatch = firstJSONObject(in: text) {
            jsonText = jsonMatch
        } else if text.contains("{") {
            jsonText = text
        } else {
            return RecordSummary(
                topics: [],
                conclusions: [text],
                todos: [],
                nextSteps: []
            )
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw LLMError.parseFailed("无法编码响应文本")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let decoded = try decoder.decode(LLMSummaryResponse.self, from: data)
            return RecordSummary(
                topics: decoded.topics ?? [],
                conclusions: decoded.conclusions ?? [],
                todos: (decoded.todos ?? []).map {
                    TodoItem(task: $0.task ?? "", owner: $0.owner ?? "", deadline: $0.deadline ?? "")
                },
                nextSteps: decoded.nextSteps ?? []
            )
        } catch {
            throw LLMError.parseFailed(error.localizedDescription)
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
    你是一个语音笔记整理助手。请从以下转写文本中提取信息，仅输出 JSON：

    {"topics": ["议题1"], "conclusions": ["结论1"], "todos": [{"task":"事项","owner":"人","deadline":"时间"}], "nextSteps": ["步骤1"]}

    示例：
    输入："今天讨论了产品发布计划，决定6月上线。张三负责后端开发，下周五完成。"
    输出：{"topics":["产品发布计划"],"conclusions":["6月上线"],"todos":[{"task":"后端开发","owner":"张三","deadline":"下周五"}],"nextSteps":["推进开发进度"]}

    现在处理以下文本，只输出 JSON：
    """
}

// MARK: - 解析辅助类型 (与 LLMClient 中的 LLMSummaryResponse 一致)

private struct LLMSummaryResponse: Codable {
    let topics: [String]?
    let conclusions: [String]?
    let todos: [LLMTodoItem]?
    let nextSteps: [String]?
}

private struct LLMTodoItem: Codable {
    let task: String?
    let owner: String?
    let deadline: String?
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
