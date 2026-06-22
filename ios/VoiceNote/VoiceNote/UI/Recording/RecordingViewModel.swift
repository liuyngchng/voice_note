import AVFoundation
import Combine
import Foundation

@MainActor
final class RecordingViewModel: ObservableObject {
    // MARK: - 表单字段

    @Published var title = ""
    @Published var notes = ""
    @Published var description = ""
    @Published var participants = ""

    // MARK: - 录音状态

    @Published var isRecording = false
    @Published var transcript = ""
    @Published var durationSeconds: TimeInterval = 0
    @Published var phase: RecordingManager.RecordingPhase = .idle
    @Published var isStarting = false
    @Published var isStopping = false
    @Published var isImporting = false
    @Published var showFilePicker = false
    @Published var importCompleted = false
    @Published var errorMessage: String?

    // MARK: - 依赖

    private let container: AppContainer
    private let recordingManager: RecordingManager

    var currentVisitId: UUID?
    private var hasStopped = false
    /// 结束录音后是否自动跳转到详情页
    var shouldNavigateToDetail = false

    init(container: AppContainer) {
        self.container = container
        self.recordingManager = container.recordingManager
    }

    func startVisit() {
        // 检查麦克风权限
        let micPermission = AVAudioSession.sharedInstance().recordPermission
        switch micPermission {
        case .denied:
            errorMessage = "麦克风权限已被拒绝。请前往 设置 > 隐私 > 麦克风 中开启。"
            return
        case .granted:
            break
        case .undetermined:
            break
        @unknown default:
            break
        }

        // 标题为空时自动生成（类似 iOS 语音备忘录）
        let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? Self.defaultTitle()
            : title

        Task {
            await MainActor.run {
                isStarting = true
            }
            defer { Task { @MainActor in isStarting = false } }

            // 获取设置
            let llmURL = UserDefaults.standard.string(forKey: "llm_url") ?? "https://api.deepseek.com"
            let llmKey = UserDefaults.standard.string(forKey: "llm_key") ?? ""
            let llmModel = UserDefaults.standard.string(forKey: "llm_model") ?? "deepseek-v4-pro"
            let asrURL = UserDefaults.standard.string(forKey: "asr_url") ?? "ws://192.168.1.110:10095"
            let asrMode = ASRMode(rawValue: UserDefaults.standard.string(forKey: "asr_mode") ?? "") ?? .online
            let llmMode = LLMMode(rawValue: UserDefaults.standard.string(forKey: "llm_mode") ?? "") ?? .online

            let record = VoiceRecord(
                title: finalTitle,
                memo: notes,
                desc: description,
                speakers: participants
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )

            do {
                let recordId = try await container.recordRepository.createRecord(record)
                currentVisitId = recordId

                // 标记为待处理
                try? await container.recordRepository.updateTranscriptStatus(recordId, status: .pending)
                try? await container.recordRepository.updateSummaryStatus(recordId, status: .pending)

                // 开始写音频文件（仅调用一次，pcmURL 由 RecordingManager 内部持有）
                _ = recordingManager.startWritingAudio(recordId: recordId)

                // 启动录音（ASR + 音频流）
                recordingManager.startRecording(
                    recordId: recordId,
                    asrURL: asrURL,
                    llmURL: llmURL,
                    llmKey: llmKey,
                    llmModel: llmModel,
                    asrMode: asrMode,
                    llmMode: llmMode
                )

                // 绑定状态轮询
                observeRecordingState()

            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func observeRecordingState() {
        isRecording = true

        // 用 Timer 轮询方式简绑定
        Task {
            await MainActor.run {
                isRecording = true
            }
            while true {
                let rec = await MainActor.run { recordingManager.isRecording }
                if !rec { break }
                await MainActor.run {
                    transcript = recordingManager.transcript
                    durationSeconds = recordingManager.durationSeconds
                    phase = recordingManager.phase
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await MainActor.run {
                isRecording = false
            }
            // 音频定稿和路径更新已移至 RecordingManager.stopRecording() 内部处理
        }
    }

    func stopVisit(navigateToDetail: Bool = false) {
        guard !hasStopped else { return }
        hasStopped = true
        shouldNavigateToDetail = navigateToDetail
        isStopping = true
        recordingManager.stopRecording()
        // 立即返回主界面
        isRecording = false
        isStopping = false
    }

    // MARK: - 导入音频

    func importAudio(from sourceURL: URL) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil

        Task {
            defer { Task { @MainActor in isImporting = false } }

            // 1. 转换格式
            guard let wavURL = AudioConverter.convertToWav(sourceURL: sourceURL) else {
                await MainActor.run { errorMessage = "音频格式转换失败" }
                return
            }
            defer { try? FileManager.default.removeItem(at: wavURL) }

            // 2. 创建记录
            let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
                ? Self.defaultTitle()
                : title

            let record = VoiceRecord(
                title: finalTitle,
                memo: notes,
                desc: description,
                speakers: participants
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )

            do {
                let recordId = try await container.recordRepository.createRecord(record)
                currentVisitId = recordId

                // 3. 把 WAV 复制到录音目录
                let audioDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("audio/\(recordId.uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
                let dateStr = Self.localDateString()
                let destURL = audioDir.appendingPathComponent("\(dateStr).wav")
                try? FileManager.default.copyItem(at: wavURL, to: destURL)

                // 4. 更新 DB
                try? await container.recordRepository.updateTranscriptStatus(recordId, status: .pending)
                try? await container.recordRepository.updateSummaryStatus(recordId, status: .pending)
                try? await container.recordRepository.updateAudioFilePath(recordId, path: destURL.path, endTime: Date())

                // 5. 启动 ASR 处理
                let asrURL = UserDefaults.standard.string(forKey: "asr_url") ?? "ws://192.168.1.110:10095"
                let asrMode = ASRMode(rawValue: UserDefaults.standard.string(forKey: "asr_mode") ?? "") ?? .online
                let llmMode = LLMMode(rawValue: UserDefaults.standard.string(forKey: "llm_mode") ?? "") ?? .online
                let llmURL = UserDefaults.standard.string(forKey: "llm_url") ?? "https://api.deepseek.com"
                let llmKey = UserDefaults.standard.string(forKey: "llm_key") ?? ""
                let llmModel = UserDefaults.standard.string(forKey: "llm_model") ?? "deepseek-v4-pro"

                // 读 PCM 数据并直接发 ASR（不经过录音流程）
                if let handle = FileHandle(forReadingAtPath: destURL.path) {
                    defer { try? handle.close() }
                    _ = try? handle.read(upToCount: 44)
                    var pcmData = Data()
                    while let chunk = try? handle.read(upToCount: 64_000), !chunk.isEmpty {
                        pcmData.append(chunk)
                    }
                    if !pcmData.isEmpty {
                        let repository = container.recordRepository
                        try? await repository.updateTranscriptStatus(recordId, status: .processing)

                        let result: Result<String, Error>
                        switch asrMode {
                        case .online:
                            result = await container.asrClient.processPCMChunk(
                                pcmData: pcmData, serverUrl: asrURL,
                                wavName: "import-\(recordId.uuidString.prefix(8))"
                            )
                        case .offline:
                            let quality = ModelDownloadManager.savedQuality()
                            if ModelDownloadManager.isModelDownloaded(quality) {
                                do {
                                    try container.offlineASRClient.ensureRecognizer(quality: quality)
                                    result = await container.offlineASRClient.processPCMChunk(pcmData: pcmData)
                                } catch {
                                    result = .failure(error)
                                }
                            } else {
                                result = .failure(OfflineASRError.modelNotDownloaded(quality))
                            }
                        }
                        if case .success(let text) = result, !text.isEmpty {
                            let txtURL = audioDir.appendingPathComponent("\(dateStr).txt")
                            try? text.write(to: txtURL, atomically: true, encoding: .utf8)
                            try? await repository.updateTranscript(recordId, text: text, filePath: txtURL.path)
                            try? await repository.updateTranscriptStatus(recordId, status: .completed)

                            // LLM 总结
                            switch llmMode {
                            case .online:
                                if !llmURL.isEmpty, !llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    try? await repository.updateSummaryStatus(recordId, status: .processing)
                                    let delays: [TimeInterval] = [5, 10, 20, 40, 80]
                                    var summaryResult: Result<RecordSummary, Error> = .failure(LLMError.parseFailed(""))
                                    let llmClient = container.llmClient
                                    for (i, delay) in delays.enumerated() {
                                        if i > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                                        let r = await llmClient.generateSummary(
                                            transcript: text, apiUrl: llmURL, apiKey: llmKey,
                                            model: llmModel, customPrompt: nil
                                        )
                                        if case .success = r { summaryResult = r; break }
                                    }
                                    if case .success(let summary) = summaryResult {
                                        try? await repository.updateSummary(recordId, summary: summary)
                                    } else {
                                        try? await repository.updateSummaryStatus(recordId, status: .unavailable)
                                    }
                                } else {
                                    try? await repository.updateSummaryStatus(recordId, status: .unavailable)
                                }
                            case .offline:
                                let modelInfo = LLMModelManager.savedModelInfo()
                                if LLMModelManager.isModelDownloaded(modelInfo) {
                                    try? await repository.updateSummaryStatus(recordId, status: .processing)
                                    let summaryResult = await container.offlineLLMClient.generateSummary(
                                        transcript: text,
                                        modelInfo: modelInfo,
                                        customPrompt: nil
                                    )
                                    if case .success(let summary) = summaryResult {
                                        try? await repository.updateSummary(recordId, summary: summary)
                                    } else {
                                        try? await repository.updateSummaryStatus(recordId, status: .unavailable)
                                    }
                                } else {
                                    try? await repository.updateSummaryStatus(recordId, status: .unavailable)
                                }
                            }
                        } else {
                            try? await repository.updateTranscriptStatus(recordId, status: .unavailable)
                            try? await repository.updateSummaryStatus(recordId, status: .unavailable)
                        }
                    }
                }

                // 回到首页
                await MainActor.run {
                    shouldNavigateToDetail = false
                    isRecording = false
                    importCompleted = true
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private static func localDateString() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return fmt.string(from: Date())
    }

    /// 默认标题：新录音 6月20日 09:41
    private static func defaultTitle() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return "新录音 \(fmt.string(from: Date()))"
    }
}
