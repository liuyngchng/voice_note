import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    // MARK: - ASR 模型设置
    @Published var offlineModelQuality: ModelQuality

    // MARK: - 标点模型设置
    @Published var punctuationModelState: ModelState = .idle

    // MARK: - LLM 模型（固定 Qwen2.5-1.5B）
    let llmModelInfo: LLMModelInfo = .qwen2_5_1_5b_q4km

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
        Snapshot(offlineModelQuality: offlineModelQuality) != saved
    }

    init() {
        let defaults = UserDefaults.standard
        let quality = ModelQuality(rawValue: defaults.string(forKey: "offline_model_quality") ?? "") ?? .int8

        offlineModelQuality = quality
        previousModelQuality = quality
        saved = Snapshot(offlineModelQuality: quality)
    }

    private var saveGeneration = 0

    @discardableResult
    func save() -> Bool {
        validationError = nil

        let defaults = UserDefaults.standard
        defaults.set(offlineModelQuality.rawValue, forKey: "offline_model_quality")

        saved = Snapshot(offlineModelQuality: offlineModelQuality)

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

    // MARK: - LLM 模型下载（委托给 LLMModelManager）

    var llmModelManager = LLMModelManager()

    func startLLMFromModelScope() {
        llmModelManager.downloadFromModelScope(llmModelInfo)
    }

    func importLLMModel(from url: URL, cleanup: (() -> Void)? = nil) {
        llmModelManager.importFromFile(url, info: llmModelInfo, cleanup: cleanup)
    }

    func cancelLLMDownload() {
        llmModelManager.cancelDownload()
    }

    func deleteLLMModel() async {
        await llmModelManager.deleteModel(llmModelInfo)
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

    @Published var logShareTrigger = false

}
