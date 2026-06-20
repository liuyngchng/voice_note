import SwiftUI
import AVFoundation
import Network

/// App 入口
/// 对齐 Android: SmartBadgeApp.kt + MainActivity.kt
@main
struct SmartBadgeApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
        }
    }
}

// MARK: - 权限请求 (麦克风 + 局域网)

private struct PermissionModifier: ViewModifier {
    @State private var hasRequested = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !hasRequested else { return }
            hasRequested = true

            // 0. 版本号
            let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            print("[App] 语音笔记 v\(shortVersion) build \(build) 启动")

            // 1. 麦克风权限
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                print(granted ? "[Perm] 麦克风权限已授予" : "[Perm] 麦克风权限被拒绝")
            }

            // 2. 局域网权限 — iOS 14+ 自动弹窗
            //    用 NWConnection 触达本地 IP 触发系统对话框
            let asrURL = UserDefaults.standard.string(forKey: "asr_url") ?? "ws://192.168.1.110:10095"
            if let url = URL(string: asrURL),
               let host = url.host,
               let port = url.port {
                let conn = NWConnection(
                    host: NWEndpoint.Host(host),
                    port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                    using: .tcp
                )
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed:
                        conn.cancel()
                    default:
                        break
                    }
                }
                conn.start(queue: .global())
                // 3 秒后取消，避免长时间挂起
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    conn.cancel()
                }
            }
        }
    }
}

// MARK: - 根导航

private struct RootView: View {
    @EnvironmentObject var container: AppContainer

    // 导航状态 (iOS 14 兼容: 使用 NavigationLink(isActive:) 替代 NavigationPath)
    @State private var showRecording = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showDetail = false
    @State private var detailId: UUID?

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
                    showSettings = true
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
            onVisitComplete: { id in
                showRecording = false
            }
        )
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Detail 详情页

    private func detailScreen(id: UUID) -> some View {
        DetailView(
            viewModel: DetailViewModel(container: container),
            visitId: id,
            onBack: { showDetail = false }
        )
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - History 历史页

    private var historyScreen: some View {
        HistoryView(
            viewModel: HistoryViewModel(container: container),
            onVisitTap: { id in
                // History 内部自己管理推入 Detail
            },
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
