import CoreData
import Foundation

/// 拜访数据仓库实现
/// 对齐 Android: VisitRepositoryImpl.kt
final class VisitRepositoryImpl: VisitRepository {
    private let container: AppContainer
    private let context: NSManagedObjectContext

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(container: AppContainer) {
        self.container = container
        self.context = container.persistence.container.viewContext
    }

    func createVisit(_ visit: Visit) async throws -> UUID {
        let entity = VisitEntity(context: context)
        entity.id = visit.id
        entity.clientName = visit.clientName
        entity.clientCompany = visit.clientCompany
        entity.purpose = visit.purpose
        entity.participantsJSON = try? encoder.encodeString(visit.participants)
        entity.startTime = visit.startTime
        entity.transcriptStatus = visit.transcriptStatus.rawValue
        entity.summaryStatus = visit.summaryStatus.rawValue

        try context.save()
        return visit.id
    }

    func updateAudioFilePath(_ visitId: UUID, path: String, endTime: Date, locationPoints: [LocationPoint]) async throws {
        guard let entity = try fetchEntity(id: visitId) else { return }
        entity.audioFilePath = path
        entity.endTime = endTime
        entity.locationPointsJSON = try? encoder.encodeString(locationPoints)
        try context.save()
    }

    func updateTranscript(_ visitId: UUID, text: String, filePath: String) async throws {
        guard let entity = try fetchEntity(id: visitId) else { return }
        entity.transcriptText = text
        entity.transcriptFilePath = filePath
        try context.save()
    }

    func updateTranscriptStatus(_ visitId: UUID, status: ProcessingStatus) async throws {
        guard let entity = try fetchEntity(id: visitId) else { return }
        entity.transcriptStatus = status.rawValue
        try context.save()
    }

    func updateSummary(_ visitId: UUID, summary: VisitSummary) async throws {
        guard let entity = try fetchEntity(id: visitId) else { return }
        entity.summaryJSON = try? encoder.encodeString(summary)
        entity.summaryStatus = ProcessingStatus.completed.rawValue
        try context.save()
    }

    func updateSummaryStatus(_ visitId: UUID, status: ProcessingStatus) async throws {
        guard let entity = try fetchEntity(id: visitId) else { return }
        entity.summaryStatus = status.rawValue
        try context.save()
    }

    func getVisit(id: UUID) async throws -> Visit? {
        guard let entity = try fetchEntity(id: id) else { return nil }
        return mapEntity(entity)
    }

    func getAllVisits() async throws -> [Visit] {
        let request = VisitEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \VisitEntity.startTime, ascending: false)]
        let entities = try context.fetch(request) as! [VisitEntity]
        return entities.map(mapEntity)
    }

    func searchVisits(query: String) async throws -> [Visit] {
        let request = VisitEntity.fetchRequest()
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "clientName CONTAINS[cd] %@", query),
            NSPredicate(format: "clientCompany CONTAINS[cd] %@", query)
        ])
        request.sortDescriptors = [NSSortDescriptor(keyPath: \VisitEntity.startTime, ascending: false)]
        let entities = try context.fetch(request) as! [VisitEntity]
        return entities.map(mapEntity)
    }

    func deleteVisit(id: UUID) async throws {
        guard let entity = try fetchEntity(id: id) else { return }

        // 清理磁盘上的音频文件和转写文件
        if let audioPath = entity.audioFilePath, !audioPath.isEmpty {
            let dir = URL(fileURLWithPath: audioPath).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
        }

        context.delete(entity)
        try context.save()
    }

    // MARK: - 私有

    private func fetchEntity(id: UUID) throws -> VisitEntity? {
        let request = VisitEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first as? VisitEntity
    }

    private func mapEntity(_ e: VisitEntity) -> Visit {
        Visit(
            id: e.id,
            clientName: e.clientName,
            clientCompany: e.clientCompany ?? "",
            purpose: e.purpose ?? "",
            participants: (try? decoder.decode([String].self, from: e.participantsJSON)) ?? [],
            startTime: e.startTime,
            endTime: e.endTime,
            locationPoints: (try? decoder.decode([LocationPoint].self, from: e.locationPointsJSON)) ?? [],
            transcriptText: e.transcriptText,
            transcriptFilePath: e.transcriptFilePath,
            transcriptStatus: ProcessingStatus(rawValue: e.transcriptStatus) ?? .pending,
            summaryStatus: ProcessingStatus(rawValue: e.summaryStatus) ?? .pending,
            audioFilePath: e.audioFilePath,
            summary: (try? decoder.decode(VisitSummary.self, from: e.summaryJSON))
        )
    }
}

// MARK: - JSON 编解码扩展

private extension JSONEncoder {
    func encodeString<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension JSONDecoder {
    func decode<T: Decodable>(_ type: T.Type, from string: String?) throws -> T {
        guard let string, let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Empty JSON string"))
        }
        return try decode(type, from: data)
    }
}
