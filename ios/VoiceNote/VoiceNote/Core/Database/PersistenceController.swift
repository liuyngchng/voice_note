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

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Core Data 加载失败: \(error)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - 程序化数据模型

    private static let model: NSManagedObjectModel = {
        let model = NSManagedObjectModel()

        let visitEntity = NSEntityDescription()
        visitEntity.name = "VisitEntity"
        visitEntity.managedObjectClassName = NSStringFromClass(VisitEntity.self)

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

        let boolAttr: (String, Bool, Any?) -> NSAttributeDescription = { name, opt, defaultVal in
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = .booleanAttributeType
            attr.isOptional = opt
            attr.defaultValue = defaultVal
            return attr
        }

        visitEntity.properties = [
            uuidAttr("id", false),
            makeAttr("clientName", .stringAttributeType, false),
            makeAttr("clientCompany", .stringAttributeType),
            makeAttr("purpose", .stringAttributeType),
            makeAttr("participantsJSON", .stringAttributeType),
            dateAttr("startTime", false),
            dateAttr("endTime", true),
            makeAttr("locationPointsJSON", .stringAttributeType),
            makeAttr("transcriptText", .stringAttributeType),
            makeAttr("transcriptFilePath", .stringAttributeType),
            makeAttr("transcriptStatus", .stringAttributeType, false),
            makeAttr("summaryStatus", .stringAttributeType, false),
            makeAttr("audioFilePath", .stringAttributeType),
            makeAttr("summaryJSON", .stringAttributeType),
        ]

        model.entities = [visitEntity]
        return model
    }()
}

// MARK: - NSManagedObject 子类

@objc(VisitEntity)
final class VisitEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var clientName: String
    @NSManaged var clientCompany: String?
    @NSManaged var purpose: String?
    @NSManaged var participantsJSON: String?
    @NSManaged var startTime: Date
    @NSManaged var endTime: Date?
    @NSManaged var locationPointsJSON: String?
    @NSManaged var transcriptText: String?
    @NSManaged var transcriptFilePath: String?
    @NSManaged var transcriptStatus: String
    @NSManaged var summaryStatus: String
    @NSManaged var audioFilePath: String?
    @NSManaged var summaryJSON: String?
}
