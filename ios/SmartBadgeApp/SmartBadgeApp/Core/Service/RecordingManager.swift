import AVFoundation
import Combine
import Foundation

/// 录音状态管理器 — 统筹录音/ASR/定位/总结全流程
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

    private var currentVisitId: UUID?
    private var currentAsrURL: String = ""
    private var currentLlmURL: String = ""
    private var currentLlmKey: String = ""
    private var currentLlmModel: String = "deepseek-v4-pro"
    private var currentLlmPrompt: String?

    private var transcriptBuffer = ""
    private var locationPoints: [LocationPoint] = []

    private var audioStreamTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var asrTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?

    private var audioDataWritable: ((Data) -> Void)?
    private var batteryWarningShown = false

    init(container: AppContainer) {
        self.container = container
    }

    // MARK: - 开始录音

    func startRecording(
        visitId: UUID,
        asrURL: String,
        llmURL: String,
        llmKey: String,
        llmModel: String = "deepseek-v4-pro",
        llmPrompt: String? = nil
    ) {
        currentVisitId = visitId
        currentAsrURL = asrURL
        currentLlmURL = llmURL
        currentLlmKey = llmKey
        currentLlmModel = llmModel
        currentLlmPrompt = llmPrompt

        transcriptBuffer = ""
        transcript = ""
        locationPoints = []
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

        // 启动定位
        locationTask = Task {
            for await point in container.locationTracker.startTracking() {
                locationPoints.append(point)
            }
        }

        // 启动 ASR + 录音 pipeline
        performRecording()
    }

    private func performRecording() {
        let asrURL = currentAsrURL
        let asrClient = container.asrClient
        let audioCapture = container.audioCapture

        // 1. 连接 ASR WebSocket
        let asrStream = asrClient.connect(url: asrURL)

        // 2. 接收 ASR 结果
        asrTask = Task {
            for await event in asrStream {
                switch event {
                case .partial(let text):
                    transcriptBuffer += text
                    transcript = transcriptBuffer
                case .final(let text):
                    transcriptBuffer += text
                    transcript = transcriptBuffer
                case .error(let msg):
                    Log.recording("ASR error: \(msg)")
                case .connected:
                    Log.recording("ASR connected")
                    // 发送握手
                    asrClient.sendHandshake()
                case .disconnected:
                    Log.recording("ASR disconnected")
                }
            }
        }

        // 3. 启动录音并发送音频到 ASR
        audioStreamTask = Task {
            do {
                // 等待 WebSocket 连通
                try? await Task.sleep(nanoseconds: 300_000_000)

                let stream = try audioCapture.startCapturing()
                for try await audioData in stream {
                    // 写入本地文件
                    audioDataWritable?(audioData)
                    // 实时发送给 ASR
                    asrClient.sendAudio(audioData)
                }
            } catch {
                Log.recording("Audio capture error: \(error)")
            }
        }
    }

    /// 提供给外部的原始音频回调（用于写本地文件）
    func onAudioData(_ block: @escaping (Data) -> Void) {
        audioDataWritable = block
    }

    // MARK: - 结束录音

    func stopRecording() {
        phase = .stopping
        durationTask?.cancel()
        locationTask?.cancel()
        container.locationTracker.stopTracking()
        container.audioCapture.stop()

        // 发送 ASR 结束信号
        container.asrClient.sendEnd()

        Task {
            // 等待最终结果返回
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            container.asrClient.disconnect()
            audioStreamTask?.cancel()
            asrTask?.cancel()

            await generateSummary()
        }
    }

    // MARK: - 生成总结

    private func generateSummary() async {
        guard let visitId = currentVisitId else { return }

        phase = .generatingSummary
        let transcriptText = transcriptBuffer

        if transcriptText.isBlank, !currentAsrURL.isEmpty {
            // 实时 ASR 失败，尝试离线重试
            do {
                let audioPath = try await container.visitRepository.getVisit(id: visitId)?.audioFilePath ?? ""
                if !audioPath.isEmpty {
                    try await container.visitRepository.updateTranscriptStatus(visitId, status: .processing)
                    let result = await container.asrClient.processFile(
                        audioFilePath: audioPath,
                        serverUrl: currentAsrURL
                    )
                    if case .success(let text) = result {
                        transcript = text
                        transcriptBuffer = text
                    }
                }
            } catch {}
        }

        let finalTranscript = transcriptBuffer.isBlank
            ? "暂时无法获取转写内容"
            : transcriptBuffer

        // 保存转写文件
        let transcriptFileURL = saveTranscriptToFile(visitId: visitId, text: finalTranscript)

        try? await container.visitRepository.updateTranscript(
            visitId,
            text: finalTranscript,
            filePath: transcriptFileURL?.path ?? ""
        )
        try? await container.visitRepository.updateTranscriptStatus(
            visitId,
            status: finalTranscript == "暂时无法获取转写内容" ? .unavailable : .completed
        )

        // LLM 生成总结
        if finalTranscript != "暂时无法获取转写内容", !currentLlmURL.isEmpty {
            try? await container.visitRepository.updateSummaryStatus(visitId, status: .processing)

            let result = await retryLlm(transcript: finalTranscript)
            if case .success(let summary) = result {
                try? await container.visitRepository.updateSummary(visitId, summary: summary)
            } else {
                try? await container.visitRepository.updateSummaryStatus(visitId, status: .unavailable)
            }
        }

        isRecording = false
        phase = .idle
    }

    private func retryLlm(transcript: String) async -> Result<VisitSummary, Error> {
        let delays: [TimeInterval] = [20, 40, 80, 160, 320]

        for (i, delay) in delays.enumerated() {
            if i > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            let result = await container.llmClient.generateSummary(
                transcript: transcript,
                apiUrl: currentLlmURL,
                apiKey: currentLlmKey,
                model: currentLlmModel,
                customPrompt: currentLlmPrompt
            )
            if case .success = result { return result }
        }
        return .failure(LLMError.parseFailed("所有重试均已失败"))
    }

    // MARK: - 文件管理

    private let fileManager = FileManager.default

    private var audioDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
    }

    func startWritingAudio(visitId: UUID) -> URL {
        let dir = audioDirectory.appendingPathComponent(visitId.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let dateString = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(dateString).pcm")
        fileManager.createFile(atPath: url.path, contents: nil)

        // 设置写入回调
        let fileHandle = try? FileHandle(forWritingTo: url)
        onAudioData { data in
            try? fileHandle?.write(contentsOf: data)
        }

        return url
    }

    func finalizeAudio(visitId: UUID, pcmURL: URL) -> String? {
        try? FileHandle(forWritingTo: pcmURL).close()

        let wavURL = pcmURL.deletingPathExtension().appendingPathExtension("wav")
        guard let pcmData = try? Data(contentsOf: pcmURL),
              pcmData.count > 0
        else { return nil }

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

    private func saveTranscriptToFile(visitId: UUID, text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let dir = audioDirectory.appendingPathComponent(visitId.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let dateString = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(dateString).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
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
