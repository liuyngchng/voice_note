import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var records: [VoiceRecord] = []
    @Published var isLoading = false

    private let container: AppContainer

    /// 有录音文件的记录
    private var recordedRecords: [VoiceRecord] {
        records.filter { record in
            guard let path = record.audioFilePath, !path.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    // 统计数据
    var todayRecordCount: Int {
        let calendar = Calendar.current
        return recordedRecords.filter { calendar.isDateInToday($0.startTime) }.count
    }

    /// 总录音记录数
    var totalRecordCount: Int {
        recordedRecords.count
    }

    var recentRecords: [VoiceRecord] {
        Array(records.prefix(2))
    }

    init(container: AppContainer) {
        self.container = container
    }

    func loadRecords() {
        Task {
            // 先恢复崩溃前未完成的录音
            await container.recordingManager.recoverUnfinishedRecords()

            let result = try? await container.recordRepository.getAllRecords()
            await MainActor.run {
                records = result ?? []
            }
        }
    }

    func deleteRecord(id: UUID) {
        Task {
            try? await container.recordRepository.deleteRecord(id: id)
            await MainActor.run {
                records.removeAll { $0.id == id }
            }
        }
    }
}
