import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    // MARK: - 编辑中的值
    @Published var asrURL: String
    @Published var llmURL: String
    @Published var llmKey: String
    @Published var llmModel: String
    @Published var asrMode: ASRMode
    @Published var offlineModelQuality: ModelQuality

    @Published var saveConfirmed = false
    @Published var validationError: String?

    // MARK: - FP32 内存警告
    @Published var showFP32Warning = false

    /// 设备物理内存是否 < 4GB
    static var isLowMemoryDevice: Bool {
        ProcessInfo.processInfo.physicalMemory < 4 * 1024 * 1024 * 1024
    }

    /// 上一次成功切换的模型质量（用于取消时回退）
    private var previousModelQuality: ModelQuality
    @Published var wsTestResult: ConnectionTestResult = .idle
    @Published var llmTestResult: ConnectionTestResult = .idle

    /// 已保存的原始值（用于判断是否有修改）
    private var saved: Snapshot

    private struct Snapshot: Equatable {
        var asrURL, llmURL, llmKey, llmModel: String
        var asrMode: ASRMode
        var offlineModelQuality: ModelQuality
    }

    /// 版本号 — 用可执行文件的修改时间（即编译时间），格式 20260620.1351
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

    /// 是否有未保存的修改
    var hasChanges: Bool {
        Snapshot(asrURL: asrURL, llmURL: llmURL, llmKey: llmKey,
                 llmModel: llmModel,
                 asrMode: asrMode, offlineModelQuality: offlineModelQuality) != saved
    }

    init() {
        let defaults = UserDefaults.standard
        let a = defaults.string(forKey: "asr_url")    ?? "ws://192.168.1.110:10095"
        let b = defaults.string(forKey: "llm_url")    ?? "https://api.deepseek.com"
        let c = defaults.string(forKey: "llm_key")    ?? ""
        let d = defaults.string(forKey: "llm_model")  ?? "deepseek-v4-pro"
        let mode = ASRMode(rawValue: defaults.string(forKey: "asr_mode") ?? "") ?? .online
        let quality = ModelQuality(rawValue: defaults.string(forKey: "offline_model_quality") ?? "") ?? .int8

        asrURL = a
        llmURL = b
        llmKey = c
        llmModel = d
        asrMode = mode
        offlineModelQuality = quality
        previousModelQuality = quality
        saved = Snapshot(asrURL: a, llmURL: b, llmKey: c, llmModel: d,
                         asrMode: mode, offlineModelQuality: quality)
    }

    private var saveGeneration = 0

    /// 显式保存；返回 true 表示保存成功（校验通过并已写入）
    @discardableResult
    func save() -> Bool {
        // 校验
        if let error = validate() {
            validationError = error
            return false
        }
        validationError = nil

        let defaults = UserDefaults.standard
        defaults.set(asrURL,   forKey: "asr_url")
        defaults.set(llmURL,   forKey: "llm_url")
        defaults.set(llmKey,   forKey: "llm_key")
        defaults.set(llmModel, forKey: "llm_model")
        defaults.set(asrMode.rawValue, forKey: "asr_mode")
        defaults.set(offlineModelQuality.rawValue, forKey: "offline_model_quality")

        saved = Snapshot(asrURL: asrURL, llmURL: llmURL, llmKey: llmKey,
                         llmModel: llmModel,
                         asrMode: asrMode, offlineModelQuality: offlineModelQuality)

        // 短暂显示"已保存"，使用代数防止快速多次保存时的闪烁
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

    // MARK: - 输入校验

    /// 校验所有必填字段；返回 nil 表示通过，否则返回错误信息
    func validate() -> String? {
        // 必填字段：LLM 始终必填，FunASR 仅在在线模式下必填
        var requiredFields: [(String, String)] = [
            ("LLM API 地址", llmURL),
            ("API Key", llmKey),
            ("模型名称", llmModel),
        ]
        if asrMode == .online {
            requiredFields.insert(("FunASR 地址", asrURL), at: 0)
        }
        for (name, value) in requiredFields {
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(name) 不能为空"
            }
        }
        // URL 格式校验：LLM 始终校验，FunASR 仅在线模式校验
        var urlFields: [(String, String)] = [("LLM API 地址", llmURL)]
        if asrMode == .online {
            urlFields.append(("FunASR 地址", asrURL))
        }
        for (name, value) in urlFields {
            guard let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
                  let scheme = url.scheme,
                  !scheme.isEmpty,
                  url.host != nil
            else {
                return "\(name) 格式不正确"
            }
        }
        return nil
    }

    // MARK: - 连接测试

    func testWebSocket() {
        guard wsTestResult != .testing else { return }
        wsTestResult = .testing
        let url = asrURL
        Task {
            let result = await ConnectionTester.testWebSocket(urlString: url)
            wsTestResult = result
        }
    }

    func testLLM() {
        guard llmTestResult != .testing else { return }
        llmTestResult = .testing
        let url = llmURL
        let key = llmKey
        let model = llmModel
        Task {
            let result = await ConnectionTester.testLLMAPI(baseURL: url, apiKey: key, model: model)
            llmTestResult = result
        }
    }

    var isTesting: Bool {
        wsTestResult == .testing || llmTestResult == .testing
    }

    func test() {
        testWebSocket()
        testLLM()
    }

    // MARK: - 模型下载（委托给 ModelDownloadManager）

    /// 模型下载管理器（由 View 层注入）
    var modelDownloadManager: ModelDownloadManager?

    /// 当前下载状态，由 ModelDownloadManager 同步
    var modelDownloadState: ModelDownloadManager.DownloadState {
        modelDownloadManager?.downloadState ?? .idle
    }

    /// 当前下载进度 0...1
    var modelDownloadProgress: Double {
        modelDownloadManager?.downloadProgress ?? 0
    }

    /// 当前选定质量的模型是否已下载
    var isModelDownloaded: Bool {
        ModelDownloadManager.isModelDownloaded(offlineModelQuality)
    }

    func startDownload() async {
        guard let manager = modelDownloadManager else { return }
        do {
            try await manager.downloadModel(quality: offlineModelQuality)
        } catch {
            // 错误状态已由 ModelDownloadManager 设置
        }
    }

    func importModel(from url: URL) async {
        guard let manager = modelDownloadManager else { return }
        do {
            try await manager.importModel(from: url, quality: offlineModelQuality)
        } catch {
            // 错误状态已由 ModelDownloadManager 设置
        }
    }

    func cancelDownload() {
        modelDownloadManager?.cancelDownload()
    }

    func deleteModel() async {
        modelDownloadManager?.deleteModel(quality: offlineModelQuality)
    }

    // MARK: - FP32 内存警告

    /// 当用户切换模型质量时调用。若选中 FP32 且设备内存 < 4GB，弹出警告。
    func checkFP32Switch(_ newQuality: ModelQuality) {
        if newQuality == .fp32 && Self.isLowMemoryDevice {
            showFP32Warning = true
            // 暂不更新 previousModelQuality，等用户确认
        } else {
            previousModelQuality = newQuality
        }
    }

    /// 用户确认切换 FP32
    func confirmFP32Switch() {
        showFP32Warning = false
        previousModelQuality = .fp32
    }

    /// 用户取消切换 FP32，回退到之前的质量
    func cancelFP32Switch() {
        showFP32Warning = false
        offlineModelQuality = previousModelQuality
    }
}
