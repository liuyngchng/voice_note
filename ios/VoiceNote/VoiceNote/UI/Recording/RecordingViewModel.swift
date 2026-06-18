import Combine
import Foundation

@MainActor
final class RecordingViewModel: ObservableObject {
    // MARK: - 表单字段

    @Published var clientName = ""
    @Published var clientCompany = ""
    @Published var purpose = ""
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

    init(container: AppContainer) {
        self.container = container
        self.recordingManager = RecordingManager(container: container)
    }

    func startVisit() {
        guard !clientName.isEmpty else {
            errorMessage = "请输入客户名称"
            return
        }

        Task {
            await MainActor.run {
                isStarting = true
            }
            defer { Task { @MainActor in isStarting = false } }

            // 获取设置
            let llmURL = UserDefaults.standard.string(forKey: "llm_url") ?? ""
            let llmKey = UserDefaults.standard.string(forKey: "llm_key") ?? ""
            let llmModel = UserDefaults.standard.string(forKey: "llm_model") ?? "deepseek-v4-pro"
            let asrURL = UserDefaults.standard.string(forKey: "asr_url") ?? ""

            let visit = Visit(
                clientName: clientName,
                clientCompany: clientCompany,
                purpose: purpose,
                participants: participants
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )

            do {
                let visitId = try await container.visitRepository.createVisit(visit)
                currentVisitId = visitId

                // 开始写音频文件（仅调用一次，pcmURL 由 RecordingManager 内部持有）
                _ = recordingManager.startWritingAudio(visitId: visitId)

                // 启动录音（ASR + 音频流）
                recordingManager.startRecording(
                    visitId: visitId,
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

    func stopVisit() {
        isStopping = true
        recordingManager.stopRecording()
    }
}
