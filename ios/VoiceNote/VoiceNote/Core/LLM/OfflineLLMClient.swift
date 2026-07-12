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
    private var contextLength: Int32 = 2048  // 实际加载的上下文长度

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
        var gpuLayers: Int32 = isLowMemory ? 0 : 99
        var ctxLen: Int32 = 2048

        if isLowMemory {
            Log.llm("低内存设备 (\(physicalMemory / 1_048_576)MB)，使用 CPU-only 推理")
        } else {
            Log.llm("GPU offload: \(gpuLayers) layers")
        }

        // ObjC NSError** 在 Swift 侧自动转为 throws
        // LlamaBridge 内部会先尝试 GPU，Metal 失败时自动回退到 CPU
        do {
            try bridge.loadModel(modelPath, gpuLayers: gpuLayers, contextLength: ctxLen)
        } catch let firstError {
            // GPU→CPU 回退已由 LlamaBridge 内部处理，此处再尝试减小上下文长度
            Log.llm("[离线] 首次加载失败: \(firstError.localizedDescription)")
            Log.llm("[离线] 尝试减小上下文长度 (ctxLen=1024, CPU-only) 重试...")
            gpuLayers = 0
            ctxLen = 1024
            do {
                try bridge.loadModel(modelPath, gpuLayers: gpuLayers, contextLength: ctxLen)
                Log.llm("[离线] 减小上下文长度后加载成功")
            } catch {
                let msg = error.localizedDescription
                initError = msg
                Log.llm("[离线] 模型加载失败: \(msg)")
                throw OfflineLLMError.modelLoadFailed(msg)
            }
        }

        isInitialized = true
        currentModelInfo = modelInfo
        contextLength = ctxLen
        initError = nil
        setupMemoryObserver()
        Log.llm("[离线] 模型就绪: \(modelInfo.rawValue), gpuLayers=\(gpuLayers)")
    }

    // MARK: - 推理

    /// 进度回调（主线程调用）
    typealias ProgressHandler = (String) -> Void

    func generateSummary(
        transcript: String,
        modelInfo: LLMModelInfo,
        customPrompt: String?,
        onProgress: ProgressHandler? = nil
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

        let systemPrompt = "你是一个语音笔记助手，负责用简洁的文字总结转写文本。"
        let instruction = customPrompt?.isEmpty == false ? customPrompt! : offlineDefaultPrompt

        // 安全的分块大小：上下文 40% 用于输入，剩余留给 prompt 模板和输出
        // 中文约 1 字符 ≈ 1-2 token，取保守值 1 字符 = 2 token
        let maxChunkChars = max(200, Int(contextLength) / 2)

        return await withCheckedContinuation { continuation in
            inferenceQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(OfflineLLMError.clientDeallocated))
                    return
                }

                do {
                    let result: RecordSummary
                    if transcript.count <= maxChunkChars {
                        // 短文本：单次推理
                        let userPrompt = instruction + "\n\n转写文本：\n" + transcript
                        Log.llm("[离线] 单次推理: transcript=\(transcript.count) chars, maxChunk=\(maxChunkChars)")
                        let output = try self.infer(userPrompt: userPrompt, systemPrompt: systemPrompt, maxTokens: 512)
                        result = try self.parseSummary(from: output)
                    } else {
                        // 长文本：分批摘要 → 汇总
                        Log.llm("[离线] 长文本分批处理: transcript=\(transcript.count) chars, maxChunk=\(maxChunkChars)")
                        let mergedOutput = try self.multiPassSummarize(
                            transcript: transcript,
                            systemPrompt: systemPrompt,
                            instruction: instruction,
                            maxChunkChars: maxChunkChars,
                            onProgress: onProgress
                        )
                        result = try self.parseSummary(from: mergedOutput)
                    }
                    Log.llm("[离线] 解析完成: \(result.conclusions.first?.count ?? 0) 字符")
                    continuation.resume(returning: .success(result))
                } catch {
                    Log.llm("[离线] 推理失败: \(error.localizedDescription)")
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - 核心推理方法

    /// 执行一次推理（用户 prompt + 系统 prompt），返回生成文本
    private func infer(userPrompt: String, systemPrompt: String?, maxTokens: Int) throws -> String {
        let output = try bridge.generate(
            withPrompt: userPrompt,
            systemPrompt: systemPrompt,
            maxTokens: Int32(maxTokens),
            temperature: 0.3
        )
        guard !output.isEmpty else {
            throw OfflineLLMError.emptyResponse
        }
        Log.llm("[离线] 推理输出: \(output.count) chars")
        return output
    }

    // MARK: - 多轮分批处理

    /// 长文本分批摘要流程：分块 → 逐块摘要 → 合并
    private func multiPassSummarize(
        transcript: String,
        systemPrompt: String,
        instruction: String,
        maxChunkChars: Int,
        onProgress: ProgressHandler?
    ) throws -> String {
        // 1. 分块
        let chunks = splitText(transcript, maxChars: maxChunkChars)
        let total = chunks.count
        Log.llm("[离线] 分块完成: \(total) 块 (maxChunk=\(maxChunkChars))")

        // 2. 逐块摘要
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let current = i + 1
            DispatchQueue.main.async { onProgress?("正在分析片段 (\(current)/\(total))...") }

            // 清除上一块的 KV cache，避免上下文污染
            bridge.clearContext()

            let chunkPrompt = "用一两句话提取以下文本的关键信息，不要遗漏重要事项和决定：\n\n\(chunk)"
            do {
                let summary = try infer(userPrompt: chunkPrompt, systemPrompt: nil, maxTokens: 256)
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunkSummaries.append(trimmed)
                    Log.llm("[离线] 块 \(current)/\(total) 摘要: \(trimmed.count) chars")
                }
            } catch {
                Log.llm("[离线] 块 \(current)/\(total) 摘要失败，跳过: \(error.localizedDescription)")
                // 跳过失败的块，继续处理其他块
            }
        }

        guard !chunkSummaries.isEmpty else {
            throw OfflineLLMError.emptyResponse
        }

        Log.llm("[离线] 块摘要收集完成: \(chunkSummaries.count)/\(total) 块")

        // 3. 合并摘要
        DispatchQueue.main.async { onProgress?("正在整合摘要...") }
        bridge.clearContext()

        let mergedText: String
        if chunkSummaries.count == 1 {
            // 只有一块成功，直接返回
            mergedText = chunkSummaries[0]
        } else {
            let summariesText = chunkSummaries.enumerated()
                .map { "【片段 \($0 + 1)】\($1)" }
                .joined(separator: "\n\n")
            let mergePrompt = """
            \(instruction)

            以下是从长文本中提取的分段摘要，请整合为一个连贯的总结：

            \(summariesText)
            """
            mergedText = try infer(userPrompt: mergePrompt, systemPrompt: systemPrompt, maxTokens: 512)
        }

        return mergedText
    }

    // MARK: - 文本分块

    /// 将文本按句子边界分块，每块不超过 maxChars
    private func splitText(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }

        var chunks: [String] = []
        var currentChunk = ""
        let sentences = splitBySentences(text)

        for sentence in sentences {
            // 单个句子超过上限，硬截断
            if sentence.count > maxChars {
                // 先保存当前累积的块
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                    currentChunk = ""
                }
                // 硬截断长句子
                var remaining = sentence
                while remaining.count > maxChars {
                    let splitPos = remaining.index(remaining.startIndex, offsetBy: maxChars)
                    chunks.append(String(remaining[..<splitPos]).trimmingCharacters(in: .whitespacesAndNewlines))
                    remaining = String(remaining[splitPos...])
                }
                if !remaining.isEmpty {
                    currentChunk = remaining
                }
                continue
            }

            // 加入当前句子后超限 → 保存当前块，另起新块
            if currentChunk.count + sentence.count > maxChars {
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                currentChunk = sentence
            } else {
                currentChunk += sentence
            }
        }

        // 保存最后一块
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks.filter { !$0.isEmpty }
    }

    /// 按句子边界拆分文本，保留分隔符
    private func splitBySentences(_ text: String) -> [String] {
        // 中英文句子结尾模式
        let patterns = [
            // 中文标点后跟换行或空格
            try! NSRegularExpression(pattern: "([。！？；]\\n)", options: []),
            try! NSRegularExpression(pattern: "([。！？])([^」』）\\)\\n])", options: []),
            // 英文句号/问号/感叹号后跟空格和大写字母
            try! NSRegularExpression(pattern: "([.!?])\\s+(?=[A-Z])", options: []),
            // 换行符作为段落边界
            try! NSRegularExpression(pattern: "(\\n\\s*\\n)", options: []),
        ]

        // 先用正则标记切割点
        var splits: [String] = [text]
        for pattern in patterns {
            var newSplits: [String] = []
            for segment in splits {
                let matches = pattern.matches(
                    in: segment,
                    range: NSRange(segment.startIndex..., in: segment)
                )
                if matches.isEmpty {
                    newSplits.append(segment)
                } else {
                    var lastEnd = segment.startIndex
                    for match in matches {
                        let matchRange = Range(match.range, in: segment)!
                        // 句子的结束位置（包含标点）
                        let end = matchRange.upperBound
                        if end > lastEnd {
                            newSplits.append(String(segment[lastEnd..<end]))
                        }
                        lastEnd = end
                    }
                    if lastEnd < segment.endIndex {
                        newSplits.append(String(segment[lastEnd...]))
                    }
                }
            }
            splits = newSplits
        }

        // 如果没有匹配到任何句子边界，返回整段文本
        return splits.isEmpty ? [text] : splits.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
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
