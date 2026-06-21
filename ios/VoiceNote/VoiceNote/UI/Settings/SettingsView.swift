import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onBack: () -> Void

    @State private var showBackAlert = false
    @State private var showValidationAlert = false
    @State private var showModelFileImporter = false
    @StateObject private var modelDownloadManager = ModelDownloadManager()

    /// iOS 15.1 以上才支持离线识别（onnxruntime 要求）
    private var supportsOffline: Bool {
        if #available(iOS 15.1, *) { return true }
        return false
    }

    var body: some View {
        Form {
            // MARK: - ASR 模式选择
            if supportsOffline {
                Section(header: Text("语音识别")) {
                    Toggle(isOn: Binding(
                        get: { viewModel.asrMode == .offline },
                        set: { viewModel.asrMode = $0 ? .offline : .online }
                    )) {
                        Text("离线识别")
                    }

                    if viewModel.asrMode == .online {
                        TextField("WebSocket 地址", text: $viewModel.asrURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                    }
                }
            } else {
                Section(header: Text("语音识别")) {
                    TextField("WebSocket 地址", text: $viewModel.asrURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                        Text("离线识别需要 iOS 15.1 或更高版本")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // MARK: - 离线模型设置
            if supportsOffline, viewModel.asrMode == .offline {
                OfflineASRSettingsView(viewModel: viewModel,
                                       downloadManager: modelDownloadManager,
                                       showFileImporter: $showModelFileImporter)
            }

            Section(header: Text("LLM API(OpenAI)")) {
                TextField("API 地址", text: $viewModel.llmURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)

                SecureField("API Key", text: $viewModel.llmKey)

                TextField("模型名称", text: $viewModel.llmModel)
                    .autocapitalization(.none)
            }

            // MARK: - 连接测试
            Section(header: Text("连接测试")) {
                if viewModel.asrMode == .online {
                    HStack {
                        Text("FunASR WebSocket")
                            .font(.subheadline)
                        Spacer()
                        Text(viewModel.wsTestResult.message)
                            .font(.caption)
                            .foregroundColor(testResultColor(viewModel.wsTestResult))
                        Image(systemName: testResultIcon(viewModel.wsTestResult))
                            .foregroundColor(testResultColor(viewModel.wsTestResult))
                    }
                }

                HStack {
                    Text("LLM API")
                        .font(.subheadline)
                    Spacer()
                    Text(viewModel.llmTestResult.message)
                        .font(.caption)
                        .foregroundColor(testResultColor(viewModel.llmTestResult))
                    Image(systemName: testResultIcon(viewModel.llmTestResult))
                        .foregroundColor(testResultColor(viewModel.llmTestResult))
                }

                Button(action: { viewModel.test() }) {
                    HStack {
                        Text("开始测试")
                            .foregroundColor(viewModel.isTesting ? .secondary : .accentColor)
                        Spacer()
                        if viewModel.isTesting {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isTesting)
            }

            // 版本号
            Section {
                HStack {
                    Spacer()
                    Text("版本：\(viewModel.appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            // 保存状态提示
            if viewModel.saveConfirmed {
                Section {
                    HStack {
                        Spacer()
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.modelDownloadManager = modelDownloadManager
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("返回") {
                    if viewModel.hasChanges {
                        showBackAlert = true
                    } else {
                        onBack()
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    if !viewModel.save() {
                        showValidationAlert = true
                    }
                }
                .disabled(!viewModel.hasChanges)
            }
        }
        .alert(isPresented: $showBackAlert) {
            Alert(
                title: Text("未保存的修改"),
                message: Text("设置已修改但尚未保存，确定要离开吗？"),
                primaryButton: .destructive(Text("放弃修改")) { onBack() },
                secondaryButton: .cancel(Text("继续编辑"))
            )
        }
        .alert(isPresented: $showValidationAlert) {
            Alert(
                title: Text("保存失败"),
                message: Text(viewModel.validationError ?? "输入有误"),
                dismissButton: .cancel(Text("好"))
            )
        }
        .alert(isPresented: $viewModel.showFP32Warning) {
            Alert(
                title: Text("内存警告"),
                message: Text("FP32 模型约 886MB，您的设备内存较小（< 4GB），可能导致闪退。\n\n建议使用 INT8 模型（~229MB）。\n\n确定要切换吗？"),
                primaryButton: .destructive(Text("确定切换")) {
                    viewModel.confirmFP32Switch()
                },
                secondaryButton: .cancel(Text("取消")) {
                    viewModel.cancelFP32Switch()
                }
            )
        }
        .fileImporter(
            isPresented: $showModelFileImporter,
            allowedContentTypes: [.bz2],
            onCompletion: { result in
                switch result {
                case .success(let url):
                    Log.asr("用户选择了文件: \(url.lastPathComponent)")
                    Task { await viewModel.importModel(from: url) }
                case .failure(let error):
                    Log.asr("文件选择取消或失败: \(error.localizedDescription)")
                }
            }
        )
    }

    // MARK: - 测试结果辅助

    private func testResultColor(_ result: ConnectionTestResult) -> Color {
        switch result {
        case .idle:     return .secondary
        case .testing:  return .orange
        case .success:  return .green
        case .failure:  return .red
        }
    }

    private func testResultIcon(_ result: ConnectionTestResult) -> String {
        switch result {
        case .idle:     return "minus.circle"
        case .testing:  return "arrow.triangle.2.circlepath"
        case .success:  return "checkmark.circle.fill"
        case .failure:  return "xmark.circle.fill"
        }
    }
}
