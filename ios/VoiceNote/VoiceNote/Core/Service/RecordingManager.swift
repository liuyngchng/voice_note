import AVFoundation
import Combine
import Foundation
import UIKit

/// 录音状态管理器 — 统筹录音/离线ASR全流程
@MainActor
final class RecordingManager: ObservableObject {
    private let container: AppContainer

    // MARK: - 可观察状态

    @Published var isRecording = false
    @Published var transcript: String = ""
    @Published var durationSeconds: TimeInterval = 0
    @Published var phase: RecordingPhase = .idle
    @Published var audioLevel: Float = 0.0

    enum RecordingPhase {
        case idle
        case recording
        case stopping
    }

    // MARK: - 内部状态

    private var currentRecordId: UUID?

    /// 分段 ASR：累积 PCM 数据（不包含 WAV 头）
    private var pcmBuffer = Data()
    /// 分段 ASR：已完成的片段结果 (index → text)
    private var transcriptChunks: [Int: String] = [:]
    /// 分段 ASR：下一片段序号
    private var chunkIndex = 0
    /// 分段 ASR：尚未完成的片段数
    private var pendingChunkCount = 0
    /// 分段 ASR：每片段最大时长（秒）
    private let chunkDurationSeconds: TimeInterval = 15

    /// 增量转写：累积拼接 buffer（避免 O(n²) 全量拼接）
    /// 内存上限 ~64KB（约 3 万中文字符），超出的部分已写盘，只保留尾部用于 UI 展示
    private let maxAccumulatedTranscriptChars = 30000
    private var accumulatedTranscript = ""
    /// 增量转写：最后已拼入的序号，防止乱序
    private var lastChunkIndex: Int = -1
    /// 增量写盘：转写文件路径
    private var transcriptFileURL: URL?

    /// VAD 是否激活（模型可用则为 true，否则回退到按时间分块）
    private var vadActive = false
    /// VAD 语音段计数器（替代 chunkIndex 用于 VAD 模式）
    private var vadSegmentIndex = 0

    private var audioStreamTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var diskCheckTask: Task<Void, Never>?
    private var vadDecodeTask: Task<Void, Never>?

    /// 录音开始时间，用于防漂移的精确计时
    private var recordingStartTime = Date()
    /// 后台任务 ID，防止长时间录音被系统挂起
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private var currentPcmURL: URL?
    private var currentFileHandle: FileHandle?
    private var audioDataWritable: ((Data) -> Void)?
    private var batteryWarningShown = false

    /// 串行队列专门用于音频文件写入，避免阻塞主线程导致波形卡顿
    private let fileWriteQueue = DispatchQueue(label: "com.voicenote.filewrite", qos: .userInitiated)

    init(container: AppContainer) {
        self.container = container
    }

    // MARK: - 开始录音

    func startRecording(recordId: UUID) {
        currentRecordId = recordId

        pcmBuffer = Data()
        transcriptChunks = [:]
        chunkIndex = 0
        pendingChunkCount = 0
        transcript = ""
        accumulatedTranscript = ""
        lastChunkIndex = -1
        durationSeconds = 0
        batteryWarningShown = false
        isRecording = true
        phase = .recording

        // 后台任务：防止长时间录音被 iOS 系统挂起
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            Log.recording("⚠️ 后台任务即将过期，强制停止录音")
            self?.stopRecording()
        }
        if backgroundTaskID == .invalid {
            Log.recording("⚠️ beginBackgroundTask 返回 invalid，后台录音可能受限")
        } else {
            Log.recording("后台任务已注册: \(backgroundTaskID.rawValue)")
        }

        // 创建增量转写文件 (crash 可恢复)
        let dir = audioDirectory.appendingPathComponent(recordId.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let dateStr = Self.localDateString()
        transcriptFileURL = dir.appendingPathComponent("\(dateStr).txt")
        fileManager.createFile(atPath: transcriptFileURL!.path, contents: nil)
        Log.recording("增量转写文件已创建: \(transcriptFileURL!.path)")

        // 防漂移时长计时器：基于绝对时间，避免 Task.sleep 累积误差
        recordingStartTime = Date()
        durationTask = Task {
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(recordingStartTime)
                durationSeconds = elapsed

                if elapsed >= 3600, !batteryWarningShown {
                    batteryWarningShown = true
                }
                try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s 刷新
            }
        }

        // 检查离线模型是否已下载
        let quality = ASRModelManager.savedQuality()
        guard ASRModelManager.isModelDownloaded(quality) else {
            Log.recording("离线模型未下载 (\(quality.rawValue))，中止录音")
            transcript = "离线模型未下载，请先在设置中下载 SenseVoice 模型"
            isRecording = false
            phase = .idle
            return
        }

        // 确保离线识别器已初始化
        do {
            try container.offlineASRClient.ensureRecognizer(quality: quality)
        } catch {
            Log.recording("离线识别器初始化失败: \(error.localizedDescription)")
            transcript = "离线识别器初始化失败: \(error.localizedDescription)"
            isRecording = false
            phase = .idle
            return
        }

        // 尝试加载标点模型（若已下载）
        container.offlinePunctuationClient.ensureInitialized()
        Log.recording("标点模型状态: \(container.offlinePunctuationClient.isAvailable ? "已加载" : "未加载")")

        // 尝试初始化 VAD（若模型可用）
        vadActive = container.offlineASRClient.ensureVad()
        vadSegmentIndex = 0
        Log.recording("VAD 状态: \(vadActive ? "已激活" : "不可用，回退到按时间分块")")

        Log.recording("启动离线 ASR 录音 (chunk=\(Int(chunkDurationSeconds))s, vad=\(vadActive))")

        // 启动磁盘空间监控 + 转录进度 checkpoint（每 5 分钟）
        let ridForCheckpoint = recordId
        let repositoryForCheckpoint = container.recordRepository
        diskCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 min
                guard let self else { break }

                // 转录进度 checkpoint（DB 仅记录时长，文本在 .txt 文件中）
                let dur = await MainActor.run { self.durationSeconds }
                await repositoryForCheckpoint.checkpointTranscriptProgress(ridForCheckpoint, durationSeconds: dur)
                Log.recording("转录 checkpoint: \(Int(dur))s")

                // 磁盘空间检查
                guard let values = try? FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .resourceValues(forKeys: [.volumeAvailableCapacityKey]),
                      let free = values.volumeAvailableCapacity, free > 0
                else { continue }
                let freeMB = free / 1_048_576
                if free < 500_000_000 {
                    Log.recording("⚠️ 磁盘空间不足 (剩余 \(freeMB)MB)，建议停止录音")
                }
            }
        }

        // 启动 VAD 周期性解码任务（独立于音频消费循环，防止 ASR 推理阻塞音频采集）
        if vadActive {
            let offlineClientForVad = container.offlineASRClient
            vadDecodeTask = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { break }

                    let segments = await offlineClientForVad.vadDecodeSpeechSegments()
                    if segments.isEmpty { continue }

                    await MainActor.run {
                        for text in segments {
                            self.handleVadSegment(text: text)
                        }
                    }
                }
            }
            Log.recording("VAD 解码 Task 已启动（3s 周期）")
        }

        // 启动录音 pipeline
        performRecording()
    }

    private func performRecording() {
        let audioCapture = container.audioCapture
        let offlineClient = container.offlineASRClient

        // 使用 Task.detached 让音频处理循环跑在后台线程，
        // 避免 MainActor 被 VAD/ASR 推理产生的级联积压卡死。
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                let stream = try audioCapture.startCapturing()
                Log.recording("音频流已启动，开始接收数据...")
                Log.recording("▶ 转写开始")
                var totalBytes = 0
                var lastBackpressureCheckTime = Date()
                var bytesSinceLastCheck = 0

                // 一次性读取 MainActor 状态，避免每次循环都 hop 到主线程
                let vadActive = await MainActor.run { self.vadActive }
                let chunkDuration = await MainActor.run { self.chunkDurationSeconds }
                // 捕获写文件句柄 (FileHandle 线程安全，可在后台队列使用)
                let writeFileHandle = await MainActor.run { self.currentFileHandle }

                for try await audioData in stream {
                    // 协作式取消：点击结束按钮后可快速退出循环
                    try Task.checkCancellation()

                    // 写文件到后台队列，不阻塞主线程（之前 await MainActor.run 会串行化到主线程）
                    if let fh = writeFileHandle {
                        self.fileWriteQueue.async { [audioData] in
                            try? fh.write(contentsOf: audioData)
                        }
                    }
                    totalBytes += audioData.count

                    // 计算实时音量 (RMS) — 纯计算，后台线程安全
                    let floats = self.pcmDataToFloats(audioData)
                    let sumSquares = floats.reduce(0) { $0 + $1 * $1 }
                    let rms = sqrt(sumSquares / Float(floats.count))
                    let level = min(1.0, rms * 12.0)

                    // 更新波形到 MainActor（必须：@Published 需要主线程）
                    await MainActor.run { [level] in
                        self.audioLevel = level
                    }

                    if vadActive {
                        // VAD accept 异步化: 派发到 vadQueue，不阻塞音频采集
                        // VAD 解码由独立 vadDecodeTask 周期性驱动，不在此阻塞
                        await offlineClient.vadAcceptWaveformAsync(samples: floats)

                        // 每 10 秒打一次日志（含 VAD 状态 + 积压监控）
                        if totalBytes % 320_000 < audioData.count {
                            let detected = offlineClient.vadIsDetected ? "语音" : "静音"
                            Log.recordingDebug("录音中: 已写入 \(totalBytes / 1000)KB [VAD: \(detected)]")
                        }
                    } else {
                        // 非 VAD 模式: 通过 MainActor 累积 PCM 并按时间分块
                        await MainActor.run { [audioData] in
                            self.pcmBuffer.append(audioData)

                            let bufferDuration = Double(self.pcmBuffer.count) / 32000.0
                            if bufferDuration >= chunkDuration {
                                self.processCurrentChunk()
                            }
                        }
                    }

                    // 背压监控: 每 30 秒检测消费速率是否跟不上生产速率
                    bytesSinceLastCheck += audioData.count
                    let checkElapsed = Date().timeIntervalSince(lastBackpressureCheckTime)
                    if checkElapsed >= 30 {
                        let expectedBytes = Int(32000.0 * checkElapsed)  // 16kHz × 2 bytes/sample
                        let consumedRate = Double(bytesSinceLastCheck) / checkElapsed
                        if consumedRate < 28000 {  // 低于 87.5% 期望速率
                            Log.recording("⚠️ 背压告警: 过去 \(Int(checkElapsed))s 仅消费 \(bytesSinceLastCheck/1000)KB, 期望 ≥\(expectedBytes/1000)KB, 速率=\(Int(consumedRate))B/s")
                        }
                        lastBackpressureCheckTime = Date()
                        bytesSinceLastCheck = 0
                    }
                }
                Log.recording("音频流结束，总计写入 \(totalBytes / 1000)KB")
            } catch is CancellationError {
                Log.recording("音频流被取消")
            } catch {
                Log.recording("Audio capture error: \(error)")
            }
        }

        audioStreamTask = task
    }

    /// 将 PCM Data 转换为 Float 数组 (16kHz/16bit/mono → [-1, 1])
    /// nonisolated: 纯计算函数，可从任意 context 调用
    nonisolated private func pcmDataToFloats(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        return data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16s = ptr.bindMemory(to: Int16.self)
            var floats = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                floats[i] = Float(int16s[i]) / 32768.0
            }
            return floats
        }
    }

    /// 处理 VAD 模式下一个语音段的 ASR 结果
    private func handleVadSegment(text: String) {
        let index = vadSegmentIndex
        vadSegmentIndex += 1

        // 存入 transcriptChunks 并增量拼接
        transcriptChunks[index] = text

        // 累积拼接
        var nextIndex = lastChunkIndex + 1
        while let chunkText = transcriptChunks[nextIndex] {
            if !accumulatedTranscript.isEmpty {
                accumulatedTranscript += "\n"
            }
            accumulatedTranscript += chunkText
            lastChunkIndex = nextIndex
            nextIndex += 1
        }
        // 内存保护：截断超长文本（已写盘，仅保留尾部）
        if accumulatedTranscript.count > maxAccumulatedTranscriptChars {
            accumulatedTranscript = String(accumulatedTranscript.suffix(maxAccumulatedTranscriptChars))
        }
        transcript = accumulatedTranscript

        // 增量写盘
        appendTranscriptChunk(text)

        Log.recordingDebug("VAD 语音段 #\(index): \"\(text.prefix(40))...\"")
    }

    /// 将当前 buffer 作为一个片段发给离线 ASR
    private func processCurrentChunk() {
        guard !pcmBuffer.isEmpty else { return }
        let chunk = pcmBuffer
        pcmBuffer = Data()
        let index = chunkIndex
        chunkIndex += 1
        pendingChunkCount += 1
        let offlineClient = container.offlineASRClient
        let repository = container.recordRepository
        let recordId = currentRecordId

        Task.detached(priority: .utility) {
            let result = await offlineClient.processPCMChunk(pcmData: chunk)

            await MainActor.run {
                self.pendingChunkCount -= 1
                if case .success(let text) = result {
                    var chunks = self.transcriptChunks
                    chunks[index] = text
                    self.transcriptChunks = chunks

                    // 增量写盘 (crash 可恢复)
                    self.appendTranscriptChunk(text)

                    // 累积拼接：按序拼接已完成片段 (O(n) 替代 O(n²))
                    var nextIndex = self.lastChunkIndex + 1
                    while let chunkText = chunks[nextIndex] {
                        if !self.accumulatedTranscript.isEmpty {
                            self.accumulatedTranscript += "\n"
                        }
                        self.accumulatedTranscript += chunkText
                        self.lastChunkIndex = nextIndex
                        nextIndex += 1
                    }
                    // 内存保护：截断超长文本（已写盘，仅保留尾部）
                    if self.accumulatedTranscript.count > self.maxAccumulatedTranscriptChars {
                        self.accumulatedTranscript = String(self.accumulatedTranscript.suffix(self.maxAccumulatedTranscriptChars))
                    }
                    self.transcript = self.accumulatedTranscript

                    if chunks.count == 1, let rid = recordId {
                        Task { try? await repository.updateTranscriptStatus(rid, status: .processing) }
                    }
                    Log.recording("片段 #\(index) 完成: \"\(text.prefix(40))...\"")
                } else {
                    Log.recording("片段 #\(index) 失败")
                }

                if self.pendingChunkCount == 0, !self.isRecording, let rid = recordId {
                    let chunkCount = self.chunkIndex
                    Log.recording("◀ 转写结束: 全部 \(chunkCount) 片段完成，保存最终转写")
                    let rawText = self.accumulatedTranscript
                    let punctClient = self.container.offlinePunctuationClient
                    let punctuated: String
                    if !rawText.isBlank, punctClient.isAvailable {
                        punctuated = punctClient.addPunctuation(to: rawText)
                        Log.recording("标点恢复完成: raw=\(rawText.count)字符, punct=\(punctuated.count)字符")
                    } else {
                        punctuated = rawText
                        if !rawText.isBlank {
                            Log.recording("标点模型不可用，跳过标点恢复")
                        }
                    }
                    let savedText = punctuated.isBlank
                        ? "暂时无法获取转写内容"
                        : punctuated
                    // 增量文件已写入，此处仅保存最终文件到 DB
                    let fileURL = self.transcriptFileURL
                    if let url = fileURL {
                        try? savedText.write(to: url, atomically: true, encoding: .utf8)
                    }
                    self.doFinalizeTranscript(recordId: rid, text: savedText, fileURL: fileURL)
                }
            }
        }
    }

    /// 增量追加转写文本到磁盘文件（含 sync，崩溃安全）
    private func appendTranscriptChunk(_ text: String) {
        guard let url = transcriptFileURL,
              let handle = try? FileHandle(forWritingTo: url) else { return }
        let line = text + "\n"
        try? handle.seekToEnd()
        try? handle.write(contentsOf: line.data(using: .utf8)!)
        try? handle.synchronize()
        try? handle.close()
    }

    /// 提供给外部的原始音频回调（用于写本地文件）
    func onAudioData(_ block: @escaping (Data) -> Void) {
        audioDataWritable = block
    }

    // MARK: - 结束录音

    func stopRecording() {
        Log.recording("停止录音: pcmBuffer=\(pcmBuffer.count/1000)KB, pendingChunks=\(pendingChunkCount), chunkIndex=\(chunkIndex), vadActive=\(vadActive)")
        phase = .stopping
        durationTask?.cancel()
        diskCheckTask?.cancel()
        vadDecodeTask?.cancel()

        // 1. 先取消音频处理 Task，让 for-try-await 循环通过 Task.checkCancellation() 退出
        audioStreamTask?.cancel()

        // 2. 再停止音频引擎（tap removed, engine stopped）
        container.audioCapture.stop()

        // 立即标记录音结束 → UI 马上返回
        isRecording = false
        phase = .idle
        audioLevel = 0.0

        // 结束后台任务
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            Log.recording("后台任务已结束: \(backgroundTaskID.rawValue)")
            backgroundTaskID = .invalid
        }

        if vadActive {
            // VAD 模式: 异步 flush + 解码尾部语音段（vadQueue / asrQueue 已分离，线程安全）
            Task {
                await container.offlineASRClient.vadFlushAsync()
                let finalSegments = await container.offlineASRClient.vadDecodeSpeechSegments()
                if !finalSegments.isEmpty {
                    await MainActor.run {
                        for text in finalSegments {
                            self.handleVadSegment(text: text)
                        }
                    }
                }
                await MainActor.run {
                    self.finalizeTranscriptIfNeeded()
                }
            }
        } else {
            // 非 VAD 模式: 处理最后一段残片（不足 15s 的部分）
            if !pcmBuffer.isEmpty {
                processCurrentChunk()
            }
        }

        // 音频定稿：后台执行，不阻塞 UI
        let recordId = currentRecordId
        let pcmURL = currentPcmURL
        let repository = container.recordRepository

        Task {
            Log.recording("音频定稿开始")
            if let recordId, let pcmURL {
                let wavPath = finalizeAudio(recordId: recordId, pcmURL: pcmURL)
                if let path = wavPath {
                    Log.recording("WAV 已定稿: \(path)")
                    try? await repository.updateAudioFilePath(recordId, path: path, endTime: Date())
                    Log.recording("audioFilePath 已写入 DB")
                } else {
                    Log.recording("finalizeAudio 返回 nil，WAV 定稿失败")
                }
            } else {
                Log.recording("定稿跳过: recordId 或 pcmURL 为 nil")
            }
        }
        currentPcmURL = nil
    }

    /// VAD 模式下的最终转写保存
    private func finalizeTranscriptIfNeeded() {
        guard let rid = currentRecordId else { return }
        Log.recording("VAD 全部语音段完成，保存最终转写")
        let rawText = accumulatedTranscript
        let punctClient = container.offlinePunctuationClient
        let punctuated: String
        if !rawText.isBlank, punctClient.isAvailable {
            punctuated = punctClient.addPunctuation(to: rawText)
            Log.recording("标点恢复完成: raw=\(rawText.count)字符, punct=\(punctuated.count)字符")
        } else {
            punctuated = rawText
            if !rawText.isBlank {
                Log.recording("标点模型不可用，跳过标点恢复")
            }
        }
        let savedText = punctuated.isBlank
            ? "暂时无法获取转写内容"
            : punctuated
        if let url = transcriptFileURL {
            try? savedText.write(to: url, atomically: true, encoding: .utf8)
        }
        doFinalizeTranscript(recordId: rid, text: savedText, fileURL: transcriptFileURL)
    }

    /// 保存最终转写到 DB（仅元数据，文本全文在 .txt 文件中）
    private func doFinalizeTranscript(recordId: UUID, text: String, fileURL: URL?) {
        let repository = container.recordRepository
        let isUnavailable = (text == "暂时无法获取转写内容")
        Task {
            try? await repository.updateTranscriptFilePath(recordId, filePath: fileURL?.path ?? "")
            let status: ProcessingStatus = isUnavailable ? .unavailable : .completed
            try? await repository.updateTranscriptStatus(recordId, status: status)
        }
    }

    // MARK: - 文件管理

    private static func localDateString() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return fmt.string(from: Date())
    }

    private let fileManager = FileManager.default

    // MARK: - 崩溃恢复

    /// 恢复未完成的录音：从 .txt 文件加载已转录文本，更新 DB
    func recoverUnfinishedRecords() async {
        let repository = container.recordRepository
        let unfinished = await repository.getUnfinishedRecords()
        guard !unfinished.isEmpty else {
            Log.recording("崩溃恢复: 无未完成记录")
            return
        }

        Log.recording("崩溃恢复: 发现 \(unfinished.count) 条未完成记录")
        for record in unfinished {
            let dir = audioDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
            let txtFiles = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                .flatMap { $0.filter { $0.pathExtension == "txt" } } ?? []

            guard let latestTxt = txtFiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first else {
                Log.recording("崩溃恢复: recordId=\(record.id) 无转录文件，跳过")
                continue
            }

            guard let text = try? String(contentsOf: latestTxt, encoding: .utf8), !text.isEmpty else {
                Log.recording("崩溃恢复: recordId=\(record.id) 转录文件为空")
                continue
            }

            Log.recording("崩溃恢复: recordId=\(record.id), 恢复 \(text.count) 字符, 已转录 \(Int(record.transcribedDurationSeconds))s")
            try? await repository.updateTranscriptFilePath(record.id, filePath: latestTxt.path)
            try? await repository.updateTranscriptStatus(record.id, status: .completed)
        }
    }

    private var audioDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
    }

    func startWritingAudio(recordId: UUID) -> URL {
        let dir = audioDirectory.appendingPathComponent(recordId.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let dateString = Self.localDateString()
        let url = dir.appendingPathComponent("\(dateString).pcm")
        fileManager.createFile(atPath: url.path, contents: nil)

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
        // 等待所有排队的文件写入完成，再关闭 handle（防止尾部数据丢失）
        fileWriteQueue.sync {
            // barrier — 确保此前的 async 写入都已执行完毕
        }

        // 关闭写入 handle
        if let handle = currentFileHandle {
            try? handle.synchronize()
            try? handle.close()
            currentFileHandle = nil
            Log.recording("PCM FileHandle 已关闭并同步")
        }

        // 获取 PCM 文件大小（不加载到内存）
        guard let pcmAttrs = try? fileManager.attributesOfItem(atPath: pcmURL.path),
              let pcmSize = pcmAttrs[.size] as? Int64,
              pcmSize > 0
        else {
            Log.recording("finalizeAudio 失败: PCM 文件为空或不可读")
            return nil
        }

        let wavURL = pcmURL.deletingPathExtension().appendingPathExtension("wav")
        let dataSize = Int32(pcmSize)
        let fileSize = dataSize + 36
        let sampleRate: Int32 = 16_000
        let byteRate: Int32 = sampleRate * 2

        Log.recording("finalizeAudio: PCM size=\(pcmSize) bytes, duration≈\(Double(pcmSize) / 32000.0)s, 流式转换 WAV")

        // 创建 WAV 文件
        guard fileManager.createFile(atPath: wavURL.path, contents: nil) else {
            Log.recording("finalizeAudio 失败: 无法创建 WAV 文件")
            return nil
        }
        guard let wavHandle = try? FileHandle(forWritingTo: wavURL) else {
            return nil
        }

        // 写 WAV header
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian, Array.init))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: Int16(2).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: Int16(16).littleEndian, Array.init))
        header.append("data".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        try? wavHandle.write(contentsOf: header)

        // 流式读 PCM → 写到 WAV (每次 4MB 块)，避免全量加载到内存
        guard let pcmHandle = try? FileHandle(forReadingFrom: pcmURL) else {
            try? wavHandle.close()
            try? fileManager.removeItem(at: wavURL)
            Log.recording("finalizeAudio 失败: 无法打开 PCM 文件读取")
            return nil
        }

        let chunkSize = 4 * 1024 * 1024  // 4MB
        var totalWritten: Int64 = 0
        while true {
            guard let chunk = try? pcmHandle.read(upToCount: chunkSize),
                  !chunk.isEmpty else { break }
            try? wavHandle.write(contentsOf: chunk)
            totalWritten += Int64(chunk.count)
        }

        try? pcmHandle.close()
        try? wavHandle.close()

        Log.recording("WAV 流式转换完成: \(totalWritten) bytes written")

        // 验证中间振幅
        if let verifyHandle = try? FileHandle(forReadingFrom: wavURL) {
            defer { try? verifyHandle.close() }
            // Seek to middle of data section (44 byte header + middle of PCM)
            let midDataOffset: UInt64 = 44 + UInt64(pcmSize / 2)
            try? verifyHandle.seek(toOffset: midDataOffset)
            if let midChunk = try? verifyHandle.read(upToCount: 200) {
                let samples = midChunk.withUnsafeBytes { ptr -> [Int16] in
                    let base = ptr.baseAddress!.bindMemory(to: Int16.self, capacity: 100)
                    return Array(UnsafeBufferPointer(start: base, count: min(100, midChunk.count / 2)))
                }
                let maxAbs = samples.map(abs).max() ?? 0
                Log.recording("finalizeAudio: 中段前100个sample中最大振幅=\(maxAbs)")
            }
        }

        // 删除原始 PCM
        try? fileManager.removeItem(at: pcmURL)

        return wavURL.path
    }

}

// MARK: - 日志

import os

final class LogFile {
    static let shared = LogFile()

    private let queue = DispatchQueue(label: "com.voicenote.logfile")
    private var fileHandle: FileHandle?
    private var flushTimer: DispatchSourceTimer?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 日志文件路径（供外部查看/导出）
    var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.log")
    }

    private init() {
        let url = logFileURL
        let maxSize = 2 * 1024 * 1024
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxSize {
            try? FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        startPeriodicFlush()
    }

    /// 每隔 2 秒刷盘，常规崩溃最多丢 2 秒日志
    private func startPeriodicFlush() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            try? self?.fileHandle?.synchronizeFile()
        }
        timer.resume()
        flushTimer = timer
    }

    func append(_ tag: String, _ msg: String) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] [\(tag)] \(msg)\n"
        queue.async { [weak self] in
            if let data = line.data(using: .utf8) {
                try? self?.fileHandle?.write(contentsOf: data)
            }
        }
    }

    /// 清除日志文件
    func clear() {
        let url = logFileURL
        queue.async { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
            // 截断文件到 0
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self?.fileHandle = try? FileHandle(forWritingTo: url)
            self?.fileHandle?.seekToEndOfFile()
        }
    }

    /// 同步写盘（用于崩溃诊断，确保关键时刻日志落盘）
    func syncAppend(_ tag: String, _ msg: String) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] [\(tag)] \(msg)\n"
        queue.sync { [weak self] in
            if let data = line.data(using: .utf8) {
                try? self?.fileHandle?.write(contentsOf: data)
                try? self?.fileHandle?.synchronizeFile()
            }
        }
    }
}

enum Log {
    private static let logger = Logger(subsystem: "com.voicenote", category: "recording")
    private static let asrLogger = Logger(subsystem: "com.voicenote", category: "asr")

    static func recording(_ msg: String) {
        logger.info("\(msg)")
        LogFile.shared.append("recording", msg)
    }

    static func asr(_ msg: String) {
        asrLogger.info("\(msg)")
        LogFile.shared.append("asr", msg)
    }

    static func recordingDebug(_ msg: String) {
        logger.debug("\(msg)")
        LogFile.shared.append("recording-debug", msg)
    }

    static func asrDebug(_ msg: String) {
        asrLogger.debug("\(msg)")
        LogFile.shared.append("asr-debug", msg)
    }
}

// MARK: - 工具扩展

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
