import Foundation

/// 拜访记录（领域模型）
/// 对齐 Android: app/src/.../domain/model/Visit.kt
struct Visit: Identifiable, Codable {
    let id: UUID
    var clientName: String
    var clientCompany: String
    var purpose: String
    var participants: [String]
    var startTime: Date
    var endTime: Date?
    var locationPoints: [LocationPoint]
    var transcriptText: String?
    var transcriptFilePath: String?
    var transcriptStatus: ProcessingStatus
    var summaryStatus: ProcessingStatus
    var audioFilePath: String?
    var summary: VisitSummary?

    init(
        id: UUID = UUID(),
        clientName: String = "",
        clientCompany: String = "",
        purpose: String = "",
        participants: [String] = [],
        startTime: Date = Date(),
        endTime: Date? = nil,
        locationPoints: [LocationPoint] = [],
        transcriptText: String? = nil,
        transcriptFilePath: String? = nil,
        transcriptStatus: ProcessingStatus = .pending,
        summaryStatus: ProcessingStatus = .pending,
        audioFilePath: String? = nil,
        summary: VisitSummary? = nil
    ) {
        self.id = id
        self.clientName = clientName
        self.clientCompany = clientCompany
        self.purpose = purpose
        self.participants = participants
        self.startTime = startTime
        self.endTime = endTime
        self.locationPoints = locationPoints
        self.transcriptText = transcriptText
        self.transcriptFilePath = transcriptFilePath
        self.transcriptStatus = transcriptStatus
        self.summaryStatus = summaryStatus
        self.audioFilePath = audioFilePath
        self.summary = summary
    }
}

/// 处理状态
/// 对齐 Android: ProcessingStatus
enum ProcessingStatus: String, Codable {
    case pending
    case processing
    case completed
    case unavailable
}
