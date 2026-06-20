import AVFoundation
import Combine
import Foundation

/// 录音状态管理器 — 统筹录音/ASR/总结全流程
/// 对齐 Android: RecordingService.kt
@MainActor
final class RecordingManager: ObservableObject {
    private let container: AppContainer

    // MARK: - 可观察状态

    @Published var isRecording = false
    @Published var transcript: String = ""
    @Published var durationSeconds: TimeInterval = 0
    @Published var phase: RecordingPhase = .idle

    enum RecordingPhase {
        case idle
        case recording
        case stopping
        case generatingSummary
    }

    // MARK: - 内部状态

    private var currentRecordId: UUID?
    private var currentAsrURL: String = ""
    private var currentLlmURL: String = ""
    private var currentLlmKey: String = ""
    private var currentLlmModel: String = "deepseek-v4-pro"
    private var currentLlmPrompt: String?

    /// 分段 ASR：累积 PCM 数据（不包含 WAV 头）
    private var pcmBuffer = Data()
    /// 分段 ASR：已完成的片段结果 (index → text)
    private var transcriptChunks: [Int: String] = [:]
    /// 分段 ASR：下一片段序号
    private var chunkIndex = 0
    /// 分段 ASR：尚未完成的片段数
    private var pendingChunkCount = 0
    /// 分段 ASR：每片段最大时长（秒）
    private let chunkDurationSeconds: TimeInterval = 300  // 5 min

    private var audioStreamTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?

    private var currentPcmURL: URL?
    private var currentFileHandle: FileHandle?
    private var audioDataWritable: ((Data) -> Void)?
    private var batteryWarningShown = false

    init(container: AppContainer) {
        self.container = container
    }

    // MARK: - 开始录音

    func startRecording(
        recordId: UUID,
        asrURL: String,
        llmURL: String,
        llmKey: String,
        llmModel: String = "deepseek-v4-pro",
        llmPrompt: String? = nil
    ) {
        currentRecordId = recordId
        currentAsrURL = asrURL
        currentLlmURL = llmURL
        currentLlmKey = llmKey
        currentLlmModel = llmModel
        currentLlmPrompt = llmPrompt

        pcmBuffer = Data()
        transcriptChunks = [:]
        chunkIndex = 0
        pendingChunkCount = 0
        transcript = ""
        durationSeconds = 0
        batteryWarningShown = false
        isRecording = true
        phase = .recording

        // 时长计时器
        durationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                durationSeconds += 1

                if durationSeconds >= 3600, !batteryWarningShown {
                    batteryWarningShown = true
                    // 电量提醒 — 实际可通过 UIDevice 获取电量
                }
            }
        }

        // 启动 ASR + 录音 pipeline
        performRecording()
    }

    private func performRecording() {
        let asrURL = currentAsrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioCapture = container.audioCapture

        guard !asrURL.isEmpty else {
            Log.recording("ASR URL 为空，跳过连接")
            transcript = "请先在设置中配置 FunASR 服务地址"
            isRecording = false
            phase = .idle
            return
        }

        Log.recording("启动分段 ASR 录音 (chunk=\(Int(chunkDurationSeconds))s)")

        audioStreamTask = Task {
            do {
                let stream = try audioCapture.startCapturing()
                Log.recording("音频流已启动，开始接收数据...")
                var totalBytes = 0
                for try await audioData in stream {
                    // 写文件（用于最终回放）
                    audioDataWritable?(audioData)
                    // 积累到 PCM buffer（用于分段 ASR）
                    pcmBuffer.append(audioData)
                    totalBytes += audioData.count

                    // 每 10 秒打一次日志
                    if totalBytes % 320_000 < audioData.count {
                        Log.recording("录音中: 已写入 \(totalBytes / 1000)KB, buffer=\(pcmBuffer.count / 1000)KB")
                    }

                    // 每 chunkDurationSeconds 秒处理一个片段
                    let bufferDuration = Double(pcmBuffer.count) / 32000.0
                    if bufferDuration >= chunkDurationSeconds {
                        processCurrentChunk()
                    }
                }
                Log.recording("音频流结束，总计写入 \(totalBytes / 1000)KB")
            } catch {
                Log.recording("Audio capture error: \(error)")
            }
        }
    }

    /// 将当前 buffer 作为一个片段发给 FunASR，异步处理不阻塞录音
    private func processCurrentChunk() {
        guard !pcmBuffer.isEmpty else { return }
        let chunk = pcmBuffer
        pcmBuffer = Data() // 下一段从零开始累积
        let index = chunkIndex
        chunkIndex += 1
        pendingChunkCount += 1
        let asrURL = currentAsrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrClient = container.asrClient

        Log.recording("发送片段 #\(index) (PCM \(chunk.count / 1000)KB)")

        Task.detached(priority: .utility) { [weak self] in
            let result = await asrClient.processPCMChunk(
                pcmData: chunk,
                serverUrl: asrURL,
                wavName: "chunk-\(index)"
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingChunkCount -= 1
                if case .success(let text) = result {
                    var chunks = self.transcriptChunks
                    chunks[index] = text
                    self.transcriptChunks = chunks
                    // 首个片段完成 → 转写进入处理中状态
                    if chunks.count == 1, let rid = self.currentRecordId {
                        Task { try? await self.container.recordRepository.updateTranscriptStatus(rid, status: .processing) }
                    }
                    Log.recording("片段 #\(index) 完成: \"\(text.prefix(40))...\"")
                } else {
                    Log.recording("片段 #\(index) 失败")
                }
                // 实时更新 UI 显示（按序号拼接已完成片段）
                self.transcript = self.joinedTranscript()
            }
        }
    }

    /// 按序号拼接所有已完成片段
    private func joinedTranscript() -> String {
        guard !transcriptChunks.isEmpty else { return "" }
        let sorted = transcriptChunks.keys.sorted()
        return sorted.compactMap { transcriptChunks[$0] }.joined(separator: "\n")
    }

    /// 提供给外部的原始音频回调（用于写本地文件）
    func onAudioData(_ block: @escaping (Data) -> Void) {
        audioDataWritable = block
    }

    // MARK: - 结束录音

    func stopRecording() {
        Log.recording("停止录音: pcmBuffer=\(pcmBuffer.count/1000)KB, pendingChunks=\(pendingChunkCount), chunkIndex=\(chunkIndex), pcmURL=\(currentPcmURL?.lastPathComponent ?? "nil")")
        phase = .stopping
        durationTask?.cancel()
        container.audioCapture.stop()

        // 立即标记录音结束 → UI 马上返回
        isRecording = false
        phase = .idle

        // 处理最后一段残片（不足 5min 的部分）
        if !pcmBuffer.isEmpty {
            processCurrentChunk()
        }
        audioStreamTask?.cancel()

        // 所有收尾工作放到后台执行，不阻塞 UI
        let recordId = currentRecordId
        let pcmURL = currentPcmURL
        let llmURL = currentLlmURL
        let llmKey = currentLlmKey
        let llmModel = currentLlmModel
        let llmPrompt = currentLlmPrompt

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // 等待所有片段完成（最长等 5 min/片段）
            let maxWaitPerChunk: TimeInterval = 300
            let start = Date()
            var totalWait: TimeInterval = 0
            while await MainActor.run(body: { self.pendingChunkCount }) > 0 {
                if totalWait >= maxWaitPerChunk { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 每 2s 检查
                totalWait = Date().timeIntervalSince(start)
            }

            // 定稿音频文件
            Log.recording("stopRecording 收尾: recordId=\(recordId?.uuidString ?? "nil"), pcmURL=\(pcmURL?.path ?? "nil")")
            if let recordId, let pcmURL {
                let wavPath = await MainActor.run {
                    self.finalizeAudio(recordId: recordId, pcmURL: pcmURL)
                }
                if let path = wavPath {
                    Log.recording("WAV 已定稿: \(path)")
                    try? await self.container.recordRepository.updateAudioFilePath(
                        recordId, path: path, endTime: Date()
                    )
                    Log.recording("audioFilePath 已写入 DB")
                } else {
                    Log.recording("finalizeAudio 返回 nil，WAV 定稿失败")
                }
            } else {
                Log.recording("定稿跳过: recordId 或 pcmURL 为 nil")
            }

            // 拼接所有片段 → 最终转写
            let finalText = await MainActor.run { self.joinedTranscript() }
            let savedText = finalText.isBlank
                ? "暂时无法获取转写内容"
                : finalText
            let fileURL = await MainActor.run {
                self.saveTranscriptToFile(recordId: recordId!, text: savedText)
            }
            if let recordId {
                try? await self.container.recordRepository.updateTranscript(
                    recordId, text: savedText, filePath: fileURL?.path ?? ""
                )
                try? await self.container.recordRepository.updateTranscriptStatus(
                    recordId,
                    status: savedText == "暂时无法获取转写内容" ? .unavailable : .completed
                )
            }

            // LLM 总结（5 次重试）—— 转写完成且填了 API Key 才执行
            let llmConfigured = !llmURL.isEmpty && !llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if savedText != "暂时无法获取转写内容", llmConfigured, let recordId {
                try? await self.container.recordRepository.updateSummaryStatus(recordId, status: .processing)

                let delays: [TimeInterval] = [5, 10, 20, 40, 80]
                var summaryResult: Result<RecordSummary, Error> = .failure(LLMError.parseFailed("未开始"))
                for (i, delay) in delays.enumerated() {
                    if i > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    let r = await self.container.llmClient.generateSummary(
                        transcript: savedText, apiUrl: llmURL, apiKey: llmKey,
                        model: llmModel, customPrompt: llmPrompt
                    )
                    if case .success = r { summaryResult = r; break }
                }
                if case .success(let summary) = summaryResult {
                    try? await self.container.recordRepository.updateSummary(recordId, summary: summary)
                } else {
                    try? await self.container.recordRepository.updateSummaryStatus(recordId, status: .unavailable)
                }
            } else if let recordId {
                // 转写失败 → 总结也标记为不可用，避免 UI 一直显示"处理中"
                try? await self.container.recordRepository.updateSummaryStatus(recordId, status: .unavailable)
            }
        }
        currentPcmURL = nil
    }


    // MARK: - 文件管理

    private let fileManager = FileManager.default

    private var audioDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
    }

    func startWritingAudio(recordId: UUID) -> URL {
        let dir = audioDirectory.appendingPathComponent(recordId.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let dateString = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(dateString).pcm")
        fileManager.createFile(atPath: url.path, contents: nil)

        // 打开并持有 FileHandle，关闭时由 finalizeAudio 负责
        guard let fileHandle = try? FileHandle(forWritingTo: url) else {
            Log.recording("错误: 无法打开 FileHandle 写入 PCM: \(url.path)")
            return url
        }
        currentFileHandle = fileHandle
        onAudioData { [weak fileHandle] data in
            try? fileHandle?.write(contentsOf: data)
        }

        currentPcmURL = url
        Log.recording("开始写入 PCM: \(url.path)")
        return url
    }

    func finalizeAudio(recordId: UUID, pcmURL: URL) -> String? {
        // 先关闭持有的 FileHandle，确保数据刷盘
        if let handle = currentFileHandle {
            try? handle.synchronize()
            try? handle.close()
            currentFileHandle = nil
            Log.recording("PCM FileHandle 已关闭并同步")
        }

        let wavURL = pcmURL.deletingPathExtension().appendingPathExtension("wav")
        guard let pcmData = try? Data(contentsOf: pcmURL),
              pcmData.count > 0
        else {
            Log.recording("finalizeAudio 失败: PCM 文件为空或不可读")
            return nil
        }

        Log.recording("finalizeAudio: PCM size=\(pcmData.count) bytes, duration≈\(Double(pcmData.count) / 32000.0)s")

        // 验证 PCM 数据非空（取中间 100 个 sample，避开开头的静音段）
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        let midOffset = max(0, (sampleCount / 2 - 50) * MemoryLayout<Int16>.size)
        let samples = pcmData.withUnsafeBytes { ptr -> [Int16] in
            let base = ptr.baseAddress!.advanced(by: midOffset)
            return Array(UnsafeBufferPointer(start: base.bindMemory(to: Int16.self, capacity: 100), count: min(100, sampleCount)))
        }
        let maxAbs = samples.map(abs).max() ?? 0
        Log.recording("finalizeAudio: 前100个sample中最大振幅=\(maxAbs)")

        let dataSize = Int32(pcmData.count)
        let fileSize = dataSize + 36
        let sampleRate: Int32 = 16_000
        let byteRate: Int32 = sampleRate * 2 // 16-bit mono

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian, Array.init))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian, Array.init)) // chunk size
        wav.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian, Array.init))  // PCM
        wav.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian, Array.init))  // mono
        wav.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: Int16(2).littleEndian, Array.init))  // block align
        wav.append(contentsOf: withUnsafeBytes(of: Int16(16).littleEndian, Array.init)) // bits/sample
        wav.append("data".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        wav.append(pcmData)

        try? wav.write(to: wavURL)
        try? fileManager.removeItem(at: pcmURL) // 删除原始 PCM

        return wavURL.path
    }

    private func saveTranscriptToFile(recordId: UUID, text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let dir = audioDirectory.appendingPathComponent(recordId.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.recording("创建转写目录失败: \(error)")
            return nil
        }
        let dateString = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(dateString).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            Log.recording("转写文件已保存: \(url.path) (\(text.count) 字符)")
            return url
        } catch {
            Log.recording("转写文件写入失败: \(error)")
            return nil
        }
    }
}

// MARK: - 日志

enum Log {
    static func recording(_ msg: String) {
        #if DEBUG
        print("[RecordingManager] \(msg)")
        #endif
    }
}

// MARK: - 工具扩展

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
