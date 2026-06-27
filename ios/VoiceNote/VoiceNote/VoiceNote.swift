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

@MainActor
final class AppState: ObservableObject {
    /// 离线 ASR 模型是否已加载
    @Published var isModelLoaded = false
    /// 模型加载错误
    @Published var modelLoadError: String?
    /// 是否需要引导用户导入模型
    @Published var needsModelGuidance = false

    private let offlineASRClient = OfflineASRClient()

    /// 在 app 启动时调用，加载离线语音模型
    func loadModelOnStartup() {
        let quality = ASRModelManager.savedQuality()

        guard ASRModelManager.isModelDownloaded(quality) else {
            appLog("app", "[App] 离线语音模型未下载，需要引导用户导入")
            needsModelGuidance = true
            return
        }

        do {
            try offlineASRClient.ensureRecognizer(quality: quality)
            isModelLoaded = true
            needsModelGuidance = false
            appLog("app", "[App] 离线语音模型加载完成: \(quality.rawValue)")
        } catch {
            modelLoadError = error.localizedDescription
            appLog("app", "[App] 离线语音模型加载失败: \(error.localizedDescription)")
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
            appState.loadModelOnStartup()
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
            onNewVisit: { showRecording = true },
            onVisitTap: { id in
                detailId = id
                showDetail = true
            }
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
            onVisitComplete: { _ in
                showRecording = false
            }
        )
    }

    // MARK: - Detail 详情页

    private func detailScreen(id: UUID) -> some View {
        DetailView(
            viewModel: DetailViewModel(container: container),
            visitId: id,
            onBack: { showDetail = false }
        )
    }

    // MARK: - History 历史页

    private var historyScreen: some View {
        HistoryView(
            viewModel: HistoryViewModel(container: container),
            onVisitTap: { id in },
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
