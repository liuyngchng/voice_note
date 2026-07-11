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
    /// [已废弃] 仅用于兼容旧版本 DB 数据，新记录不再写入此字段
    var transcriptText: String?
    /// 转写 .txt 文件路径（文本全文存于磁盘文件）
    var transcriptFilePath: String?
    var transcriptStatus: ProcessingStatus
    var audioFilePath: String?
    /// 已转录时长（秒），5 分钟 checkpoint，用于崩溃恢复
    var transcribedDurationSeconds: TimeInterval

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
        audioFilePath: String? = nil,
        transcribedDurationSeconds: TimeInterval = 0
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
        self.audioFilePath = audioFilePath
        self.transcribedDurationSeconds = transcribedDurationSeconds
    }
}

/// 处理状态
enum ProcessingStatus: String, Codable {
    case pending
    case processing
    case completed
    case unavailable
}
