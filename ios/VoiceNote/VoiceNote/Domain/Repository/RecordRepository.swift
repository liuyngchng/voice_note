import Foundation

/// 语音笔记数据仓库接口
protocol RecordRepository {
    /// 创建新记录，返回生成的 ID
    func createRecord(_ record: VoiceRecord) async throws -> UUID

    /// 更新音频文件路径
    func updateAudioFilePath(_ recordId: UUID, path: String, endTime: Date) async throws

    /// 更新转写文件路径（DB 只存元数据，文本全文在 .txt 文件中）
    func updateTranscriptFilePath(_ recordId: UUID, filePath: String) async throws

    /// 更新转写状态
    func updateTranscriptStatus(_ recordId: UUID, status: ProcessingStatus) async throws

    /// 5 分钟 checkpoint：更新已转录时长
    func checkpointTranscriptProgress(_ recordId: UUID, durationSeconds: TimeInterval) async

    /// 查找未完成的录音记录（崩溃恢复）
    func getUnfinishedRecords() async -> [VoiceRecord]

    /// 按 ID 查询
    func getRecord(id: UUID) async throws -> VoiceRecord?

    /// 查询所有记录（按时间倒序）
    func getAllRecords() async throws -> [VoiceRecord]

    /// 按标题搜索
    func searchRecords(query: String) async throws -> [VoiceRecord]

    /// 删除记录
    func deleteRecord(id: UUID) async throws

    /// 清空所有记录
    func deleteAllRecords() async throws
}
