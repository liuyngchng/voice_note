import SwiftUI
import UniformTypeIdentifiers

/// 离线 LLM 设置组件 — 模型选择 + 下载/导入
/// 嵌入在 SettingsView 中使用，对标 OfflineASRSettingsView
struct OfflineLLMSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var downloadManager: LLMModelManager
    @Binding var showFileImporter: Bool
    @State private var copyToast = false

    var body: some View {
        Section(header: Text("离线大模型")) {
            Picker("模型选择", selection: $viewModel.llmModelInfo) {
                ForEach(LLMModelInfo.allCases, id: \.self) { info in
                    Text(info.displayName).tag(info)
                }
            }
            .pickerStyle(.menu)

            modelStatusSection
        }
    }

    // MARK: - 模型状态

    @ViewBuilder
    private var modelStatusSection: some View {
        switch downloadManager.downloadState {
        case .idle:
            if LLMModelManager.isModelDownloaded(viewModel.llmModelInfo) {
                modelReadyRow
            } else {
                modelNotDownloadedRow
            }

        case .downloading(let progress):
            downloadingRow(progress)

        case .completed:
            modelReadyRow
            if !LLMModelManager.isModelDownloaded(viewModel.llmModelInfo) {
                actionButtonsRow
            }

        case .failed(let error):
            downloadFailedRow(error)
        }
    }

    // MARK: - 各状态行

    private var modelReadyRow: some View {
        HStack {
            Label("模型已就绪", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Spacer()
            let size = LLMModelManager.downloadedModelSize(viewModel.llmModelInfo)
            Text("\(size / 1_048_576)MB")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                Task { await viewModel.deleteLLMModel() }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    private var modelNotDownloadedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("模型未下载")
                    .font(.subheadline)
            }
            Text("需要离线大模型才能本地生成总结")
                .font(.caption)
                .foregroundColor(.secondary)
            downloadHintSection
            actionButtonsRow
        }
    }

    private func downloadingRow(_ progress: Double) -> some View {
        let sourceName = downloadManager.activeSource.rawValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text("\(sourceName)下载中...")
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            ProgressView(value: progress)
            Button(action: { viewModel.cancelLLMDownload() }) {
                Text("取消").foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func downloadFailedRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("下载失败")
                    .font(.subheadline)
                    .foregroundColor(.red)
            }
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
            downloadHintSection
            actionButtonsRow
        }
    }

    // MARK: - 下载地址提示

    private var downloadHintSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("💡 下载地址（可在电脑下载后通过「上传」导入手机）：")
                .font(.caption2)
                .foregroundColor(.secondary)

            if let msURL = viewModel.llmModelInfo.modelscopeDownloadURL {
                HStack(spacing: 4) {
                    Text("ModelScope: \(msURL)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = msURL
                        copyToast = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copyToast = false
                        }
                    } label: {
                        Image(systemName: copyToast ? "doc.on.doc.fill" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let ghURL = viewModel.llmModelInfo.githubDownloadURL {
                HStack(spacing: 4) {
                    Text("GitHub: \(ghURL)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = ghURL
                        copyToast = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copyToast = false
                        }
                    } label: {
                        Image(systemName: copyToast ? "doc.on.doc.fill" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if viewModel.llmModelInfo.modelscopeDownloadURL == nil
                && viewModel.llmModelInfo.githubDownloadURL == nil {
                Text("注：自定义模型需手动上传 GGUF 文件")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if copyToast {
                Text("已复制 ✓")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - 操作按钮

    private var actionButtonsRow: some View {
        HStack(spacing: 8) {
            if viewModel.llmModelInfo.modelscopeDownloadURL != nil {
                Button {
                    Task { await viewModel.startLLMFromModelScope() }
                } label: {
                    Label("ModelScope", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(downloadManager.isDownloading)
            }

            if viewModel.llmModelInfo.githubDownloadURL != nil {
                Button {
                    Task { await viewModel.startLLMFromGitHub() }
                } label: {
                    Label("GitHub", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(downloadManager.isDownloading)
            }

            Spacer()

            Button {
                showFileImporter = true
            } label: {
                Label("上传", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(downloadManager.isDownloading)
        }
    }
}
