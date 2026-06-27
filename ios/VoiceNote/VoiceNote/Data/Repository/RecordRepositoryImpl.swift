import CoreData
import Foundation

/// 数据仓库实现
final class RecordRepositoryImpl: RecordRepository {
    private let container: AppContainer
    private let context: NSManagedObjectContext

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(container: AppContainer) {
        self.container = container
        self.context = container.persistence.container.viewContext
    }

    // MARK: - Core Data (context.perform 兼容 iOS 14)

    func createRecord(_ record: VoiceRecord) async throws -> UUID {
        try await withCheckedThrowingContinuation { c in
            context.perform {
                let entity = VoiceRecordEntity(context: self.context)
                entity.id = record.id
                entity.title = record.title
                entity.memo = record.memo
                entity.desc = record.desc
                entity.speakersJSON = try? self.encoder.encodeString(record.speakers)
                entity.startTime = record.startTime
                entity.transcriptStatus = record.transcriptStatus.rawValue
                do {
                    try self.context.save()
                    c.resume(returning: record.id)
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    func updateAudioFilePath(_ recordId: UUID, path: String, endTime: Date) async throws {
        await withCheckedContinuation { c in
            context.perform {
                guard let entity = try? self.fetchEntity(id: recordId) else { c.resume(); return }
                entity.audioFilePath = path
                entity.endTime = endTime
                try? self.context.save()
                c.resume()
            }
        }
    }

    func updateTranscriptFilePath(_ recordId: UUID, filePath: String) async throws {
        await withCheckedContinuation { c in
            context.perform {
                guard let entity = try? self.fetchEntity(id: recordId) else { c.resume(); return }
                entity.transcriptFilePath = filePath
                try? self.context.save()
                c.resume()
            }
        }
    }

    func updateTranscriptStatus(_ recordId: UUID, status: ProcessingStatus) async throws {
        await withCheckedContinuation { c in
            context.perform {
                guard let entity = try? self.fetchEntity(id: recordId) else { c.resume(); return }
                entity.transcriptStatus = status.rawValue
                try? self.context.save()
                c.resume()
            }
        }
    }

    /// 5 分钟 checkpoint：更新已转录时长（用于崩溃恢复定位进度）
    func checkpointTranscriptProgress(_ recordId: UUID, durationSeconds: TimeInterval) async {
        await withCheckedContinuation { c in
            context.perform {
                guard let entity = try? self.fetchEntity(id: recordId) else { c.resume(); return }
                entity.transcribedDurationSeconds = durationSeconds
                try? self.context.save()
                c.resume()
            }
        }
    }

    /// 查找所有未完成的录音记录（崩溃恢复用）
    func getUnfinishedRecords() async -> [VoiceRecord] {
        await withCheckedContinuation { c in
            context.perform {
                let request = VoiceRecordEntity.fetchRequest()
                request.predicate = NSPredicate(format: "transcriptStatus IN %@",
                    [ProcessingStatus.pending.rawValue, ProcessingStatus.processing.rawValue])
                request.sortDescriptors = [NSSortDescriptor(keyPath: \VoiceRecordEntity.startTime, ascending: false)]
                let entities = (try? self.context.fetch(request)) as? [VoiceRecordEntity] ?? []
                c.resume(returning: entities.map(self.mapEntity))
            }
        }
    }

    func getRecord(id: UUID) async throws -> VoiceRecord? {
        await withCheckedContinuation { c in
            context.perform {
                guard let entity = try? self.fetchEntity(id: id) else {
                    c.resume(returning: nil)
                    return
                }
                c.resume(returning: self.mapEntity(entity))
            }
        }
    }

    func getAllRecords() async throws -> [VoiceRecord] {
        await withCheckedContinuation { c in
            context.perform {
                let request = VoiceRecordEntity.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(keyPath: \VoiceRecordEntity.startTime, ascending: false)]
                let entities = (try? self.context.fetch(request)) as? [VoiceRecordEntity] ?? []
                c.resume(returning: entities.map(self.mapEntity))
            }
        }
    }

    func searchRecords(query: String) async throws -> [VoiceRecord] {
        await withCheckedContinuation { c in
            context.perform {
                let request = VoiceRecordEntity.fetchRequest()
                request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "title CONTAINS[cd] %@", query),
                    NSPredicate(format: "memo CONTAINS[cd] %@", query)
                ])
                request.sortDescriptors = [NSSortDescriptor(keyPath: \VoiceRecordEntity.startTime, ascending: false)]
                let entities = (try? self.context.fetch(request)) as? [VoiceRecordEntity] ?? []
                c.resume(returning: entities.map(self.mapEntity))
            }
        }
    }

    func deleteRecord(id: UUID) async throws {
        await withCheckedContinuation { c in
            context.perform {
                guard let entity = try? self.fetchEntity(id: id) else { c.resume(); return }
                if let audioPath = entity.audioFilePath, !audioPath.isEmpty {
                    let dir = URL(fileURLWithPath: audioPath).deletingLastPathComponent()
                    try? FileManager.default.removeItem(at: dir)
                }
                self.context.delete(entity)
                try? self.context.save()
                c.resume()
            }
        }
    }

    func deleteAllRecords() async throws {
        await withCheckedContinuation { c in
            context.perform {
                let request = VoiceRecordEntity.fetchRequest()
                let entities = (try? self.context.fetch(request)) as? [VoiceRecordEntity] ?? []
                let audioDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("audio", isDirectory: true)
                try? FileManager.default.removeItem(at: audioDir)
                for entity in entities {
                    self.context.delete(entity)
                }
                try? self.context.save()
                c.resume()
            }
        }
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
            transcriptText: e.transcriptText,  // 仅用于兼容旧数据，新记录为 nil
            transcriptFilePath: e.transcriptFilePath,
            transcriptStatus: ProcessingStatus(rawValue: e.transcriptStatus) ?? .pending,
            audioFilePath: e.audioFilePath,
            transcribedDurationSeconds: e.transcribedDurationSeconds
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
