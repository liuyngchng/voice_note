import Foundation

/// 语音笔记（领域模型）
struct VoiceRecord: Identifiable, Codable {
    let id: UUID
    var title: String
    var memo: String
    var desc: String
    var speakers: [String]
    var startTime: Date
    var endTime: Date?
    var transcriptText: String?
    var transcriptFilePath: String?
    var transcriptStatus: ProcessingStatus
    var summaryStatus: ProcessingStatus
    var audioFilePath: String?
    var summary: RecordSummary?
    var summaryGeneratedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        memo: String = "",
        desc: String = "",
        speakers: [String] = [],
        startTime: Date = Date(),
        endTime: Date? = nil,
        transcriptText: String? = nil,
        transcriptFilePath: String? = nil,
        transcriptStatus: ProcessingStatus = .pending,
        summaryStatus: ProcessingStatus = .pending,
        audioFilePath: String? = nil,
        summary: RecordSummary? = nil,
        summaryGeneratedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.memo = memo
        self.desc = desc
        self.speakers = speakers
        self.startTime = startTime
        self.endTime = endTime
        self.transcriptText = transcriptText
        self.transcriptFilePath = transcriptFilePath
        self.transcriptStatus = transcriptStatus
        self.summaryStatus = summaryStatus
        self.audioFilePath = audioFilePath
        self.summary = summary
        self.summaryGeneratedAt = summaryGeneratedAt
    }
}

/// 处理状态
enum ProcessingStatus: String, Codable {
    case pending
    case processing
    case completed
    case unavailable
}
