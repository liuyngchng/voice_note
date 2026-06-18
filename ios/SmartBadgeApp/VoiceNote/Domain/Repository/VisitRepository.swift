import Foundation

/// 拜访数据仓库接口
/// 对齐 Android: VisitRepository.kt
protocol VisitRepository {
    /// 创建新拜访，返回生成的 ID
    func createVisit(_ visit: Visit) async throws -> UUID

    /// 更新音频文件路径
    func updateAudioFilePath(_ visitId: UUID, path: String, endTime: Date, locationPoints: [LocationPoint]) async throws

    /// 更新转写文本
    func updateTranscript(_ visitId: UUID, text: String, filePath: String) async throws

    /// 更新转写状态
    func updateTranscriptStatus(_ visitId: UUID, status: ProcessingStatus) async throws

    /// 更新总结
    func updateSummary(_ visitId: UUID, summary: VisitSummary) async throws

    /// 更新总结状态
    func updateSummaryStatus(_ visitId: UUID, status: ProcessingStatus) async throws

    /// 按 ID 查询
    func getVisit(id: UUID) async throws -> Visit?

    /// 查询所有拜访（按时间倒序）
    func getAllVisits() async throws -> [Visit]

    /// 按客户名/公司搜索
    func searchVisits(query: String) async throws -> [Visit]

    /// 删除拜访
    func deleteVisit(id: UUID) async throws
}
