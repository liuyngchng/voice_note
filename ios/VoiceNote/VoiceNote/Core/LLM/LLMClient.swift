import Foundation

/// OpenAI 兼容的 LLM 客户端
/// 对齐 Android: LLMClient.kt
final class LLMClient {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    // MARK: - 连接测试（供设置页使用，与真实调用共用 encoder/decoder）

    /// 测试 LLM API 连接可达性 — 使用与 generateSummary 相同的编码器和请求格式
    static func testConnection(
        baseURL: String,
        apiKey: String,
        model: String
    ) async -> ConnectionTestResult {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("API 地址为空")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("API Key 为空")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("模型名称为空")
        }

        guard let url = buildChatURL(from: baseURL) else {
            return .failure("无效的 URL 格式")
        }

        // 使用与 generateSummary 相同的 encoder（snakeCase）
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let requestBody = ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            request.httpBody = try encoder.encode(requestBody)
        } catch {
            return .failure("无法编码请求体")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("无效的服务器响应")
            }

            switch httpResponse.statusCode {
            case 200...299:
                // 使用与 generateSummary 相同的 decoder 验证响应格式
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                if (try? decoder.decode(ChatCompletionResponse.self, from: data)) != nil {
                    return .success
                }
                return .success  // 2xx 就算成功

            case 401:
                return .failure("API Key 无效 (401 Unauthorized)")
            case 403:
                return .failure("访问被拒绝 (403 Forbidden)，请检查 API Key 权限")
            case 404:
                return .failure("接口未找到 (404)，请检查 API 地址是否正确")
            case 429:
                return .failure("请求过于频繁 (429)，请稍后重试")
            case 500...599:
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure("服务器错误 (\(httpResponse.statusCode)): \(body.prefix(200))")
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure("HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            }

        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost:
                return .failure("无法连接到服务器: \(error.localizedDescription)")
            case .timedOut:
                return .failure("请求超时（15秒）")
            case .notConnectedToInternet:
                return .failure("未连接到互联网")
            case .secureConnectionFailed:
                return .failure("SSL/TLS 连接失败: \(error.localizedDescription)")
            default:
                return .failure("网络错误: \(error.localizedDescription)")
            }
        } catch {
            return .failure("请求失败: \(error.localizedDescription)")
        }
    }

    // MARK: - URL 构建（对齐 Android: 自动拼接 chat/completions 路径）

    private static func buildChatURL(from baseURL: String) -> URL? {
        if baseURL.contains("/chat/completions") {
            return URL(string: baseURL)
        }
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmed)/v1/chat/completions")
    }

    // MARK: - 生成拜访总结

    func generateSummary(
        transcript: String,
        apiUrl: String,
        apiKey: String,
        model: String,
        customPrompt: String?
    ) async -> Result<VisitSummary, Error> {
        guard let url = Self.buildChatURL(from: apiUrl) else {
            return .failure(LLMError.invalidURL)
        }

        let prompt = customPrompt?.isBlank == false ? customPrompt! : defaultPrompt
        let systemMessage = ChatMessage(role: "system", content: prompt)
        let userMessage = ChatMessage(role: "user", content: transcript)

        let requestBody = ChatCompletionRequest(
            model: model,
            messages: [systemMessage, userMessage],
            temperature: 0.3
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        do {
            request.httpBody = try encoder.encode(requestBody)
        } catch {
            return .failure(error)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(LLMError.invalidResponse)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(LLMError.httpError(httpResponse.statusCode, body))
            }

            let completion = try decoder.decode(ChatCompletionResponse.self, from: data)
            guard let content = completion.choices.first?.message.content else {
                return .failure(LLMError.emptyResponse)
            }

            let summary = try parseSummary(from: content)
            return .success(summary)

        } catch let error as LLMError {
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 解析

    /// iOS 14 兼容: 用 NSRegularExpression 提取第一个 JSON 对象
    private func firstJSONObject(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\{[^}]*\\}") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return String(text[Range(match.range, in: text)!])
    }

    private func parseSummary(from text: String) throws -> VisitSummary {
        // 尝试提取 JSON 块 (iOS 14 兼容: 使用 NSRegularExpression 替代 Swift Regex)
        let jsonText: String
        if let jsonMatch = firstJSONObject(in: text) {
            jsonText = jsonMatch
        } else if text.contains("{") {
            jsonText = text
        } else {
            // 没有 JSON，作为纯文本返回
            return VisitSummary(
                topics: [],
                conclusions: [text],
                todos: [],
                nextSteps: []
            )
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw LLMError.parseFailed("无法编码响应文本")
        }

        do {
            let decoded = try decoder.decode(LLMSummaryResponse.self, from: data)
            return VisitSummary(
                topics: decoded.topics ?? [],
                conclusions: decoded.conclusions ?? [],
                todos: (decoded.todos ?? []).map {
                    TodoItem(task: $0.task ?? "", owner: $0.owner ?? "", deadline: $0.deadline ?? "")
                },
                nextSteps: decoded.nextSteps ?? []
            )
        } catch {
            throw LLMError.parseFailed(error.localizedDescription)
        }
    }

    // MARK: - 默认 Prompt

    private let defaultPrompt = """
    你是一个专业的商务助理，负责总结客户拜访记录。
    请根据转写文本，提取以下信息，并以 JSON 格式返回：

    {
      "topics": ["讨论议题1", "讨论议题2"],
      "conclusions": ["结论1", "结论2"],
      "todos": [{"task": "待办事项", "owner": "负责人", "deadline": "截止时间"}],
      "nextSteps": ["后续步骤1", "后续步骤2"]
    }

    确保 JSON 完整且可解析。只输出 JSON，不要额外解释。
    """
}

// MARK: - 内部类型

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatCompletionResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String
    }
}

private struct LLMSummaryResponse: Codable {
    let topics: [String]?
    let conclusions: [String]?
    let todos: [LLMTodoItem]?
    let nextSteps: [String]?
}

private struct LLMTodoItem: Codable {
    let task: String?
    let owner: String?
    let deadline: String?
}

enum LLMError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case emptyResponse
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:          return "无效的 LLM API 地址"
        case .invalidResponse:     return "无效的服务器响应"
        case .httpError(let c, _): return "HTTP 错误: \(c)"
        case .emptyResponse:       return "LLM 返回空结果"
        case .parseFailed(let m):  return "JSON 解析失败: \(m)"
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
