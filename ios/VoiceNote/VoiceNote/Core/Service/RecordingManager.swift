import AVFoundation
import Combine
import Foundation

/// 录音状态管理器 — 统筹录音/离线ASR全流程
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

    func startRecording(recordId: UUID) {
        currentRecordId = recordId

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
                }
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

        Log.recording("启动离线 ASR 录音 (chunk=\(Int(chunkDurationSeconds))s)")

        // 启动录音 pipeline
        performRecording()
    }

    private func performRecording() {
        let audioCapture = container.audioCapture

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

        Log.recording("发送片段 #\(index) (PCM \(chunk.count / 1000)KB)")

        Task.detached(priority: .utility) {
            let result = await offlineClient.processPCMChunk(pcmData: chunk)

            await MainActor.run {
                self.pendingChunkCount -= 1
                if case .success(let text) = result {
                    var chunks = self.transcriptChunks
                    chunks[index] = text
                    self.transcriptChunks = chunks
                    if chunks.count == 1, let rid = recordId {
                        Task { try? await repository.updateTranscriptStatus(rid, status: .processing) }
                    }
                    Log.recording("片段 #\(index) 完成: \"\(text.prefix(40))...\"")
                } else {
                    Log.recording("片段 #\(index) 失败")
                }
                self.transcript = self.joinedTranscript()

                if self.pendingChunkCount == 0, !self.isRecording, let rid = recordId {
                    Log.recording("全部片段完成，保存最终转写")
                    let rawText = self.joinedTranscript()
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
                    let fileURL = self.saveTranscriptToFile(recordId: rid, text: savedText)
                    self.doFinalizeTranscript(recordId: rid, text: savedText, fileURL: fileURL)
                }
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
        Log.recording("停止录音: pcmBuffer=\(pcmBuffer.count/1000)KB, pendingChunks=\(pendingChunkCount), chunkIndex=\(chunkIndex)")
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

    /// 保存最终转写到 DB
    private func doFinalizeTranscript(recordId: UUID, text: String, fileURL: URL?) {
        let repository = container.recordRepository
        let savedText = text
        Task {
            try? await repository.updateTranscript(recordId, text: savedText, filePath: fileURL?.path ?? "")
            let status: ProcessingStatus = savedText == "暂时无法获取转写内容" ? .unavailable : .completed
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
        let dateString = Self.localDateString()
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

import os

final class LogFile {
    static let shared = LogFile()

    private let queue = DispatchQueue(label: "com.voicenote.logfile")
    private var fileHandle: FileHandle?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("app.log")
        let maxSize = 2 * 1024 * 1024
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxSize {
            try? FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
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
