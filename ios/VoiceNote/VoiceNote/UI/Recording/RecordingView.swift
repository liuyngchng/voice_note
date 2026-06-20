import SwiftUI

struct RecordingView: View {
    @ObservedObject var viewModel: RecordingViewModel
    let onBack: () -> Void
    let onVisitComplete: (UUID) -> Void

    @State private var hasNavigated = false

    var body: some View {
        Group {
            if viewModel.isRecording {
                recordingContent
            } else {
                formContent
            }
        }
        .navigationTitle(viewModel.isRecording ? "录音中" : "新建记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("返回") {
                    if viewModel.isRecording {
                        viewModel.stopVisit(navigateToDetail: false)
                    }
                    onBack()
                }
            }
        }
        .modifier(ToolbarBackgroundModifier(
            isRecording: viewModel.isRecording
        ))
        .onChange(of: viewModel.isRecording) { newValue in
            if !newValue, !hasNavigated, viewModel.shouldNavigateToDetail, let visitId = viewModel.currentVisitId {
                hasNavigated = true
                onVisitComplete(visitId)
            }
        }
    }

    // MARK: - 录音中

    private var recordingContent: some View {
        VStack(spacing: 0) {
            recordingIndicator

            if !viewModel.title.isEmpty {
                Text(viewModel.title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if viewModel.transcript.isEmpty {
                            Text("语音识别结果将在此显示")
                                .font(.subheadline)
                                .foregroundColor(.secondary.opacity(0.4))
                                .padding(.top, 80)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(viewModel.transcript)
                                .font(.body)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .id("transcript")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: viewModel.transcript) { _ in
                    withAnimation {
                        proxy.scrollTo("transcript", anchor: .bottom)
                    }
                }
            }
            .padding(.top, 12)

            VStack(spacing: 8) {
                Button(action: {
                    viewModel.stopVisit(navigateToDetail: true)
                }) {
                    HStack {
                        if viewModel.isStopping {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text("结束录音")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundColor(.white)
                    .background(Color.red)
                    .clipShape(Capsule())
                }
                .disabled(viewModel.isStopping)
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    @State private var dotPulse = false

    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            // 脉冲红点（对齐 iOS 语音备忘录）
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .scaleEffect(dotPulse ? 1.8 : 1.0)
                    .opacity(dotPulse ? 0 : 0.5)
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    dotPulse = true
                }
            }

            Text("录音中")
                .font(.subheadline)
                .bold()
                .foregroundColor(.red)

            Spacer()

            Text(formatDuration(viewModel.durationSeconds))
                .font(.title3)
                .bold()
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - 表单

    private var formContent: some View {
        Form {
            Section(header: Text("记录信息")) {
                TextField("录音名称（可选）", text: $viewModel.title)

                TextField("备注", text: $viewModel.notes)

                TextField("描述", text: $viewModel.description)

                TextField("参与人员（逗号分隔）", text: $viewModel.participants)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Section {
                Button(action: { viewModel.startVisit() }) {
                    HStack {
                        if viewModel.isStarting {
                            ProgressView()
                        }
                        Text("开始录音")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(viewModel.isStarting)
            }
        }
    }
}

// MARK: - 导航栏样式: iOS 16+ toolbarBackground / iOS 14/15 UINavigationBarAppearance

private struct ToolbarBackgroundModifier: ViewModifier {
    let isRecording: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarBackground(
                    isRecording ? Color.red : Color.accentColor,
                    for: .navigationBar
                )
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            content
                .background(NavigationBarTinter(isRecording: isRecording))
        }
    }
}

/// 修改当前 UINavigationController 的导航栏外观，离开时恢复
private struct NavigationBarTinter: UIViewControllerRepresentable {
    let isRecording: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> NavBarProxyVC {
        NavBarProxyVC(coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: NavBarProxyVC, context: Context) {
        guard let navController = uiViewController.navigationController else { return }
        context.coordinator.saveOriginal(from: navController)

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = isRecording
            ? UIColor.systemRed
            : UIColor.systemBlue
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]

        navController.navigationBar.standardAppearance = appearance
        navController.navigationBar.scrollEdgeAppearance = appearance
        navController.navigationBar.tintColor = .white
    }

    final class NavBarProxyVC: UIViewController {
        let coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            coordinator.restore()
        }
    }

    final class Coordinator {
        private weak var navController: UINavigationController?
        private var originalStandardAppearance: UINavigationBarAppearance?
        private var originalScrollEdgeAppearance: UINavigationBarAppearance?
        private var originalTintColor: UIColor?
        private var didSave = false

        func saveOriginal(from nc: UINavigationController) {
            guard !didSave else { return }
            navController = nc
            originalStandardAppearance = nc.navigationBar.standardAppearance
            originalScrollEdgeAppearance = nc.navigationBar.scrollEdgeAppearance
            originalTintColor = nc.navigationBar.tintColor
            didSave = true
        }

        func restore() {
            guard let nc = navController else { return }
            nc.navigationBar.standardAppearance = originalStandardAppearance
                ?? UINavigationBarAppearance()
            nc.navigationBar.scrollEdgeAppearance = originalScrollEdgeAppearance
            nc.navigationBar.tintColor = originalTintColor
        }
    }
}

// MARK: - 格式工具

private func formatDuration(_ seconds: TimeInterval) -> String {
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    let s = Int(seconds) % 60
    if h > 0 {
        return String(format: "%02d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%02d:%02d", m, s)
    }
}
