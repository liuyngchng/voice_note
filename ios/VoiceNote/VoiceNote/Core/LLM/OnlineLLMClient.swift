import Foundation

/// 在线 LLM 客户端 — OpenAI 兼容 API
/// 将转写文本发送给在线大模型（默认 DeepSeek），返回结构化的会议总结。
/// 长文本自动分段：分块摘要 → 汇总合并。
/// 对齐 Android: OnlineLLMClient.kt
final class OnlineLLMClient {
    private let session: URLSession

    /// 单块最大字符数（约 2000-3000 中文 token），超过则启用分段
    private static let maxChunkChars = 8000

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    // MARK: - 默认配置（DeepSeek）

    /// API 地址（base URL，自动追加 /v1/chat/completions）
    static var apiBaseURL: String {
        UserDefaults.standard.string(forKey: "llm_online_api_url") ?? "https://api.deepseek.com"
    }

    /// API Key
    static var apiKey: String {
        UserDefaults.standard.string(forKey: "llm_online_api_key") ?? ""
    }

    /// 模型名称
    static var modelName: String {
        UserDefaults.standard.string(forKey: "llm_online_model_name") ?? "deepseek-v4-flash"
    }

    // MARK: - URL 构建

    /// 构建完整的 API URL：如果 endpoint 不以 /chat/completions 结尾，自动追加 /v1/chat/completions
    /// 对齐 Android: buildUrl()
    private static func buildURL(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/chat/completions") {
            return trimmed
        }
        return "\(trimmed)/v1/chat/completions"
    }

    // MARK: - 公开接口

    /// 生成会议总结（自动判断是否需要分段）
    /// - Parameters:
    ///   - transcript: 转写全文
    ///   - customPrompt: 自定义 prompt（可选）
    ///   - onProgress: 进度回调（主线程），参数为中文进度描述
    /// - Returns: Result<RecordSummary>
    func generateSummary(
        transcript: String,
        customPrompt: String?,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> Result<RecordSummary, Error> {
        let apiBase = Self.apiBaseURL
        let apiKey = Self.apiKey
        let model = Self.modelName

        guard !apiKey.isEmpty else {
            return .failure(OnlineLLMError.noAPIKey)
        }

        let urlString = Self.buildURL(apiBase)
        guard let url = URL(string: urlString) else {
            return .failure(OnlineLLMError.invalidURL)
        }

        if transcript.count <= Self.maxChunkChars {
            // 短文本：单次推理
            await MainActor.run { onProgress?("正在请求 AI 总结...") }
            return await singlePassSummary(transcript: transcript, customPrompt: customPrompt, url: url, apiKey: apiKey, model: model)
        } else {
            // 长文本：分段 → 逐块摘要 → 汇总
            return await multiPassSummary(transcript: transcript, customPrompt: customPrompt, url: url, apiKey: apiKey, model: model, onProgress: onProgress)
        }
    }

    // MARK: - 单次推理

    private func singlePassSummary(
        transcript: String,
        customPrompt: String?,
        url: URL,
        apiKey: String,
        model: String
    ) async -> Result<RecordSummary, Error> {
        let systemPrompt = buildSummarySystemPrompt()
        let instruction = (customPrompt?.isEmpty == false) ? customPrompt! : "以下是会议转写内容，请总结："
        let userPrompt = "\(instruction)\n\n\(transcript)"

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3,
            "max_tokens": 2048
        ]

        Log.llm("[在线] 单次推理: transcript=\(transcript.count) chars")

        do {
            let data = try await callAPI(url: url, apiKey: apiKey, body: requestBody)
            let content = try extractTextContent(from: data)
            let summary = try parseJsonContent(content)
            return .success(summary)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 多轮分段

    private func multiPassSummary(
        transcript: String,
        customPrompt: String?,
        url: URL,
        apiKey: String,
        model: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async -> Result<RecordSummary, Error> {
        // 1. 分块
        let chunks = splitText(transcript, maxChars: Self.maxChunkChars)
        let total = chunks.count
        Log.llm("[在线] 长文本分段: \(transcript.count) chars → \(total) 块 (max=\(Self.maxChunkChars))")

        // 2. 逐块摘要
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let current = i + 1
            await MainActor.run { onProgress?("正在分析片段 (\(current)/\(total))...") }

            let chunkPrompt = "用一两句话提取以下文本的关键信息，不要遗漏重要事项和决定：\n\n\(chunk)"

            let requestBody: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "user", "content": chunkPrompt]
                ],
                "temperature": 0.3,
                "max_tokens": 256
            ]

            do {
                let data = try await callAPI(url: url, apiKey: apiKey, body: requestBody)
                let text = try extractTextContent(from: data)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunkSummaries.append(trimmed)
                    Log.llm("[在线] 块 \(current)/\(total) 摘要: \(trimmed.count) chars")
                }
            } catch {
                Log.llm("[在线] 块 \(current)/\(total) 摘要失败，跳过: \(error.localizedDescription)")
                // 跳过失败的块，继续处理其他块
            }
        }

        guard !chunkSummaries.isEmpty else {
            return .failure(OnlineLLMError.allChunksFailed)
        }

        Log.llm("[在线] 块摘要收集完成: \(chunkSummaries.count)/\(total)")

        // 3. 合并摘要
        await MainActor.run { onProgress?("正在整合摘要...") }

        let mergedText: String
        if chunkSummaries.count == 1 {
            mergedText = chunkSummaries[0]
        } else {
            let summariesText = chunkSummaries.enumerated()
                .map { "【片段 \($0 + 1)】\($1)" }
                .joined(separator: "\n\n")

            let systemPrompt = buildSummarySystemPrompt()
            let mergePrompt = "以下是从长文本中提取的分段摘要，请整合为一个连贯的总结：\n\n\(summariesText)"

            let requestBody: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": mergePrompt]
                ],
                "temperature": 0.3,
                "max_tokens": 2048
            ]

            do {
                let data = try await callAPI(url: url, apiKey: apiKey, body: requestBody)
                mergedText = try extractTextContent(from: data)
            } catch {
                return .failure(error)
            }
        }

        // 4. 解析合并后的 JSON
        do {
            return .success(try parseJsonContent(mergedText))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - API 调用

    private func callAPI(url: URL, apiKey: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OnlineLLMError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw OnlineLLMError.authFailed
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            // 尝试解析错误 JSON
            let errorMsg: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                errorMsg = message
            } else {
                errorMsg = "HTTP \(httpResponse.statusCode): \(bodyStr.prefix(200))"
            }
            Log.llm("[在线] API 错误: \(errorMsg)")
            throw OnlineLLMError.httpError(httpResponse.statusCode, errorMsg)
        }

        return data
    }

    /// 从 API 响应中提取文本内容
    /// 对齐 Android: extractTextContent()
    private func extractTextContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw OnlineLLMError.invalidResponseFormat
        }
        return content
    }

    // MARK: - JSON 提取 + 解析

    /// 解析 JSON 内容为 RecordSummary
    /// 对齐 Android: parseJsonContent()
    private func parseJsonContent(_ content: String) throws -> RecordSummary {
        Log.llm("[在线] parseJsonContent: content=\(content.count) chars")
        let jsonStr = extractJSON(from: content)

        if let summary = try? parseRecordSummary(from: jsonStr) {
            Log.llm("[在线] 解析完成: topics=\(summary.topics.count), conclusions=\(summary.conclusions.count), todos=\(summary.todos.count), nextSteps=\(summary.nextSteps.count)")
            return summary
        }

        // JSON 解析失败，将纯文本作为结论
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnlineLLMError.emptyResponse }
        return RecordSummary(
            topics: [],
            conclusions: [trimmed],
            todos: [],
            nextSteps: []
        )
    }

    /// 从 LLM 返回内容中提取 JSON 字符串
    /// 处理可能被包裹在 ```json ... ``` 中的情况
    /// 对齐 Android: extractJson()
    private func extractJSON(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // 尝试匹配 ```json ... ``` 或 ``` ... ``` 代码块
        if let codeBlockRange = findCodeBlock(in: trimmed) {
            return String(trimmed[codeBlockRange])
        }

        // 尝试匹配 { ... } 直接 JSON
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           lastBrace > firstBrace {
            return String(trimmed[firstBrace...lastBrace])
        }

        return trimmed
    }

    private func findCodeBlock(in text: String) -> Range<String.Index>? {
        // 匹配 ```json\n...\n``` 或 ```\n...\n```
        let patterns = [
            "```json\n",
            "```json",
            "```\n",
            "```"
        ]
        for startPattern in patterns {
            if let startRange = text.range(of: startPattern) {
                let afterStart = startRange.upperBound
                let remaining = text[afterStart...]
                if let endRange = remaining.range(of: "\n```") ?? remaining.range(of: "```") {
                    return afterStart..<endRange.lowerBound
                }
            }
        }
        return nil
    }

    /// 解析 RecordSummary JSON
    private func parseRecordSummary(from jsonStr: String) throws -> RecordSummary {
        guard let data = jsonStr.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw OnlineLLMError.invalidResponseFormat
        }

        let topics = (json["topics"] as? [String]) ?? []
        let conclusions = (json["conclusions"] as? [String]) ?? []
        let nextSteps = (json["nextSteps"] as? [String]) ?? []

        var todos: [TodoItem] = []
        if let todoList = json["todos"] as? [[String: Any]] {
            todos = todoList.map { item in
                TodoItem(
                    task: item["task"] as? String ?? "",
                    owner: item["owner"] as? String ?? "",
                    deadline: item["deadline"] as? String ?? ""
                )
            }
        }

        guard !topics.isEmpty || !conclusions.isEmpty || !todos.isEmpty || !nextSteps.isEmpty else {
            throw OnlineLLMError.emptyResponse
        }

        return RecordSummary(topics: topics, conclusions: conclusions, todos: todos, nextSteps: nextSteps)
    }

    // MARK: - 文本分块

    /// 将文本按句子边界分块，每块不超过 maxChars
    /// 对齐 Android: splitText()
    private func splitText(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }

        var chunks: [String] = []
        let sentences = splitBySentences(text)
        var currentChunk = ""

        for sentence in sentences {
            // 单个句子超过上限，硬截断
            if sentence.count > maxChars {
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                    currentChunk = ""
                }
                var remaining = sentence
                while remaining.count > maxChars {
                    let splitIdx = remaining.index(remaining.startIndex, offsetBy: maxChars)
                    chunks.append(String(remaining[..<splitIdx]).trimmingCharacters(in: .whitespacesAndNewlines))
                    remaining = String(remaining[splitIdx...])
                }
                if !remaining.isEmpty {
                    currentChunk = remaining
                }
                continue
            }

            // 加入当前句后会超出上限，先保存当前块
            if currentChunk.count + sentence.count > maxChars {
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                currentChunk = sentence
            } else {
                currentChunk += sentence
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks.filter { !$0.isEmpty }
    }

    /// 按句子边界分割文本
    /// 对齐 Android: splitBySentences()
    private func splitBySentences(_ text: String) -> [String] {
        // 在常见标点后分割，保留标点附在前一句末尾
        let separators = try! NSRegularExpression(pattern: "[。！？!?\n]+", options: [])
        let nsText = text as NSString
        let matches = separators.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var sentences: [String] = []
        var lastEnd = 0

        for match in matches {
            let range = match.range
            if range.location > lastEnd {
                let part = nsText.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty {
                    sentences.append(part)
                }
            }
            // 分隔符附加到前一句
            let delimiter = nsText.substring(with: range)
            if !sentences.isEmpty {
                sentences[sentences.count - 1] += delimiter
            } else {
                sentences.append(delimiter)
            }
            lastEnd = range.location + range.length
        }

        // 剩余部分
        if lastEnd < nsText.length {
            let remaining = nsText.substring(from: lastEnd)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                sentences.append(remaining)
            }
        }

        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - Prompt

    private func buildSummarySystemPrompt() -> String {
        """
        你是一个专业的会议记录总结助手。请从以下会议转写文本中提取关键信息，以 JSON 格式返回。
        JSON 格式要求：
        {
          "topics": ["议题1", "议题2"],
          "conclusions": ["结论1", "结论2"],
          "todos": [{"task": "待办事项", "owner": "负责人", "deadline": "截止时间"}],
          "nextSteps": ["后续步骤1", "后续步骤2"]
        }
        注意：
        1. 只返回 JSON，不要包含任何其他文字
        2. 如果某个字段没有相关内容，返回空数组 []
        3. todos 中的 owner 和 deadline 如果未提及则为空字符串
        4. 请确保 JSON 格式正确，可以被直接解析
        """
    }
}

// MARK: - 错误

enum OnlineLLMError: LocalizedError {
    case noAPIKey
    case invalidURL
    case invalidResponse
    case invalidResponseFormat
    case authFailed
    case httpError(Int, String)
    case networkError(Error)
    case emptyResponse
    case allChunksFailed

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "请在设置中配置在线大语言模型的 API Key"
        case .invalidURL:
            return "API 地址无效"
        case .invalidResponse:
            return "服务器响应异常"
        case .invalidResponseFormat:
            return "响应格式异常"
        case .authFailed:
            return "API Key 验证失败，请检查设置"
        case .httpError(let code, let msg):
            return "API 请求失败 (\(code)): \(msg)"
        case .networkError(let error):
            return "网络请求失败: \(error.localizedDescription)"
        case .emptyResponse:
            return "LLM 返回空结果"
        case .allChunksFailed:
            return "所有分段摘要均失败"
        }
    }
}
