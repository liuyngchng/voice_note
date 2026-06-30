import SwiftUI
import AVFoundation
import os

/// App 入口
@main
struct SmartBadgeApp: App {
    @StateObject private var container = AppContainer()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(appState)
        }
    }
}

// MARK: - App 全局状态

/// 模型加载状态，对齐 Android: OfflineASRClient.ModelStatus
enum ModelStatus {
    case unknown
    case missing
    case loading
    case ready
    case error
}

@MainActor
final class AppState: ObservableObject {
    /// 模型加载状态
    @Published var modelStatus: ModelStatus = .unknown
    /// 模型加载错误描述
    @Published var modelLoadError: String?
    /// 是否需要引导用户导入模型（弹 alert）
    @Published var needsModelGuidance = false

    /// 在 app 启动时调用，加载离线模型（ASR + VAD + 标点）
    func loadModelOnStartup(container: AppContainer) {
        preloadModels(container: container)
    }

    /// 从设置页返回时刷新模型状态（用户可能刚下载了模型）
    func refreshModelStatus(container: AppContainer) {
        // 正在加载或已就绪则跳过，避免重复加载
        guard modelStatus != .ready, modelStatus != .loading else { return }
        preloadModels(container: container)
    }

    // MARK: - 私有

    private func preloadModels(container: AppContainer) {
        let quality = ASRModelManager.savedQuality()

        // 检查 ASR 模型文件 + tokens 是否在本地
        guard ASRModelManager.isModelDownloaded(quality),
              FileManager.default.fileExists(atPath: ASRModelManager.tokensFilePath().path)
        else {
            modelStatus = .missing
            needsModelGuidance = true
            appLog("app", "[App] 离线语音模型未下载，需要引导用户导入")
            return
        }

        // ASR 已加载且 VAD 已就绪 → 直接标记 ready
        let asrClient = container.offlineASRClient
        if asrClient.isAvailable, asrClient.loadedQuality == quality {
            modelStatus = .ready
            needsModelGuidance = false
            appLog("app", "[App] 离线模型已加载，跳过")
            return
        }

        modelStatus = .loading
        appLog("app", "[App] 开始加载离线模型 (quality=\(quality.rawValue))")

        Task.detached(priority: .utility) {
            do {
                // 1. 加载 ASR 模型
                try asrClient.ensureRecognizer(quality: quality)
                appLog("app", "[App] ASR 模型加载完成")

                // 2. 加载 VAD
                let vadReady = asrClient.ensureVad()
                appLog("app", "[App] VAD \(vadReady ? "已就绪" : "不可用")")

                // 3. 加载标点模型（可选，不存在则跳过）
                container.offlinePunctuationClient.ensureInitialized()
                appLog("app", "[App] 标点模型 \(container.offlinePunctuationClient.isAvailable ? "已加载" : "未安装，跳过")")

                await MainActor.run {
                    self.modelStatus = .ready
                    self.needsModelGuidance = false
                    self.modelLoadError = nil
                    appLog("app", "[App] 全部模型加载完成")
                }
            } catch {
                appLog("app", "[App] 模型加载失败: \(error.localizedDescription)")
                await MainActor.run {
                    self.modelStatus = .error
                    self.modelLoadError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 权限请求

private let permLogger = Logger(subsystem: "com.voicenote", category: "app")

private func appLog(_ tag: String, _ msg: String) {
    permLogger.info("\(msg)")
    LogFile.shared.append(tag, msg)
}

private struct PermissionModifier: ViewModifier {
    @State private var hasRequested = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !hasRequested else { return }
            hasRequested = true

            // 0. 版本号
            let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            appLog("app","[App] 语音笔记 v\(shortVersion) build \(build) 启动")

            // 1. 麦克风权限
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                appLog("app","\(granted ? "[Perm] 麦克风权限已授予" : "[Perm] 麦克风权限被拒绝")")
            }
        }
    }
}

// MARK: - 根导航

private struct RootView: View {
    @EnvironmentObject var container: AppContainer
    @EnvironmentObject var appState: AppState

    @State private var showRecording = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showDetail = false
    @State private var detailId: UUID?
    @State private var showModelGuide = false

    var body: some View {
        NavigationView {
            homeScreen
                .background(recordingLink)
                .background(historyLink)
                .background(settingsLink)
                .background(detailLink)
        }
        .navigationViewStyle(.stack)
        .modifier(PermissionModifier())
        .onAppear {
            appState.loadModelOnStartup(container: container)
            appState.refreshModelStatus(container: container)
        }
        .alert(isPresented: $showModelGuide) {
            Alert(
                title: Text("需要导入语音识别模型"),
                message: Text("检测到离线语音模型尚未下载或导入。\n\n请前往「设置」页面下载或导入 SenseVoice 模型，否则无法进行语音识别。"),
                primaryButton: .default(Text("前往设置")) {
                    // 延迟导航，等待 alert 关闭动画完成，避免与 NavigationLink push 冲突
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showSettings = true
                    }
                },
                secondaryButton: .cancel(Text("稍后"))
            )
        }
        .onChange(of: appState.needsModelGuidance) { needs in
            if needs {
                showModelGuide = true
            }
        }
    }

    // MARK: - 隐藏 NavigationLink (程序化导航)

    private var recordingLink: some View {
        NavigationLink(
            destination: recordingScreen,
            isActive: $showRecording,
            label: { EmptyView() }
        )
    }

    private var historyLink: some View {
        NavigationLink(
            destination: historyScreen,
            isActive: $showHistory,
            label: { EmptyView() }
        )
    }

    private var settingsLink: some View {
        NavigationLink(
            destination: settingsScreen,
            isActive: $showSettings,
            label: { EmptyView() }
        )
    }

    @ViewBuilder
    private var detailLink: some View {
        if let id = detailId {
            NavigationLink(
                destination: detailScreen(id: id),
                isActive: $showDetail,
                label: { EmptyView() }
            )
        }
    }

    // MARK: - Home 首页

    private var homeScreen: some View {
        HomeView(
            viewModel: HomeViewModel(container: container),
            modelStatus: appState.modelStatus,
            onNewRecord: { showRecording = true },
            onRecordTap: { id in
                detailId = id
                showDetail = true
            },
            onSettingsTap: { showSettings = true }
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if showModelGuide {
                        // alert 正在显示，先关闭再延迟导航，避免转场冲突
                        showModelGuide = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showSettings = true
                        }
                    } else {
                        showSettings = true
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    // MARK: - Recording 录音页

    private var recordingScreen: some View {
        RecordingView(
            viewModel: RecordingViewModel(container: container),
            onBack: { showRecording = false },
            onRecordComplete: { _ in
                showRecording = false
            }
        )
    }

    // MARK: - Detail 详情页

    private func detailScreen(id: UUID) -> some View {
        DetailView(
            viewModel: DetailViewModel(container: container),
            recordId: id,
            onBack: { showDetail = false }
        )
    }

    // MARK: - History 历史页

    private var historyScreen: some View {
        HistoryView(
            viewModel: HistoryViewModel(container: container),
            onRecordTap: { id in },
            onBack: { showHistory = false }
        )
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Settings 设置页

    private var settingsScreen: some View {
        SettingsView(
            viewModel: SettingsViewModel(),
            onBack: { showSettings = false }
        )
        .navigationBarBackButtonHidden(true)
    }
}

#if DEBUG
struct SmartBadgeApp_Previews: PreviewProvider {
    static var previews: some View {
        Text("SmartBadge App Preview")
    }
}
#endif
