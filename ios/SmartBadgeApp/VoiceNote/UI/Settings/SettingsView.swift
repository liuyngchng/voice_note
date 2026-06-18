import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onBack: () -> Void

    var body: some View {
        Form {
            Section(header: Text("FunASR 语音识别")) {
                TextField("WebSocket 地址", text: $viewModel.asrURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
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

                HStack {
                    Spacer()
                    Button(action: { viewModel.test() }) {
                        Label("测试", systemImage: "checklist")
                            .font(.caption)
                    }
                    .disabled(viewModel.isTesting)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    Spacer()
                }
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
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("返回", action: onBack)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    viewModel.save()
                }
                .disabled(!viewModel.hasChanges)
            }
        }
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
