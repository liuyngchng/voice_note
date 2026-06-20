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
                    llmModel: llmModel
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

    /// 默认标题：新录音 6月20日 09:41
    private static func defaultTitle() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return "新录音 \(fmt.string(from: Date()))"
    }
}
