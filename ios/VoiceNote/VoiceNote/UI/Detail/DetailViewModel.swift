import Combine
import Foundation

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var visit: VoiceRecord?
    @Published var isLoading = true
    @Published var isRetryingTranscript = false
    @Published var isRetryingSummary = false

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

    // MARK: - 手动重试

    func retryTranscript() {
        guard let id = currentVisitId,
              let audioPath = visit?.audioFilePath, !audioPath.isEmpty,
              !isRetryingTranscript
        else { return }

        let asrURL = UserDefaults.standard.string(forKey: "asr_url") ?? "ws://192.168.1.110:10095"
        let asrClient = container.asrClient
        let repository = container.recordRepository

        isRetryingTranscript = true

        Task {
            // 从 WAV 文件读取 PCM 数据
            var pcmData = Data()
            if let handle = FileHandle(forReadingAtPath: audioPath) {
                defer { try? handle.close() }
                _ = try? handle.read(upToCount: 44)
                while let chunk = try? handle.read(upToCount: 64_000), !chunk.isEmpty {
                    pcmData.append(chunk)
                }
            }

            guard !pcmData.isEmpty else {
                isRetryingTranscript = false
                try? await repository.updateTranscriptStatus(id, status: .unavailable)
                refresh()
                return
            }

            try? await repository.updateTranscriptStatus(id, status: .processing)
            refresh()

            let result = await asrClient.processPCMChunk(
                pcmData: pcmData, serverUrl: asrURL,
                wavName: "retry-\(id.uuidString.prefix(8))"
            )

            if case .success(let text) = result, !text.isEmpty {
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("audio/\(id.uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dateStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let fileURL = dir.appendingPathComponent("\(dateStr).txt")
                try? text.write(to: fileURL, atomically: true, encoding: .utf8)

                try? await repository.updateTranscript(id, text: text, filePath: fileURL.path)
                try? await repository.updateTranscriptStatus(id, status: .completed)
            } else {
                try? await repository.updateTranscriptStatus(id, status: .unavailable)
            }

            isRetryingTranscript = false
            refresh()
        }
    }

    func retrySummary() {
        guard let id = currentVisitId,
              let transcript = visit?.transcriptText,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isRetryingSummary
        else { return }

        let llmURL = UserDefaults.standard.string(forKey: "llm_url") ?? "https://api.deepseek.com"
        let llmKey = UserDefaults.standard.string(forKey: "llm_key") ?? ""
        let llmModel = UserDefaults.standard.string(forKey: "llm_model") ?? "deepseek-v4-pro"

        guard !llmURL.isEmpty, !llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let llmClient = container.llmClient
        let repository = container.recordRepository

        isRetryingSummary = true

        Task {
            try? await repository.updateSummaryStatus(id, status: .processing)
            refresh()

            let summaryResult = await llmClient.generateSummary(
                transcript: transcript, apiUrl: llmURL, apiKey: llmKey,
                model: llmModel, customPrompt: nil
            )

            if case .success(let summary) = summaryResult {
                try? await repository.updateSummary(id, summary: summary)
            } else {
                try? await repository.updateSummaryStatus(id, status: .unavailable)
            }

            isRetryingSummary = false
            refresh()
        }
    }
}
