import CoreData
import Foundation

/// 数据仓库实现
/// 对齐 Android: VisitRepositoryImpl.kt
final class RecordRepositoryImpl: RecordRepository {
    private let container: AppContainer
    private let context: NSManagedObjectContext

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(container: AppContainer) {
        self.container = container
        self.context = container.persistence.container.viewContext
    }

    func createRecord(_ record: VoiceRecord) async throws -> UUID {
        let entity = VoiceRecordEntity(context: context)
        entity.id = record.id
        entity.title = record.title
        entity.memo = record.memo
        entity.desc = record.desc
        entity.speakersJSON = try? encoder.encodeString(record.speakers)
        entity.startTime = record.startTime
        entity.transcriptStatus = record.transcriptStatus.rawValue
        entity.summaryStatus = record.summaryStatus.rawValue

        try context.save()
        return record.id
    }

    func updateAudioFilePath(_ recordId: UUID, path: String, endTime: Date) async throws {
        guard let entity = try fetchEntity(id: recordId) else { return }
        entity.audioFilePath = path
        entity.endTime = endTime
        try context.save()
    }

    func updateTranscript(_ recordId: UUID, text: String, filePath: String) async throws {
        guard let entity = try fetchEntity(id: recordId) else { return }
        entity.transcriptText = text
        entity.transcriptFilePath = filePath
        try context.save()
    }

    func updateTranscriptStatus(_ recordId: UUID, status: ProcessingStatus) async throws {
        guard let entity = try fetchEntity(id: recordId) else { return }
        entity.transcriptStatus = status.rawValue
        try context.save()
    }

    func updateSummary(_ recordId: UUID, summary: RecordSummary) async throws {
        guard let entity = try fetchEntity(id: recordId) else { return }
        entity.summaryJSON = try? encoder.encodeString(summary)
        entity.summaryStatus = ProcessingStatus.completed.rawValue
        try context.save()
    }

    func updateSummaryStatus(_ recordId: UUID, status: ProcessingStatus) async throws {
        guard let entity = try fetchEntity(id: recordId) else { return }
        entity.summaryStatus = status.rawValue
        try context.save()
    }

    func getRecord(id: UUID) async throws -> VoiceRecord? {
        guard let entity = try fetchEntity(id: id) else { return nil }
        return mapEntity(entity)
    }

    func getAllRecords() async throws -> [VoiceRecord] {
        let request = VoiceRecordEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \VoiceRecordEntity.startTime, ascending: false)]
        let entities = try context.fetch(request) as! [VoiceRecordEntity]
        return entities.map(mapEntity)
    }

    func searchRecords(query: String) async throws -> [VoiceRecord] {
        let request = VoiceRecordEntity.fetchRequest()
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "title CONTAINS[cd] %@", query),
            NSPredicate(format: "memo CONTAINS[cd] %@", query)
        ])
        request.sortDescriptors = [NSSortDescriptor(keyPath: \VoiceRecordEntity.startTime, ascending: false)]
        let entities = try context.fetch(request) as! [VoiceRecordEntity]
        return entities.map(mapEntity)
    }

    func deleteRecord(id: UUID) async throws {
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

    private func fetchEntity(id: UUID) throws -> VoiceRecordEntity? {
        let request = VoiceRecordEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first as? VoiceRecordEntity
    }

    private func mapEntity(_ e: VoiceRecordEntity) -> VoiceRecord {
        VoiceRecord(
            id: e.id,
            title: e.title,
            memo: e.memo ?? "",
            desc: e.desc ?? "",
            speakers: (try? decoder.decode([String].self, from: e.speakersJSON)) ?? [],
            startTime: e.startTime,
            endTime: e.endTime,
            transcriptText: e.transcriptText,
            transcriptFilePath: e.transcriptFilePath,
            transcriptStatus: ProcessingStatus(rawValue: e.transcriptStatus) ?? .pending,
            summaryStatus: ProcessingStatus(rawValue: e.summaryStatus) ?? .pending,
            audioFilePath: e.audioFilePath,
            summary: (try? decoder.decode(RecordSummary.self, from: e.summaryJSON))
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
