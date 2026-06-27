import AVFoundation
import Combine
import Foundation

@MainActor
final class RecordingViewModel: ObservableObject {
    // MARK: - 录音状态

    @Published var isRecording = false
    @Published var transcript = ""
    @Published var durationSeconds: TimeInterval = 0
    @Published var phase: RecordingManager.RecordingPhase = .idle
    @Published var isStarting = false
    @Published var isStopping = false
    @Published var errorMessage: String?

    // MARK: - 依赖

    private let container: AppContainer
    private let recordingManager: RecordingManager

    var currentVisitId: UUID?
    private var hasStopped = false
    var shouldNavigateToDetail = false

    init(container: AppContainer) {
        self.container = container
        self.recordingManager = container.recordingManager
    }

    /// 点击 + 按钮直接开始录音（无需表单）
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

        let finalTitle = Self.defaultTitle()

        Task {
            await MainActor.run {
                isStarting = true
            }
            defer { Task { @MainActor in isStarting = false } }

            // 检查离线 ASR 模型是否已下载
            let quality = ASRModelManager.savedQuality()
            guard ASRModelManager.isModelDownloaded(quality) else {
                await MainActor.run {
                    errorMessage = "离线语音模型未下载，请先在设置中下载 SenseVoice 模型"
                }
                return
            }

            let record = VoiceRecord(
                title: finalTitle,
                memo: "",
                desc: "",
                speakers: []
            )

            do {
                let recordId = try await container.recordRepository.createRecord(record)
                currentVisitId = recordId

                try? await container.recordRepository.updateTranscriptStatus(recordId, status: .pending)

                // 开始写音频文件
                _ = recordingManager.startWritingAudio(recordId: recordId)

                // 启动录音（仅离线 ASR）
                recordingManager.startRecording(recordId: recordId)

                // 绑定状态轮询
                observeRecordingState()

            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func observeRecordingState() {
        isRecording = true

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
        }
    }

    func stopVisit(navigateToDetail: Bool = false) {
        guard !hasStopped else { return }
        hasStopped = true
        shouldNavigateToDetail = navigateToDetail
        isStopping = true
        recordingManager.stopRecording()
        isRecording = false
        isStopping = false
    }

    private static func localDateString() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return fmt.string(from: Date())
    }

    private static func defaultTitle() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return "新录音 \(fmt.string(from: Date()))"
    }
}
