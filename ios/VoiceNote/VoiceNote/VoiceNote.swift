import SwiftUI
import AVFoundation

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

// MARK: - 麦克风权限请求

private struct MicrophonePermissionModifier: ViewModifier {
    @State private var hasRequested = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !hasRequested else { return }
            hasRequested = true
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                if granted {
                    print("[Mic] 麦克风权限已授予")
                } else {
                    print("[Mic] 麦克风权限被拒绝")
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
        .modifier(MicrophonePermissionModifier())
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
