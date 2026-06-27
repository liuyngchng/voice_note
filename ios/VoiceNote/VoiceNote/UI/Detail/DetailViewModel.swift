import Combine
import Foundation

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var visit: VoiceRecord?
    @Published var isLoading = true
    @Published var isRetryingTranscript = false
    @Published var transcriptError: String?

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

    private func deriveErrorMessages() {
        guard let visit else { return }

        if visit.transcriptStatus == .unavailable, transcriptError == nil {
            if let path = visit.audioFilePath, !path.isEmpty, !FileManager.default.fileExists(atPath: path) {
                transcriptError = "音频文件已被删除"
            } else if visit.audioFilePath?.isEmpty != false {
                transcriptError = "录音未正常完成"
            } else {
                transcriptError = "离线转写失败，可尝试手动重新转写"
            }
        }
    }

    private func scheduleNextRefreshIfNeeded() {
        refreshTimer?.cancel()
        guard let visit else { return }

        let needsRefresh = visit.transcriptStatus == .processing
            || visit.transcriptStatus == .pending

        if needsRefresh {
            refreshTimer = Timer.publish(every: 2, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.refresh()
                }
        }
    }

    private func loadAudioIfNeeded() {
        guard let path = visit?.audioFilePath, !path.isEmpty else { return }
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
        guard let id = currentVisitId, !isRetryingTranscript else { return }

        let audioPath = visit?.audioFilePath ?? ""

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

                try? await repository.updateTranscript(id, text: text, filePath: fileURL.path)
                try? await repository.updateTranscriptStatus(id, status: .completed)
                transcriptError = nil
                if let oldPath = visit?.transcriptFilePath, !oldPath.isEmpty, oldPath != fileURL.path {
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
