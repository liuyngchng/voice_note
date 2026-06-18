import Combine
import Foundation

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var visit: Visit?
    @Published var isLoading = true

    let audioPlayer = AudioPlayer()

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    func loadVisit(id: UUID) {
        Task {
            let result = try? await container.visitRepository.getVisit(id: id)
            await MainActor.run {
                visit = result
                isLoading = false
                loadAudioIfNeeded()
            }
        }
    }

    /// 加载音频文件到播放器
    private func loadAudioIfNeeded() {
        guard let path = visit?.audioFilePath, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        audioPlayer.load(url: url)
    }

    /// 格式化时长 (mm:ss)
    func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
