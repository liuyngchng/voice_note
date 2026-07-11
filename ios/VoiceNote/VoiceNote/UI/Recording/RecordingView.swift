import SwiftUI
import UniformTypeIdentifiers

struct RecordingView: View {
    @ObservedObject var viewModel: RecordingViewModel
    let onBack: () -> Void
    let onRecordComplete: (UUID) -> Void

    @State private var hasNavigated = false
    @State private var dotPulse = false
    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.errorMessage {
                // 错误提示
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    Button("返回") { onBack() }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            } else {
                recordingContent
            }
        }
        .navigationTitle("录音中")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("返回") {
                    if viewModel.isRecording {
                        viewModel.stopRecording(navigateToDetail: false)
                    }
                    onBack()
                }
            }
        }
        .modifier(ToolbarBackgroundModifier(isRecording: viewModel.isRecording))
        .onAppear {
            if !hasStarted {
                hasStarted = true
                viewModel.startRecording()
            }
        }
        .onChange(of: viewModel.isRecording) { newValue in
            if !newValue, !hasNavigated, viewModel.shouldNavigateToDetail, let recordId = viewModel.currentRecordId {
                hasNavigated = true
                onRecordComplete(recordId)
            }
        }
    }

    // MARK: - 录音中

    private var recordingContent: some View {
        VStack(spacing: 0) {
            recordingIndicator

            if viewModel.isStarting {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在启动录音...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                // 音频波形可视化
                AudioWaveformView(levels: viewModel.audioLevelHistory)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

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
                                Text(viewModel.displayTranscript)
                                    .font(.body)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                            // 底部锚点（与 Android LaunchedEffect + animateScrollTo 对齐）
                            Color.clear
                                .frame(height: 1)
                                .id("bottomAnchor")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: viewModel.transcript) { _ in
                        withAnimation {
                            proxy.scrollTo("bottomAnchor", anchor: .bottom)
                        }
                    }
                }
                .padding(.top, 12)

                VStack(spacing: 8) {
                    Button(action: {
                        viewModel.stopRecording(navigateToDetail: true)
                    }) {
                        HStack {
                            if viewModel.isStopping {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Image(systemName: "stop.fill")
                            }
                            Text("结束")
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
        }
        .background(Color(.systemGroupedBackground))
    }

    private var recordingIndicator: some View {
        HStack(spacing: 10) {
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
}

// MARK: - 导航栏样式

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

// MARK: - 音频波形

private struct AudioWaveformView: View {
    let levels: [Float]
    private let barCount = 42
    private let maxHeight: CGFloat = 48

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(level: levelForBar(index))
            }
        }
        .frame(height: maxHeight)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func levelForBar(_ index: Int) -> Float {
        let historyIndex = levels.count - barCount + index
        guard historyIndex >= 0, historyIndex < levels.count else {
            return 0.03 // 最小高度，保持波形始终可见
        }
        return max(0.03, levels[historyIndex])
    }
}

private struct WaveformBar: View {
    let level: Float

    /// 用平方根曲线提升中低音量的视觉高度，使波形更灵敏
    private var scaledHeight: CGFloat {
        let boosted = sqrt(max(0, level))       // sqrt 拉伸中低段
        return max(4, CGFloat(boosted) * 44)
    }

    var body: some View {
        Capsule()
            .fill(colorForLevel(level))
            .frame(width: 3, height: scaledHeight)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: level)
    }

    private func colorForLevel(_ level: Float) -> Color {
        switch level {
        case 0..<0.25:  return .green
        case 0.25..<0.5: return .yellow
        default:         return .red
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
