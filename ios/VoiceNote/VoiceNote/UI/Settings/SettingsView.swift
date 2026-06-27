import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onBack: () -> Void

    @State private var showBackAlert = false
    @State private var showValidationAlert = false
    @State private var modelFilePickerTarget: FilePickerTarget? = nil
    @State private var filePickerErrorMessage: String? = nil
    @StateObject private var modelDownloadManager = ASRModelManager()
    @StateObject private var punctuationModelManager = PunctuationModelManager()

    enum FilePickerTarget: String, Identifiable {
        case asrModel
        case punctModel
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            // MARK: - 语音识别模型设置
            Section(header: Text("语音识别模型")) {
                Picker("模型质量", selection: $viewModel.offlineModelQuality) {
                    ForEach(ModelQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.offlineModelQuality) { newQuality in
                    viewModel.checkFP32Switch(newQuality)
                }

                asrModelStatusSection
            }

            // MARK: - 标点恢复模型
            Section(header: Text("标点恢复模型")) {
                punctModelStatusSection
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
            viewModel.punctuationModelManager = punctuationModelManager
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
        .alert(isPresented: Binding<Bool>(
            get: { filePickerErrorMessage != nil },
            set: { if !$0 { filePickerErrorMessage = nil } }
        )) {
            Alert(
                title: Text("导入失败"),
                message: Text(filePickerErrorMessage ?? ""),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(item: $modelFilePickerTarget) { target in
            switch target {
            case .asrModel:
                ModelFilePicker(allowedContentTypes: [.bz2, UTType(filenameExtension: "tar") ?? .data]) { url, cleanup in
                    Log.asr("[SettingsView] 用户选择了ASR模型文件: \(url.lastPathComponent)")
                    Task {
                        await viewModel.importModel(from: url)
                        cleanup()
                    }
                } onError: { msg in
                    Log.asr("[SettingsView] ASR文件选择失败: \(msg)")
                    filePickerErrorMessage = msg
                }
            case .punctModel:
                ModelFilePicker(allowedContentTypes: [.bz2, UTType(filenameExtension: "tar") ?? .data, UTType(filenameExtension: "onnx") ?? .data]) { url, cleanup in
                    Log.asr("[SettingsView] 用户选择了标点模型文件: \(url.lastPathComponent)")
                    Task {
                        await viewModel.importPunctuationModel(from: url)
                        cleanup()
                    }
                } onError: { msg in
                    Log.asr("[SettingsView] 标点文件选择失败: \(msg)")
                    filePickerErrorMessage = msg
                }
            }
        }
    }

    // MARK: - ASR 模型状态

    @ViewBuilder
    private var asrModelStatusSection: some View {
        switch modelDownloadManager.downloadState {
        case .idle:
            if viewModel.isModelDownloaded {
                asrModelReadyRow
            } else {
                asrModelNotDownloadedRow
            }

        case .downloading(let progress):
            asrDownloadingRow(progress)

        case .extracting(let progress):
            asrExtractingRow(progress)

        case .completed:
            asrModelReadyRow
            if !viewModel.isModelDownloaded {
                asrActionButtonsRow
            }

        case .failed(let error):
            asrDownloadFailedRow(error)
        }
    }

    private var asrModelReadyRow: some View {
        HStack {
            Label("SenseVoice 模型已就绪", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Spacer()
            Text("\(viewModel.offlineModelQuality.rawValue.uppercased())")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                Task { await viewModel.deleteModel() }
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    private var asrModelNotDownloadedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("SenseVoice 模型未下载")
                    .font(.body)
            }
            Divider()
            asrActionButtonsRow
        }
    }

    private var asrDownloadAddressRow: some View {
        let urlString = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(viewModel.offlineModelQuality.archiveFilename)"
        return VStack(alignment: .leading, spacing: 4) {
            Text("下载地址")
                .font(.subheadline)
                .foregroundColor(.primary)
            Button {
                UIPasteboard.general.string = urlString
            } label: {
                HStack(spacing: 4) {
                    Text(urlString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
            }
        }
    }

    private func asrDownloadingRow(_ progress: Double) -> some View {
        let isImport = modelDownloadManager.activeOperation == .import_
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text(isImport ? "导入中..." : "下载中...")
                Spacer()
                if !isImport {
                    Text("\(Int(progress * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Button(action: { viewModel.cancelDownload() }) {
                    Text("取消").foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            if !isImport {
                ProgressView(value: progress)
            }
        }
    }

    private func asrExtractingRow(_ progress: Double) -> some View {
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

    private func asrDownloadFailedRow(_ error: String) -> some View {
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
            asrDownloadAddressRow
            Divider()
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.startDownload() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .disabled(modelDownloadManager.isDownloading)
                Spacer()
                Button {
                    Log.asr("[SettingsView] ASR上传按钮点击(失败行)")
                    modelFilePickerTarget = .asrModel
                } label: {
                    Label("上传", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        }
    }

    private var asrActionButtonsRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.startDownload() }
            } label: {
                Label("下载", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .disabled(modelDownloadManager.isDownloading)
            Spacer()
            Button {
                Log.asr("[SettingsView] ASR上传按钮点击(操作行)")
                modelFilePickerTarget = .asrModel
            } label: {
                Label("上传", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .disabled(modelDownloadManager.isDownloading)
        }
    }

    // MARK: - 标点模型状态

    @ViewBuilder
    private var punctModelStatusSection: some View {
        switch punctuationModelManager.downloadState {
        case .idle:
            if viewModel.isPunctuationModelDownloaded {
                punctModelReadyRow
            } else {
                punctModelNotDownloadedRow
            }

        case .downloading(let progress):
            punctDownloadingRow(progress)

        case .extracting(let progress):
            punctExtractingRow(progress)

        case .completed:
            punctModelReadyRow
            if !viewModel.isPunctuationModelDownloaded {
                punctActionButtonsRow
            }

        case .failed(let error):
            punctDownloadFailedRow(error)
        }
    }

    private var punctModelReadyRow: some View {
        HStack {
            Label("标点模型已就绪", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Spacer()
            Button {
                Task { await viewModel.deletePunctuationModel() }
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    private var punctModelNotDownloadedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("标点恢复模型未下载")
                    .font(.body)
            }
            Text("用于给转写文本自动添加标点符号")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            punctActionButtonsRow
        }
    }

    private var punctDownloadAddressRow: some View {
        let urlString = "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar.bz2"
        return VStack(alignment: .leading, spacing: 4) {
            Text("下载地址")
                .font(.subheadline)
                .foregroundColor(.primary)
            Button {
                UIPasteboard.general.string = urlString
            } label: {
                HStack(spacing: 4) {
                    Text(urlString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
            }
        }
    }

    private func punctDownloadingRow(_ progress: Double) -> some View {
        let isImport = punctuationModelManager.activeOperation == .import_
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text(isImport ? "导入中..." : "下载中...")
                Spacer()
                if !isImport {
                    Text("\(Int(progress * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Button(action: { viewModel.cancelPunctuationDownload() }) {
                    Text("取消").foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            if !isImport {
                ProgressView(value: progress)
            }
        }
    }

    private func punctExtractingRow(_ progress: Double) -> some View {
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
            Text("正在解压并提取标点模型文件")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func punctDownloadFailedRow(_ error: String) -> some View {
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
            punctDownloadAddressRow
            Divider()
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.startPunctuationDownload() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .disabled(punctuationModelManager.isDownloading)
                Spacer()
                Button {
                    Log.asr("[SettingsView] 标点上传按钮点击(失败行)")
                    modelFilePickerTarget = .punctModel
                } label: {
                    Label("上传", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        }
    }

    private var punctActionButtonsRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.startPunctuationDownload() }
            } label: {
                Label("下载", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .disabled(punctuationModelManager.isDownloading)
            Spacer()
            Button {
                Log.asr("[SettingsView] 标点上传按钮点击(操作行)")
                modelFilePickerTarget = .punctModel
            } label: {
                Label("上传", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .disabled(punctuationModelManager.isDownloading)
        }
    }
}

// MARK: - 模型文件选择器（UIDocumentPicker 包装，避免 SwiftUI fileImporter 在 Form 中的兼容问题）

private struct ModelFilePicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let onPick: (URL, @escaping () -> Void) -> Void
    let onError: ((String) -> Void)?

    init(allowedContentTypes: [UTType], onPick: @escaping (URL, @escaping () -> Void) -> Void, onError: ((String) -> Void)? = nil) {
        self.allowedContentTypes = allowedContentTypes
        self.onPick = onPick
        self.onError = onError
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiView: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onError: onError)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL, @escaping () -> Void) -> Void
        let onError: ((String) -> Void)?
        init(onPick: @escaping (URL, @escaping () -> Void) -> Void, onError: ((String) -> Void)?) {
            self.onPick = onPick
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onError?("无法读取所选文件。\n\n文件可能存储在远程服务器上但未下载到本地。\n\n请先在文件 App 中将文件下载到本地存储（'我的 iPhone'），再重新导入。")
                return
            }
            // 在 picker 上下文中启动安全范围；对于远程文件（SMB 等），可能无法获取权限
            let secured = url.startAccessingSecurityScopedResource()
            if !secured {
                onError?("无法访问所选文件。\n\n远程服务器上的文件需要先下载到本地。\n\n请在文件 App 中将该文件复制到'我的 iPhone'，再重新导入。")
                return
            }
            onPick(url) {
                url.stopAccessingSecurityScopedResource()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
