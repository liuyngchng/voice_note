import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var visits: [Visit] = []
    @Published var isLoading = false

    private let container: AppContainer

    /// 有录音文件的记录（真正完成了录音的拜访）
    private var recordedVisits: [Visit] {
        visits.filter { visit in
            guard let path = visit.audioFilePath, !path.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    // 统计数据
    var todayVisitCount: Int {
        let calendar = Calendar.current
        return recordedVisits.filter { calendar.isDateInToday($0.startTime) }.count
    }

    /// 总录音记录数
    var totalRecordCount: Int {
        recordedVisits.count
    }

    var recentVisits: [Visit] {
        Array(visits.prefix(5))
    }

    init(container: AppContainer) {
        self.container = container
    }

    func loadVisits() {
        Task {
            let result = try? await container.visitRepository.getAllVisits()
            await MainActor.run {
                visits = result ?? []
            }
        }
    }

    func deleteVisit(id: UUID) {
        Task {
            try? await container.visitRepository.deleteVisit(id: id)
            await MainActor.run {
                visits.removeAll { $0.id == id }
            }
        }
    }
}
