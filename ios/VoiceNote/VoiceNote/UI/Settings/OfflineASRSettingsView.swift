import SwiftUI
import UniformTypeIdentifiers

/// 离线 ASR 设置组件 — 模型质量选择 + 下载/删除
/// 嵌入在 SettingsView 中使用
struct OfflineASRSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var downloadManager: ModelDownloadManager
    @Binding var showFileImporter: Bool
    @State private var copyToast = false

    var body: some View {
        Section(header: Text("离线模型")) {
            Picker("模型质量", selection: $viewModel.offlineModelQuality) {
                ForEach(ModelQuality.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
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
            if viewModel.isModelDownloaded {
                modelReadyRow
            } else {
                modelNotDownloadedRow
            }

        case .downloading(let progress):
            downloadingRow(progress)

        case .extracting(let progress):
            extractingRow(progress)

        case .completed:
            modelReadyRow
            if !viewModel.isModelDownloaded {
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
            Text("\(viewModel.offlineModelQuality.rawValue.uppercased())")
                .font(.caption)
                .foregroundColor(.secondary)
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
            Text("需要 SenseVoice 模型才能离线使用语音识别")
                .font(.caption)
                .foregroundColor(.secondary)
            downloadHintSection
            actionButtonsRow
        }
    }

    private func downloadingRow(_ progress: Double) -> some View {
        let isImport = downloadManager.activeOperation == .import_
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text(isImport ? "导入中..." : "下载中...")
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            ProgressView(value: progress)
            Button(action: { viewModel.cancelDownload() }) {
                Text("取消").foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func extractingRow(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text("解压提取中...")
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            ProgressView(value: progress)
            Text("正在解压并提取模型文件")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func downloadFailedRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("安装失败")
                    .font(.subheadline)
                    .foregroundColor(.red)
            }
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
            downloadHintSection
            HStack(spacing: 12) {
                retryDownloadButton
                Spacer()
                importButton
            }
        }
    }

    // MARK: - 下载地址提示

    /// 当前质量对应的下载地址
    private var modelDownloadURL: String {
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(viewModel.offlineModelQuality.archiveFilename)"
    }

    private var downloadHintSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("💡 下载地址（可在电脑下载后通过「上传」导入手机）：")
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Text(modelDownloadURL)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.blue)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button {
                    UIPasteboard.general.string = modelDownloadURL
                    Log.asr("下载链接已复制到剪贴板")
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
            if copyToast {
                Text("已复制 ✓")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - 操作按钮

    private var actionButtonsRow: some View {
        HStack(spacing: 12) {
            downloadButton
            Spacer()
            importButton
        }
    }

    private var downloadButton: some View {
        Button {
            Task { await viewModel.startDownload() }
        } label: {
            Label("下载", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderless)  // 防止 Form 整行点击劫持
        .font(.subheadline)
        .disabled(downloadManager.isDownloading)
    }

    private var retryDownloadButton: some View {
        Button("重试下载") {
            Task { await viewModel.startDownload() }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .disabled(downloadManager.isDownloading)
    }

    private var importButton: some View {
        Button {
            showFileImporter = true
        } label: {
            Label("上传", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
        .disabled(downloadManager.isDownloading)
    }
}
