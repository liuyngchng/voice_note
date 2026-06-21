import Combine
import Foundation

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var visit: VoiceRecord?
    @Published var isLoading = true
    @Published var isRetryingTranscript = false
    @Published var isRetryingSummary = false
    @Published var transcriptError: String?
    @Published var summaryError: String?

    @Published var audioPlayer = AudioPlayer()

    private let container: AppContainer
    private var loadedAudioPath: String?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: AnyCancellable?
    private var currentVisitId: UUID?

    init(container: AppContainer) {
        self.container = container
        audioPlayer.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func loadRecord(id: UUID) {
        currentVisitId = id
        refresh()
    }

    private func refresh() {
        guard let id = currentVisitId else { return }
        Task {
            let result = try? await container.recordRepository.getRecord(id: id)
            await MainActor.run {
                visit = result
                isLoading = false
                loadAudioIfNeeded()
                scheduleNextRefreshIfNeeded()
                deriveErrorMessages()
            }
        }
    }

    /// 如果自动失败时未设置具体错误信息，根据上下文推断
    private func deriveErrorMessages() {
        guard let visit else { return }

        if visit.transcriptStatus == .unavailable, transcriptError == nil {
            if let path = visit.audioFilePath, !path.isEmpty, !FileManager.default.fileExists(atPath: path) {
                transcriptError = "音频文件已被删除"
            } else if visit.audioFilePath?.isEmpty != false {
                transcriptError = "录音未正常完成"
            } else {
                transcriptError = "ASR 转写失败，可尝试手动重新转写"
            }
        }

        if visit.summaryStatus == .unavailable, summaryError == nil {
            let llmMode = LLMMode(rawValue: UserDefaults.standard.string(forKey: "llm_mode") ?? "") ?? .online
            if llmMode == .online {
                let key = UserDefaults.standard.string(forKey: "llm_key") ?? ""
                if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    summaryError = "未配置 LLM API Key，请在设置中填写"
                } else if visit.transcriptText?.isEmpty != false
                            || visit.transcriptText == "暂时无法获取转写内容" {
                    summaryError = "缺少转写文本，无法生成总结"
                } else {
                    summaryError = "API 调用失败，可尝试手动重新生成"
                }
            } else {
                let modelInfo = LLMModelManager.savedModelInfo()
                if !LLMModelManager.isModelDownloaded(modelInfo) {
                    summaryError = "离线 LLM 模型未下载，请在设置中下载"
                } else if visit.transcriptText?.isEmpty != false
                            || visit.transcriptText == "暂时无法获取转写内容" {
                    summaryError = "缺少转写文本，无法生成总结"
                } else {
                    summaryError = "离线推理失败，可尝试手动重新生成"
                }
            }
        }
    }

    /// 如果转写或总结还在处理中，定时刷新
    private func scheduleNextRefreshIfNeeded() {
        refreshTimer?.cancel()
        guard let visit else { return }

        let needsRefresh = visit.transcriptStatus == .processing
            || visit.summaryStatus == .processing
            || visit.transcriptStatus == .pending

        if needsRefresh {
            refreshTimer = Timer.publish(every: 2, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.refresh()
                }
        }
    }

    /// 加载音频文件到播放器（已加载则跳过，避免重复打断播放状态）
    private func loadAudioIfNeeded() {
        guard let path = visit?.audioFilePath, !path.isEmpty else { return }
        guard loadedAudioPath != path else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        loadedAudioPath = path
        audioPlayer.load(url: url)
    }

    /// 格式化时长 (mm:ss)
    func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static func localDateString() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return fmt.string(from: Date())
    }

    // MARK: - 手动重试

    func retryTranscript() {
        guard let id = currentVisitId, !isRetryingTranscript else { return }

        let audioPath = visit?.audioFilePath ?? ""

        // 1. 检查音频文件
        guard !audioPath.isEmpty else {
            transcriptError = "没有关联的音频文件，无法重新转写"
            return
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            transcriptError = "音频文件不存在或已被删除"
            return
        }

        // 2. 读取当前 ASR 模式设置（实时读取，确保设置变更生效）
        let asrMode = ASRMode(rawValue: UserDefaults.standard.string(forKey: "asr_mode") ?? "") ?? .online

        switch asrMode {
        case .online:
            retryTranscriptOnline(id: id, audioPath: audioPath)
        case .offline:
            retryTranscriptOffline(id: id, audioPath: audioPath)
        }
    }

    private func retryTranscriptOnline(id: UUID, audioPath: String) {
        let asrURL = UserDefaults.standard.string(forKey: "asr_url") ?? "ws://192.168.1.110:10095"
        let asrClient = container.asrClient
        let repository = container.recordRepository

        isRetryingTranscript = true
        transcriptError = nil

        Task {
            let pcmData = Self.readPCMFromWAV(at: audioPath)
            guard let pcmData, !pcmData.isEmpty else {
                transcriptError = "音频文件损坏或为空，无法读取 PCM 数据"
                isRetryingTranscript = false
                refresh()
                return
            }

            let result = await asrClient.processPCMChunk(
                pcmData: pcmData, serverUrl: asrURL,
                wavName: "retry-\(id.uuidString.prefix(8))"
            )

            await handleTranscriptResult(id: id, result: result, repository: repository)
        }
    }

    private func retryTranscriptOffline(id: UUID, audioPath: String) {
        let quality = ModelDownloadManager.savedQuality()
        guard ModelDownloadManager.isModelDownloaded(quality) else {
            transcriptError = "离线 ASR 模型未下载，请在设置中下载后重试"
            return
        }

        let offlineClient = container.offlineASRClient
        let repository = container.recordRepository

        isRetryingTranscript = true
        transcriptError = nil

        Task {
            // 模型加载放在后台 Task 中，避免阻塞主线程
            do {
                try offlineClient.ensureRecognizer(quality: quality)
            } catch {
                transcriptError = "离线 ASR 模型加载失败: \(error.localizedDescription)"
                isRetryingTranscript = false
                refresh()
                return
            }

            let pcmData = Self.readPCMFromWAV(at: audioPath)
            guard let pcmData, !pcmData.isEmpty else {
                transcriptError = "音频文件损坏或为空，无法读取 PCM 数据"
                isRetryingTranscript = false
                refresh()
                return
            }

            let result = await offlineClient.processPCMChunk(pcmData: pcmData)

            await handleTranscriptResult(id: id, result: result, repository: repository)
        }
    }

    /// 从 WAV 文件读取 PCM 数据（跳过 44 字节头部）
    private static func readPCMFromWAV(at path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        _ = try? handle.read(upToCount: 44)
        var data = Data()
        while let chunk = try? handle.read(upToCount: 64_000), !chunk.isEmpty {
            data.append(chunk)
        }
        return data
    }

    /// 统一处理转写结果（在线/离线共用）
    private func handleTranscriptResult(id: UUID, result: Result<String, Error>, repository: RecordRepository) async {
        if case .success(let text) = result, !text.isEmpty {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("audio/\(id.uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dateStr = Self.localDateString()
            let fileURL = dir.appendingPathComponent("\(dateStr).txt")
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)

            try? await repository.updateTranscript(id, text: text, filePath: fileURL.path)
            try? await repository.updateTranscriptStatus(id, status: .completed)
            transcriptError = nil
            // 新成功，删旧文件
            if let oldPath = visit?.transcriptFilePath, !oldPath.isEmpty, oldPath != fileURL.path {
                try? FileManager.default.removeItem(atPath: oldPath)
            }
        } else {
            transcriptError = "ASR 转写失败"
            if case .failure(let error) = result {
                transcriptError = error.localizedDescription
            }
            try? await repository.updateTranscriptStatus(id, status: .unavailable)
        }

        isRetryingTranscript = false
        refresh()
    }

    func retrySummary() {
        guard let id = currentVisitId, !isRetryingSummary else { return }

        // 1. 检查是否有转写文本
        let transcript = visit?.transcriptText ?? ""
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summaryError = "没有转写文本，无法生成总结"
            return
        }
        // 排除占位文本
        guard transcript != "暂时无法获取转写内容" else {
            summaryError = "转写未成功，无法生成总结"
            return
        }

        // 2. 读取 LLM 模式
        let llmMode = LLMMode(rawValue: UserDefaults.standard.string(forKey: "llm_mode") ?? "") ?? .online

        switch llmMode {
        case .online:
            // 检查在线 LLM 配置
            let llmURL = UserDefaults.standard.string(forKey: "llm_url") ?? "https://api.deepseek.com"
            let llmKey = UserDefaults.standard.string(forKey: "llm_key") ?? ""
            let llmModel = UserDefaults.standard.string(forKey: "llm_model") ?? "deepseek-v4-pro"

            guard !llmURL.isEmpty, !llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                summaryError = "未配置 LLM API Key，请在设置中填写"
                return
            }

            let llmClient = container.llmClient
            let repository = container.recordRepository

            isRetryingSummary = true
            summaryError = nil

            Task {
                let summaryResult = await llmClient.generateSummary(
                    transcript: transcript, apiUrl: llmURL, apiKey: llmKey,
                    model: llmModel, customPrompt: nil
                )

                if case .success(let summary) = summaryResult {
                    try? await repository.updateSummary(id, summary: summary)
                    summaryError = nil
                } else {
                    summaryError = "AI 总结生成失败"
                    if case .failure(let error) = summaryResult {
                        summaryError = error.localizedDescription
                    }
                    try? await repository.updateSummaryStatus(id, status: .unavailable)
                }

                isRetryingSummary = false
                refresh()
            }

        case .offline:
            let modelInfo = LLMModelManager.savedModelInfo()
            guard LLMModelManager.isModelDownloaded(modelInfo) else {
                summaryError = "离线模型未下载，请在设置中下载后重试"
                return
            }

            let offlineClient = container.offlineLLMClient
            let repository = container.recordRepository

            isRetryingSummary = true
            summaryError = nil

            Task {
                let summaryResult = await offlineClient.generateSummary(
                    transcript: transcript,
                    modelInfo: modelInfo,
                    customPrompt: nil
                )

                if case .success(let summary) = summaryResult {
                    try? await repository.updateSummary(id, summary: summary)
                    summaryError = nil
                } else {
                    summaryError = "离线总结生成失败"
                    if case .failure(let error) = summaryResult {
                        summaryError = error.localizedDescription
                    }
                    try? await repository.updateSummaryStatus(id, status: .unavailable)
                }

                isRetryingSummary = false
                refresh()
            }
        }
    }
}
