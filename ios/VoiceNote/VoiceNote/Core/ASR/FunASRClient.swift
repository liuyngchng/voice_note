import Foundation

/// FunASR WebSocket 客户端
/// 对齐 Android: FunASRClient.kt
final class FunASRClient {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession!
    private var serverUrl: String?
    private var intentionalDisconnect = false
    private var reconnectAttempt = 0

    private let maxReconnectAttempts = 3
    private let reconnectDelays: [TimeInterval] = [2, 4, 8]

    // MARK: - 实时流式连接

    func connect(url: String) -> AsyncStream<ASREvent> {
        serverUrl = url
        intentionalDisconnect = false
        reconnectAttempt = 0
        session = URLSession(configuration: {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForResource = 0    // 无超时
            return c
        }())

        return AsyncStream { continuation in
            openWebSocket(url: url, continuation: continuation)
        }
    }

    private func openWebSocket(url: String, continuation: AsyncStream<ASREvent>.Continuation) {
        guard let wsUrl = URL(string: url) else {
            continuation.yield(.error("无效的 WebSocket URL"))
            continuation.finish()
            return
        }
        webSocket = session.webSocketTask(with: wsUrl)
        webSocket?.resume()

        // 短暂延迟后发送已连接事件
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            continuation.yield(.connected)
        }

        receiveLoop(continuation: continuation)
    }

    private func receiveLoop(continuation: AsyncStream<ASREvent>.Continuation) {
        webSocket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.parseMessage(text, continuation: continuation)
                case .data:
                    break // 忽略二进制消息
                @unknown default:
                    break
                }
                self.receiveLoop(continuation: continuation)

            case .failure(let error):
                continuation.yield(.error(error.localizedDescription))
                if !self.intentionalDisconnect {
                    self.scheduleReconnect(continuation: continuation)
                } else {
                    continuation.yield(.disconnected)
                    continuation.finish()
                }
            }
        }
    }

    private func parseMessage(_ text: String, continuation: AsyncStream<ASREvent>.Continuation) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let resultText = json["text"] as? String ?? ""
        let isFinal = json["is_final"] as? Bool ?? false

        guard !resultText.isEmpty else { return }

        if isFinal {
            continuation.yield(.final(resultText))
        } else {
            continuation.yield(.partial(resultText))
        }
    }

    // MARK: - 控制消息

    func sendHandshake(chunkSize: [Int] = [5, 10, 5]) {
        sendJSON([
            "mode": "2pass",
            "chunk_size": chunkSize,
            "wav_name": "streaming",
            "is_speaking": true
        ])
    }

    func sendAudio(_ data: Data) {
        webSocket?.send(.data(data)) { error in
            if let error { Log.asr("send audio error: \(error)") }
        }
    }

    func sendEnd() {
        sendJSON(["is_speaking": false])
    }

    func disconnect() {
        intentionalDisconnect = true
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }

    // MARK: - 私有方法

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else { return }
        webSocket?.send(.string(text)) { error in
            if let error { Log.asr("send json error: \(error)") }
        }
    }

    private func scheduleReconnect(continuation: AsyncStream<ASREvent>.Continuation) {
        guard reconnectAttempt < maxReconnectAttempts, let url = serverUrl else { return }
        let delay = reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.openWebSocket(url: url, continuation: continuation)
        }
    }

    // MARK: - 连接测试（供设置页使用，与真实录音共用握手逻辑）

    /// 测试 WebSocket 连接可达性 — 使用与真实录音相同的握手格式和连接流程
    static func testConnection(urlString: String) async -> ConnectionTestResult {
        guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("WebSocket 地址为空")
        }
        guard let url = URL(string: urlString) else {
            return .failure("无效的 URL 格式")
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            return .failure("URL 必须以 ws:// 或 wss:// 开头")
        }

        return await withCheckedContinuation { continuation in
            final class Gate { var fired = false }
            let gate = Gate()

            let finish: @Sendable (ConnectionTestResult) -> Void = { result in
                guard !gate.fired else { return }
                gate.fired = true
                continuation.resume(returning: result)
            }

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config)
            let task = session.webSocketTask(with: url)

            // 超时 8 秒
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                task.cancel()
                finish(.failure("连接超时（8秒）"))
            }

            task.resume()

            // 发送握手 — 与 sendHandshake() 完全一致的格式
            let handshake: [String: Any] = [
                "mode": "2pass",
                "chunk_size": [5, 10, 5],
                "wav_name": "streaming",
                "is_speaking": true
            ]
            if let data = try? JSONSerialization.data(withJSONObject: handshake),
               let text = String(data: data, encoding: .utf8) {
                task.send(.string(text)) { error in
                    if let error = error {
                        task.cancel()
                        finish(.failure("发送握手失败: \(error.localizedDescription)"))
                    }
                }
            } else {
                task.cancel()
                finish(.failure("无法构建握手消息"))
            }

            // 握手后发送结束信号，触发服务端离线 pass 返回结果
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                let endMsg: [String: Any] = ["is_speaking": false]
                if let data = try? JSONSerialization.data(withJSONObject: endMsg),
                   let text = String(data: data, encoding: .utf8) {
                    task.send(.string(text)) { _ in }
                }
            }

            // 等待服务端响应（成功则表明连接可用）
            task.receive { result in
                switch result {
                case .success:
                    task.cancel()
                    finish(.success)
                case .failure(let error):
                    task.cancel()
                    finish(.failure("连接失败: \(error.localizedDescription)"))
                }
            }
        }
    }

    // MARK: - 离线文件处理（带重试）

    func processFile(audioFilePath: String, serverUrl: String, maxRetries: Int = 5) async -> Result<String, Error> {
        let retryDelays: [TimeInterval] = [20, 40, 80, 160, 320]

        for attempt in 0..<maxRetries {
            if attempt > 0 {
                let delay = retryDelays[min(attempt - 1, retryDelays.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            let result = await doProcessFile(audioFilePath: audioFilePath, serverUrl: serverUrl)
            if case .success = result {
                return result
            }
        }

        return .failure(ASRError.allRetriesExhausted)
    }

    private func doProcessFile(audioFilePath: String, serverUrl: String) async -> Result<String, Error> {
        guard let fileHandle = FileHandle(forReadingAtPath: audioFilePath) else {
            return .failure(ASRError.fileNotFound)
        }
        defer { try? fileHandle.close() }

        // 跳过 WAV 头 44 字节
        let wavHeader = try? fileHandle.read(upToCount: 44)
        guard wavHeader?.count == 44 else {
            return .failure(ASRError.invalidWavFile)
        }

        guard let wsUrl = URL(string: serverUrl) else {
            return .failure(ASRError.invalidURL)
        }

        return await withCheckedContinuation { continuation in
            let wsSession = URLSession(configuration: .default)
            let task = wsSession.webSocketTask(with: wsUrl)
            var transcript = ""
            var hasResumed = false

            func finish(_ result: Result<String, Error>) {
                guard !hasResumed else { return }
                hasResumed = true
                task.cancel()
                continuation.resume(returning: result)
            }

            task.resume()

            // 发送握手
            let handshake: [String: Any] = [
                "mode": "offline",
                "wav_name": URL(fileURLWithPath: audioFilePath).lastPathComponent,
                "is_speaking": true
            ]
            if let data = try? JSONSerialization.data(withJSONObject: handshake),
               let text = String(data: data, encoding: .utf8) {
                task.send(.string(text)) { error in
                    if let error { Log.asr("processFile send handshake error: \(error)") }
                }
            }

            // 逐块读取并发送 PCM 数据（同步循环 + 短 sleep 节流）
            let chunkSize = 64_000
            while let chunk = try? fileHandle.read(upToCount: chunkSize), !chunk.isEmpty {
                task.send(.data(chunk)) { error in
                    if let error { Log.asr("processFile send chunk error: \(error)") }
                }
                Thread.sleep(forTimeInterval: 0.005) // 5ms 节流
            }

            // 所有数据发送完毕，发送结束信号
            let endMsg: [String: Any] = ["is_speaking": false]
            if let data = try? JSONSerialization.data(withJSONObject: endMsg),
               let text = String(data: data, encoding: .utf8) {
                task.send(.string(text)) { error in
                    if let error { Log.asr("processFile send end error: \(error)") }
                }
            }

            // 接收结果
            func receive() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        if case .string(let text) = message,
                           let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let t = json["text"] as? String {
                            transcript += t
                        }
                        receive()
                    case .failure:
                        if transcript.isEmpty {
                            finish(.failure(ASRError.noTranscript))
                        } else {
                            finish(.success(transcript))
                        }
                    }
                }
            }

            receive()
        }
    }
}

// MARK: - 事件与错误

enum ASREvent {
    case connected
    case disconnected
    case partial(String)
    case final(String)
    case error(String)
}

enum ASRError: LocalizedError {
    case fileNotFound
    case invalidURL
    case invalidWavFile
    case noTranscript
    case allRetriesExhausted

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "音频文件不存在"
        case .invalidURL: return "无效的服务器地址"
        case .invalidWavFile: return "无效的 WAV 文件"
        case .noTranscript: return "未收到转写结果"
        case .allRetriesExhausted: return "所有重试均已失败"
        }
    }
}

// MARK: - 日志

extension Log {
    static func asr(_ msg: String) {
        #if DEBUG
        print("[FunASR] \(msg)")
        #endif
    }
}
