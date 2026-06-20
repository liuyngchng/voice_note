import Combine
import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var records: [VoiceRecord] = []
    @Published var searchQuery = ""
    @Published var isLoading = false

    let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    func search() {
        Task {
            isLoading = true
            defer { Task { @MainActor in isLoading = false } }
            let result: [VoiceRecord]
            if searchQuery.isEmpty {
                result = (try? await container.recordRepository.getAllRecords()) ?? []
            } else {
                result = (try? await container.recordRepository.searchRecords(query: searchQuery)) ?? []
            }
            await MainActor.run {
                records = result
                isLoading = false
            }
        }
    }

    func loadAll() {
        Task {
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

    func deleteAll() {
        Task {
            try? await container.recordRepository.deleteAllRecords()
            await MainActor.run {
                records.removeAll()
            }
        }
    }
}
