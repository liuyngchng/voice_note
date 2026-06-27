import Foundation

/// 离线标点恢复客户端 — 通过 sherpa-onnx C API 对 ASR 结果添加标点
/// 模型按需加载，使用后保持到 app 退出
final class OfflinePunctuationClient {
    private var punct: OpaquePointer?
    private var isInitialized = false

    deinit {
        destroy()
    }

    // MARK: - 初始化

    /// 确保标点处理器已初始化（若模型存在）
    func ensureInitialized() {
        guard !isInitialized else { return }

        guard PunctuationModelManager.isModelDownloaded() else {
            Log.asr("标点模型未下载，跳过标点恢复")
            return
        }

        let modelPath = PunctuationModelManager.modelFilePath().path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            Log.asr("标点模型文件不存在: \(modelPath)")
            return
        }

        var config = SherpaOnnxOfflinePunctuationConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflinePunctuationConfig>.size)

        let modelStr = strdup(modelPath)!
        let providerStr = strdup("cpu")!
        defer {
            free(modelStr)
            free(providerStr)
        }

        config.model.ct_transformer = UnsafePointer(modelStr)
        config.model.num_threads = 1
        config.model.debug = 0
        config.model.provider = UnsafePointer(providerStr)

        guard let p = SherpaOnnxCreateOfflinePunctuation(&config) else {
            Log.asr("标点处理器创建失败")
            return
        }
        punct = p
        isInitialized = true
        Log.asr("标点处理器初始化完成")
    }

    // MARK: - 标点恢复

    /// 对文本添加标点，返回带标点的文本
    /// 若模型未初始化则返回原文
    func addPunctuation(to text: String) -> String {
        guard isInitialized, let punct else { return text }
        guard !text.isEmpty else { return text }

        let result = text.withCString { cStr in
            SherpaOfflinePunctuationAddPunct(punct, cStr)
        }
        guard let result else {
            Log.asr("标点恢复返回 nil，使用原文")
            return text
        }

        let punctuated = String(cString: result)
        SherpaOfflinePunctuationFreeText(result)
        return punctuated
    }

    // MARK: - 生命周期

    var isAvailable: Bool { isInitialized }

    private func destroy() {
        if let punct {
            SherpaOnnxDestroyOfflinePunctuation(punct)
            self.punct = nil
        }
        isInitialized = false
        Log.asr("标点处理器已释放")
    }
}
