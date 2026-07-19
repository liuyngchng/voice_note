import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    // MARK: - ASR 模型设置
    @Published var offlineModelQuality: ModelQuality

    // MARK: - 标点模型设置
    @Published var punctuationModelState: ModelState = .idle

    // MARK: - 在线 LLM 配置
    @Published var llmAPIURL: String
    @Published var llmAPIKey: String
    @Published var llmModelName: String

    enum ModelState {
        case idle
        case downloading(progress: Double)
        case completed(Date)
        case failed(String)
    }

    @Published var saveConfirmed = false
    @Published var validationError: String?

    // MARK: - FP32 内存警告
    @Published var showFP32Warning = false

    static var isLowMemoryDevice: Bool {
        ProcessInfo.processInfo.physicalMemory < 4 * 1024 * 1024 * 1024
    }

    private var previousModelQuality: ModelQuality

    private var saved: Snapshot

    private struct Snapshot: Equatable {
        var offlineModelQuality: ModelQuality
        var llmAPIURL: String
        var llmAPIKey: String
        var llmModelName: String
    }

    var appVersion: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let modDate = attrs[.modificationDate] as? Date
        else { return "unknown" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd.HHmm"
        return fmt.string(from: modDate)
    }

    var hasChanges: Bool {
        Snapshot(
            offlineModelQuality: offlineModelQuality,
            llmAPIURL: llmAPIURL,
            llmAPIKey: llmAPIKey,
            llmModelName: llmModelName
        ) != saved
    }

    init() {
        let defaults = UserDefaults.standard
        let quality = ModelQuality(rawValue: defaults.string(forKey: "offline_model_quality") ?? "") ?? .int8

        let apiURL = defaults.string(forKey: "llm_online_api_url") ?? OnlineLLMClient.apiBaseURL
        let apiKey = defaults.string(forKey: "llm_online_api_key") ?? ""
        let model = defaults.string(forKey: "llm_online_model_name") ?? OnlineLLMClient.modelName

        offlineModelQuality = quality
        previousModelQuality = quality
        llmAPIURL = apiURL
        llmAPIKey = apiKey
        llmModelName = model

        saved = Snapshot(
            offlineModelQuality: quality,
            llmAPIURL: apiURL,
            llmAPIKey: apiKey,
            llmModelName: model
        )
    }

    private var saveGeneration = 0

    @discardableResult
    func save() -> Bool {
        validationError = nil

        let defaults = UserDefaults.standard
        defaults.set(offlineModelQuality.rawValue, forKey: "offline_model_quality")
        defaults.set(llmAPIURL, forKey: "llm_online_api_url")
        defaults.set(llmAPIKey, forKey: "llm_online_api_key")
        defaults.set(llmModelName, forKey: "llm_online_model_name")

        saved = Snapshot(
            offlineModelQuality: offlineModelQuality,
            llmAPIURL: llmAPIURL,
            llmAPIKey: llmAPIKey,
            llmModelName: llmModelName
        )

        let generation = saveGeneration + 1
        saveGeneration = generation
        saveConfirmed = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if saveGeneration == generation {
                saveConfirmed = false
            }
        }
        return true
    }

    // MARK: - ASR 模型下载（委托给 ASRModelManager）

    var modelDownloadManager = ASRModelManager()

    var modelDownloadState: ASRModelManager.DownloadState {
        modelDownloadManager.downloadState
    }

    var modelDownloadProgress: Double {
        modelDownloadManager.downloadProgress
    }

    var isModelDownloaded: Bool {
        ASRModelManager.isModelDownloaded(offlineModelQuality)
    }

    func startDownload() {
        modelDownloadManager.downloadModel(quality: offlineModelQuality)
    }

    func importModel(from url: URL, cleanup: (() -> Void)? = nil) {
        modelDownloadManager.importModel(from: url, quality: offlineModelQuality, cleanup: cleanup)
    }

    func cancelDownload() {
        modelDownloadManager.cancelDownload()
    }

    func deleteModel() async {
        await modelDownloadManager.deleteModel(quality: offlineModelQuality)
    }

    // MARK: - 标点模型

    /// 标点模型是否已下载
    var isPunctuationModelDownloaded: Bool {
        PunctuationModelManager.isModelDownloaded()
    }

    /// 标点模型下载管理器
    var punctuationModelManager = PunctuationModelManager()

    func startPunctuationDownload() {
        punctuationModelManager.downloadModel()
    }

    func importPunctuationModel(from url: URL, cleanup: (() -> Void)? = nil) {
        punctuationModelManager.importModel(from: url, cleanup: cleanup)
    }

    func cancelPunctuationDownload() {
        punctuationModelManager.cancelDownload()
    }

    func deletePunctuationModel() async {
        await punctuationModelManager.deleteModel()
    }

    // MARK: - FP32 内存警告

    func checkFP32Switch(_ newQuality: ModelQuality) {
        if newQuality == .fp32 && Self.isLowMemoryDevice {
            showFP32Warning = true
        } else {
            previousModelQuality = newQuality
        }
    }

    func confirmFP32Switch() {
        showFP32Warning = false
        previousModelQuality = .fp32
    }

    func cancelFP32Switch() {
        showFP32Warning = false
        offlineModelQuality = previousModelQuality
    }

    // MARK: - 诊断日志

    /// 日志文件 URL（供导出）
    var logFileURL: URL {
        LogFile.shared.logFileURL
    }

    func shareLogFile() {
        // 触发前先同步刷盘
        LogFile.shared.syncAppend("diag", "用户导出日志")
        logShareTrigger.toggle()
    }

    func clearLog() {
        LogFile.shared.syncAppend("diag", "用户清除日志")
        LogFile.shared.clear()
    }

    @Published var logShareTrigger = false

    // MARK: - 连接测试

    struct TestResult: Identifiable {
        let id = UUID()
        let name: String
        let success: Bool
        let message: String
    }

    @Published var isTesting = false
    @Published var testResults: [TestResult] = []
    @Published var showTestResults = false

    func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        testResults = []
        showTestResults = false

        // 捕获当前表单值，避免测试过程中用户修改
        let currentAPIURL = llmAPIURL
        let currentAPIKey = llmAPIKey
        let currentModelName = llmModelName

        print("[TestConnection] 开始测试连接...")
        print("[TestConnection] API URL: \(currentAPIURL.isEmpty ? "(空)" : currentAPIURL)")
        print("[TestConnection] API Key: \(currentAPIKey.isEmpty ? "(空)" : "已填写(\(currentAPIKey.count)字符)")")
        print("[TestConnection] Model: \(currentModelName.isEmpty ? "(空)" : currentModelName)")

        Task {
            var results: [TestResult] = []

            do {
                // 1. 测试离线 ASR 模型
                let modelFile = ASRModelManager.modelFilePath(offlineModelQuality)
                let tokensFile = ASRModelManager.tokensFilePath()
                let fm = FileManager.default

                let asrSuccess = fm.fileExists(atPath: modelFile.path) && fm.fileExists(atPath: tokensFile.path)
                let asrMessage: String
                if !fm.fileExists(atPath: modelFile.path) {
                    asrMessage = "离线模型未下载，请先下载"
                } else if !fm.fileExists(atPath: tokensFile.path) {
                    asrMessage = "tokens.txt 缺失，请重新下载模型"
                } else {
                    asrMessage = "离线 ASR 准备就绪 (\(offlineModelQuality.rawValue.uppercased()))"
                }
                results.append(TestResult(name: "语音识别 (离线)", success: asrSuccess, message: asrMessage))
                print("[TestConnection] ASR 检查完成: success=\(asrSuccess), msg=\(asrMessage)")

                // 2. 测试在线 LLM API（使用当前表单值，而非 UserDefaults 中已保存的值）
                if !currentAPIKey.isEmpty && !currentAPIURL.isEmpty {
                    let client = OnlineLLMClient()
                    print("[TestConnection] 开始测试 LLM API...")
                    let result = await client.testConnection(
                        apiBase: currentAPIURL,
                        apiKey: currentAPIKey,
                        model: currentModelName
                    )
                    switch result {
                    case .success(let msg):
                        print("[TestConnection] LLM API 成功: \(msg)")
                        results.append(TestResult(name: "大语言模型", success: true, message: msg))
                    case .failure(let error):
                        print("[TestConnection] LLM API 失败: \(error.localizedDescription)")
                        results.append(TestResult(name: "大语言模型", success: false, message: error.localizedDescription))
                    }
                } else {
                    print("[TestConnection] 未配置 LLM API 凭据，跳过 LLM 测试")
                    results.append(TestResult(name: "大语言模型", success: false, message: "未配置 API 地址或密钥"))
                }
            } catch {
                print("[TestConnection] 测试异常: \(error.localizedDescription)")
                results.append(TestResult(name: "测试异常", success: false, message: error.localizedDescription))
            }

            print("[TestConnection] 测试完成，\(results.count) 项结果")
            for r in results {
                print("[TestConnection]   \(r.success ? "✅" : "❌") \(r.name): \(r.message)")
            }

            await MainActor.run {
                print("[TestConnection] 设置 showTestResults = true")
                isTesting = false
                testResults = results
                showTestResults = true
            }
        }
    }

    func dismissTestResults() {
        print("[TestConnection] dismissTestResults")
        showTestResults = false
        testResults = []
    }
}
