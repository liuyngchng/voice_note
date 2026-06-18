import Foundation

/// 连接测试结果
enum ConnectionTestResult: Equatable {
    case idle
    case testing
    case success
    case failure(String)  // 错误原因

    var message: String {
        switch self {
        case .idle:     return "未测试"
        case .testing:  return "测试中..."
        case .success:  return "连接成功"
        case .failure(let reason): return reason
        }
    }
}

/// 连接测试器 — 测试 WS 和 LLM API 的可用性
final class ConnectionTester {

    // MARK: - WebSocket 测试

    /// 测试 WebSocket 连接 — 委托给 FunASRClient，保证与真实录音使用同一套握手逻辑
    static func testWebSocket(urlString: String) async -> ConnectionTestResult {
        await FunASRClient.testConnection(urlString: urlString)
    }

    // MARK: - LLM API 测试

    /// 测试 LLM API — 委托给 LLMClient，保证与真实调用使用同一套 encoder/decoder
    static func testLLMAPI(baseURL: String, apiKey: String, model: String) async -> ConnectionTestResult {
        await LLMClient.testConnection(baseURL: baseURL, apiKey: apiKey, model: model)
    }
}
