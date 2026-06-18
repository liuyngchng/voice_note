import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    // MARK: - 编辑中的值
    @Published var asrURL: String
    @Published var llmURL: String
    @Published var llmKey: String
    @Published var llmModel: String

    @Published var saveConfirmed = false

    // MARK: - 连接测试状态
    @Published var wsTestResult: ConnectionTestResult = .idle
    @Published var llmTestResult: ConnectionTestResult = .idle

    /// 已保存的原始值（用于判断是否有修改）
    private var saved: Snapshot

    private struct Snapshot: Equatable {
        var asrURL, llmURL, llmKey, llmModel: String
    }

    /// 构建版本号 — 用 Info.plist 修改时间，每次 build 自动更新
    var appVersion: String {
        guard let url = Bundle.main.url(forResource: "Info", withExtension: "plist"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date
        else { return "unknown" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        return fmt.string(from: modDate)
    }

    /// 是否有未保存的修改
    var hasChanges: Bool {
        Snapshot(asrURL: asrURL, llmURL: llmURL, llmKey: llmKey,
                 llmModel: llmModel) != saved
    }

    init() {
        let defaults = UserDefaults.standard
        let a = defaults.string(forKey: "asr_url")    ?? "ws://192.168.27.29:10095"
        let b = defaults.string(forKey: "llm_url")    ?? "https://api.deepseek.com"
        let c = defaults.string(forKey: "llm_key")    ?? ""
        let d = defaults.string(forKey: "llm_model")  ?? "deepseek-v4-pro"

        asrURL = a
        llmURL = b
        llmKey = c
        llmModel = d
        saved = Snapshot(asrURL: a, llmURL: b, llmKey: c, llmModel: d)
    }

    private var saveGeneration = 0

    /// 显式保存
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(asrURL,   forKey: "asr_url")
        defaults.set(llmURL,   forKey: "llm_url")
        defaults.set(llmKey,   forKey: "llm_key")
        defaults.set(llmModel, forKey: "llm_model")

        saved = Snapshot(asrURL: asrURL, llmURL: llmURL, llmKey: llmKey,
                         llmModel: llmModel)

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
}
