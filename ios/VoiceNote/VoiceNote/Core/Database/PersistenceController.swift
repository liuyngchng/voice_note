import CoreData
import Foundation

/// 本地数据库管理（Core Data 实现）
/// 对齐 Android: Room (AppDatabase.kt + VisitDao.kt)
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "SmartBadge", managedObjectModel: Self.model)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        // 遇到损坏的 store 自动删除重建
        container.loadPersistentStores { [weak self] desc, error in
            if let error {
                print("[CoreData] 加载失败: \(error.localizedDescription)，尝试重建...")
                if let url = desc.url {
                    try? FileManager.default.removeItem(at: url)
                    // 删除关联文件
                    let shm = url.appendingPathExtension("sqlite-shm")
                    let wal = url.appendingPathExtension("sqlite-wal")
                    try? FileManager.default.removeItem(at: shm)
                    try? FileManager.default.removeItem(at: wal)
                }
                // 重试
                self?.container.loadPersistentStores { _, error2 in
                    if let error2 {
                        print("[CoreData] 重建失败: \(error2.localizedDescription)")
                    } else {
                        print("[CoreData] 数据库已重建")
                    }
                }
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - 程序化数据模型

    private static let model: NSManagedObjectModel = {
        let model = NSManagedObjectModel()

        let recordEntity = NSEntityDescription()
        recordEntity.name = "VoiceRecordEntity"
        recordEntity.managedObjectClassName = NSStringFromClass(VoiceRecordEntity.self)

        func makeAttr(_ name: String, _ type: NSAttributeType, _ optional: Bool = true) -> NSAttributeDescription {
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.isOptional = optional
            return attr
        }

        let uuidAttr: (String, Bool) -> NSAttributeDescription = { name, opt in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = .UUIDAttributeType
            attr.isOptional = opt
            return attr
        }

        let dateAttr: (String, Bool) -> NSAttributeDescription = { name, opt in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = .dateAttributeType
            attr.isOptional = opt
            return attr
        }

        recordEntity.properties = [
            uuidAttr("id", false),
            makeAttr("title", .stringAttributeType, false),
            makeAttr("memo", .stringAttributeType),
            makeAttr("desc", .stringAttributeType),
            makeAttr("speakersJSON", .stringAttributeType),
            dateAttr("startTime", false),
            dateAttr("endTime", true),
            makeAttr("transcriptText", .stringAttributeType),
            makeAttr("transcriptFilePath", .stringAttributeType),
            makeAttr("transcriptStatus", .stringAttributeType, false),
            makeAttr("summaryStatus", .stringAttributeType, false),
            makeAttr("audioFilePath", .stringAttributeType),
            makeAttr("summaryJSON", .stringAttributeType),
            dateAttr("summaryGeneratedAt", true),
        ]

        model.entities = [recordEntity]
        return model
    }()
}

// MARK: - NSManagedObject 子类

@objc(VoiceRecordEntity)
final class VoiceRecordEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var memo: String?
    @NSManaged var desc: String?
    @NSManaged var speakersJSON: String?
    @NSManaged var startTime: Date
    @NSManaged var endTime: Date?
    @NSManaged var transcriptText: String?
    @NSManaged var transcriptFilePath: String?
    @NSManaged var transcriptStatus: String
    @NSManaged var summaryStatus: String
    @NSManaged var audioFilePath: String?
    @NSManaged var summaryJSON: String?
    @NSManaged var summaryGeneratedAt: Date?
}
