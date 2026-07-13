import Combine
import Foundation

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var record: VoiceRecord?
    @Published var isLoading = true
    @Published var isRetryingTranscript = false
    @Published var transcriptError: String?
    /// 从 .txt 文件加载的转写文本（DB 不再存储全文）
    @Published var transcriptText: String?

    /// 文本总结状态
    @Published var isGeneratingSummary = false
    @Published var summaryProgressMessage: String?
    @Published var summaryError: String?
    /// 总结导出文件 URL（设置后触发分享 sheet）
    @Published var summaryExportURL: URL?

    @Published var audioPlayer = AudioPlayer()

    private let container: AppContainer
    private var loadedAudioPath: String?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: AnyCancellable?
    private var currentRecordId: UUID?

    init(container: AppContainer) {
        self.container = container
        audioPlayer.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func loadRecord(id: UUID) {
        currentRecordId = id
        refresh()
    }

    private func refresh() {
        guard let id = currentRecordId else { return }
        Task {
            let result = try? await container.recordRepository.getRecord(id: id)
            await MainActor.run {
                record = result
                isLoading = false
                // 从 .txt 文件加载转录文本（DB 不再存储全文）
                loadTranscriptFromFile()
                loadAudioIfNeeded()
                scheduleNextRefreshIfNeeded()
                deriveErrorMessages()
            }
        }
    }

    /// 从 .txt 文件加载转录文本
    private func loadTranscriptFromFile() {
        guard let path = record?.transcriptFilePath, !path.isEmpty else {
            transcriptText = record?.transcriptText  // 兼容旧数据
            return
        }
        transcriptText = try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func deriveErrorMessages() {
        guard let record else { return }

        if record.transcriptStatus == .unavailable, transcriptError == nil {
            if let path = record.audioFilePath, !path.isEmpty, !FileManager.default.fileExists(atPath: path) {
                transcriptError = "音频文件已被删除"
            } else if record.audioFilePath?.isEmpty != false {
                transcriptError = "录音未正常完成"
            } else {
                transcriptError = "离线转写失败，可尝试手动重新转写"
            }
        }
    }

    private func scheduleNextRefreshIfNeeded() {
        refreshTimer?.cancel()
        guard let record else { return }

        let needsRefresh = record.transcriptStatus == .processing
            || record.transcriptStatus == .pending
            || record.summaryStatus == .processing

        if needsRefresh {
            refreshTimer = Timer.publish(every: 2, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.refresh()
                }
        }
    }

    private func loadAudioIfNeeded() {
        guard let path = record?.audioFilePath, !path.isEmpty else { return }
        guard loadedAudioPath != path else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        loadedAudioPath = path
        audioPlayer.load(url: url)
    }

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

    // MARK: - 手动重试转写

    func retryTranscript() {
        guard let id = currentRecordId, !isRetryingTranscript else { return }

        let audioPath = record?.audioFilePath ?? ""

        guard !audioPath.isEmpty else {
            transcriptError = "没有关联的音频文件，无法重新转写"
            return
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            transcriptError = "音频文件不存在或已被删除"
            return
        }

        let quality = ASRModelManager.savedQuality()
        guard ASRModelManager.isModelDownloaded(quality) else {
            transcriptError = "离线 ASR 模型未下载，请在设置中下载后重试"
            return
        }

        let offlineClient = container.offlineASRClient
        let repository = container.recordRepository

        isRetryingTranscript = true
        transcriptError = nil

        Task {
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

            if case .success(let text) = result, !text.isEmpty {
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("audio/\(id.uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dateStr = Self.localDateString()
                let fileURL = dir.appendingPathComponent("\(dateStr).txt")
                try? text.write(to: fileURL, atomically: true, encoding: .utf8)

                try? await repository.updateTranscriptFilePath(id, filePath: fileURL.path)
                try? await repository.updateTranscriptStatus(id, status: .completed)
                transcriptError = nil
                if let oldPath = record?.transcriptFilePath, !oldPath.isEmpty, oldPath != fileURL.path {
                    try? FileManager.default.removeItem(atPath: oldPath)
                }
            } else {
                transcriptError = "离线转写失败"
                if case .failure(let error) = result {
                    transcriptError = error.localizedDescription
                }
                try? await repository.updateTranscriptStatus(id, status: .unavailable)
            }

            isRetryingTranscript = false
            refresh()
        }
    }

    // MARK: - 文本总结（在线 LLM，手动触发）
    // 对齐 Android: DetailViewModel.generateSummary()

    private let onlineLLMClient = OnlineLLMClient()

    func generateSummary() {
        // 防重复点击
        guard !isGeneratingSummary else { return }
        guard let id = currentRecordId else { return }

        // 1. 获取转写文本
        let transcript = transcriptText ?? ""
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summaryError = "没有转写文本，无法生成总结"
            return
        }
        guard transcript != "暂时无法获取转写内容" else {
            summaryError = "转写未成功，无法生成总结"
            return
        }

        // 2. 检查 LLM 配置
        guard !OnlineLLMClient.apiKey.isEmpty else {
            summaryError = "请在设置中配置在线大语言模型的 API Key"
            return
        }

        let repository = container.recordRepository

        Log.llm("[总结] 用户触发在线总结生成: transcript=\(transcript.count) chars")
        isGeneratingSummary = true
        summaryProgressMessage = "正在连接 LLM..."
        summaryError = nil

        // 3. 先更新状态为 processing
        Task {
            try? await repository.updateSummaryStatus(id, status: .processing)
        }

        // 4. 执行在线推理（带进度回调）
        Task { [weak self] in
            guard let self else { return }

            let summaryResult = await onlineLLMClient.generateSummary(
                transcript: transcript,
                customPrompt: nil,
                onProgress: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.summaryProgressMessage = message
                    }
                }
            )

            await MainActor.run {
                if case .success(let summary) = summaryResult {
                    Task {
                        try? await repository.updateSummary(id, summary: summary)
                        await MainActor.run {
                            self.summaryError = nil
                            self.isGeneratingSummary = false
                            self.summaryProgressMessage = nil
                            self.refresh()
                        }
                    }
                } else {
                    let errorMessage: String
                    if case .failure(let error) = summaryResult {
                        errorMessage = error.localizedDescription
                    } else {
                        errorMessage = "在线总结生成失败"
                    }
                    self.summaryError = errorMessage
                    self.isGeneratingSummary = false
                    self.summaryProgressMessage = nil
                    Task {
                        try? await repository.updateSummaryStatus(id, status: .unavailable)
                        await MainActor.run { self.refresh() }
                    }
                }
            }
        }
    }

    // MARK: - 导出总结

    func exportSummary() {
        guard let summary = record?.summary else { return }
        let text = formatSummaryAsText(summary)
        guard !text.isEmpty else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "总结_\(record?.title ?? "untitled").txt"
            .replacingOccurrences(of: "/", with: "_")
        let fileURL = tempDir.appendingPathComponent(fileName)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        summaryExportURL = fileURL
    }

    private func formatSummaryAsText(_ summary: RecordSummary) -> String {
        var lines: [String] = []
        if !summary.topics.isEmpty {
            lines.append("【议题】")
            lines.append(contentsOf: summary.topics.map { "  • \($0)" })
            lines.append("")
        }
        if !summary.conclusions.isEmpty {
            lines.append("【结论】")
            lines.append(contentsOf: summary.conclusions.map { "  • \($0)" })
            lines.append("")
        }
        if !summary.todos.isEmpty {
            lines.append("【待办】")
            for todo in summary.todos {
                var parts = "  • \(todo.task)"
                if !todo.owner.isEmpty { parts += "（\(todo.owner)）" }
                if !todo.deadline.isEmpty { parts += " 截止: \(todo.deadline)" }
                lines.append(parts)
            }
            lines.append("")
        }
        if !summary.nextSteps.isEmpty {
            lines.append("【后续步骤】")
            lines.append(contentsOf: summary.nextSteps.map { "  • \($0)" })
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

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
}
