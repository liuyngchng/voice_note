import Combine
import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var visits: [Visit] = []
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
            let result: [Visit]
            if searchQuery.isEmpty {
                result = (try? await container.visitRepository.getAllVisits()) ?? []
            } else {
                result = (try? await container.visitRepository.searchVisits(query: searchQuery)) ?? []
            }
            await MainActor.run {
                visits = result
                isLoading = false
            }
        }
    }

    func loadAll() {
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
