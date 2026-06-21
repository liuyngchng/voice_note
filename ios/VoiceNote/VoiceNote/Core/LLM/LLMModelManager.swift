import Foundation
import os

/// 离线 LLM 模型下载管理器
/// 支持 ModelScope（优先）、GitHub Releases（兜底）、文件导入
/// 对齐 ModelDownloadManager 模式（简化版：GGUF 是单文件，无需 bzip2/tar 处理）
@MainActor
final class LLMModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var downloadState: DownloadState = .idle
    @Published var activeSource: DownloadSource = .modelscope

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case completed(Date)
        case failed(String)
    }

    enum DownloadSource: String {
        case modelscope = "ModelScope"
        case github = "GitHub"
        case import_ = "导入"
    }

    // MARK: - 下载任务

    @Published var isDownloading = false
    private var currentTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?

    deinit {
        downloadSession?.invalidateAndCancel()
    }

    // MARK: - 路径

    static nonisolated var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/llm", isDirectory: true)
    }

    static nonisolated func modelFilePath(_ info: LLMModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(info.modelFilename)
    }

    // MARK: - 检查模型状态

    static nonisolated func isModelDownloaded(_ info: LLMModelInfo) -> Bool {
        let path = modelFilePath(info).path
        return FileManager.default.fileExists(atPath: path)
    }

    /// 获取已下载模型的文件大小（bytes）
    static nonisolated func downloadedModelSize(_ info: LLMModelInfo) -> UInt64 {
        let path = modelFilePath(info).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64
        else { return 0 }
        return size
    }

    static nonisolated func savedModelInfo() -> LLMModelInfo {
        let raw = UserDefaults.standard.string(forKey: "llm_model_info") ?? ""
        return LLMModelInfo(rawValue: raw) ?? .qwen3_0_6b_q4km
    }

    // MARK: - 磁盘空间检查

    static nonisolated func hasSufficientDiskSpace(for info: LLMModelInfo) -> Bool {
        let estimated = Int64(info.estimatedSizeMB) * 1024 * 1024
        let margin = Int64(Double(estimated) * 0.1)
        let totalRequired = estimated + margin

        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let values = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            guard let available = values.volumeAvailableCapacity, available > 0 else {
                return true // 无法读取则假设足够
            }
            return Int64(available) > totalRequired
        } catch {
            return true
        }
    }

    // MARK: - 从 ModelScope 下载

    func downloadFromModelScope(_ info: LLMModelInfo) async throws {
        guard let urlString = info.modelscopeDownloadURL,
              let url = URL(string: urlString)
        else {
            downloadState = .failed("该模型暂不支持 ModelScope 下载")
            throw LLMDownloadError.noURL
        }
        try await download(from: url, source: .modelscope, info: info)
    }

    // MARK: - 从 GitHub 下载

    func downloadFromGitHub(_ info: LLMModelInfo) async throws {
        guard let urlString = info.githubDownloadURL,
              let url = URL(string: urlString)
        else {
            downloadState = .failed("该模型暂未配置 GitHub 镜像，请使用 ModelScope 下载或手动上传")
            throw LLMDownloadError.noURL
        }
        try await download(from: url, source: .github, info: info)
    }

    // MARK: - 导入本地文件

    func importFromFile(_ sourceURL: URL, info: LLMModelInfo) async throws {
        guard !isDownloading else {
            Log.llm("操作已在进行中，忽略重复请求")
            return
        }
        isDownloading = true
        activeSource = .import_

        guard Self.hasSufficientDiskSpace(for: info) else {
            let msg = "磁盘空间不足，需要至少 \(info.estimatedSizeMB) MB"
            downloadState = .failed(msg)
            isDownloading = false
            throw LLMDownloadError.insufficientDiskSpace
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        let targetURL = Self.modelFilePath(info)
        try? fm.removeItem(at: targetURL)

        do {
            try fm.copyItem(at: sourceURL, to: targetURL)
        } catch {
            let msg = "文件导入失败: \(error.localizedDescription)"
            downloadState = .failed(msg)
            isDownloading = false
            throw LLMDownloadError.fileImportFailed(error.localizedDescription)
        }

        // 验证文件大小合理 (>10MB)
        let fileSize = Self.downloadedModelSize(info)
        guard fileSize > 10_000_000 else {
            try? fm.removeItem(at: targetURL)
            let msg = "导入的文件过小 (\(fileSize / 1_048_576)MB)，可能不是有效的 GGUF 模型"
            downloadState = .failed(msg)
            isDownloading = false
            throw LLMDownloadError.invalidFile(msg)
        }

        isDownloading = false
        downloadState = .completed(Date())
        Log.llm("模型导入完成: \(info.rawValue) (\(fileSize / 1_048_576)MB)")
    }

    // MARK: - 通用下载

    private func download(from url: URL, source: DownloadSource, info: LLMModelInfo) async throws {
        guard !isDownloading else {
            Log.llm("操作已在进行中，忽略重复请求")
            return
        }
        isDownloading = true
        activeSource = source

        guard Self.hasSufficientDiskSpace(for: info) else {
            let msg = "磁盘空间不足，需要至少 \(info.estimatedSizeMB) MB"
            downloadState = .failed(msg)
            isDownloading = false
            throw LLMDownloadError.insufficientDiskSpace
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        let targetURL = Self.modelFilePath(info)

        downloadState = .downloading(progress: 0)
        Log.llm("开始从 \(source.rawValue) 下载: \(url.absoluteString.prefix(80))...")

        do {
            try await performDownload(from: url, to: targetURL)
        } catch {
            isDownloading = false
            if error is CancellationError {
                Log.llm("下载已取消")
                downloadState = .idle
                throw error
            }
            let msg = "下载失败: \(error.localizedDescription)"
            downloadState = .failed(msg)
            throw error
        }

        // 验证
        guard Self.isModelDownloaded(info) else {
            let msg = "下载完成但文件验证失败"
            downloadState = .failed(msg)
            isDownloading = false
            throw LLMDownloadError.verificationFailed
        }

        let fileSize = Self.downloadedModelSize(info)
        isDownloading = false
        downloadState = .completed(Date())
        Log.llm("模型下载完成: \(info.rawValue) (\(fileSize / 1_048_576)MB), 来源=\(source.rawValue)")
    }

    private func performDownload(from url: URL, to targetURL: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressDelegate { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress
                    self?.downloadState = .downloading(progress: progress)
                }
            }

            let session = URLSession(configuration: .default,
                                      delegate: delegate,
                                      delegateQueue: nil)
            self.downloadSession = session

            delegate.onCompletion = { [weak self] result in
                Task { @MainActor [weak self] in
                    switch result {
                    case .success(let tempURL):
                        do {
                            try? FileManager.default.removeItem(at: targetURL)
                            try FileManager.default.copyItem(at: tempURL, to: targetURL)
                            Log.llm("归档文件已保存到: \(targetURL.lastPathComponent)")
                            continuation.resume()
                        } catch {
                            Log.llm("复制下载文件失败: \(error.localizedDescription)")
                            continuation.resume(throwing: error)
                        }
                        try? FileManager.default.removeItem(at: tempURL)
                        self?.downloadSession?.finishTasksAndInvalidate()
                        self?.downloadSession = nil
                    case .failure(let error):
                        self?.downloadSession?.invalidateAndCancel()
                        self?.downloadSession = nil
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            Log.llm("下载网络错误: \(error.localizedDescription)")
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            let task = session.downloadTask(with: url)
            self.currentTask = task
            task.resume()
            Log.llm("下载任务已启动")
        }
    }

    // MARK: - 取消

    func cancelDownload() {
        Log.llm("用户取消下载")
        currentTask?.cancel()
        currentTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        isDownloading = false
        downloadState = .idle
    }

    // MARK: - 删除

    func deleteModel(_ info: LLMModelInfo) {
        let path = Self.modelFilePath(info)
        try? FileManager.default.removeItem(at: path)
        Log.llm("模型已删除: \(info.rawValue)")

        // 如果目录空了也清理
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: Self.modelsDirectory.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: Self.modelsDirectory)
        }

        downloadState = .idle
        downloadProgress = 0
    }
}

// MARK: - 错误

enum LLMDownloadError: LocalizedError {
    case noURL
    case insufficientDiskSpace
    case verificationFailed
    case fileImportFailed(String)
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .noURL: return "未配置下载地址"
        case .insufficientDiskSpace: return "磁盘空间不足"
        case .verificationFailed: return "下载完成但文件验证失败，请重试"
        case .fileImportFailed(let msg): return "文件导入失败: \(msg)"
        case .invalidFile(let msg): return msg
        }
    }
}

// MARK: - URLSessionDownloadDelegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    var onCompletion: ((Result<URL, Error>) -> Void)?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress(progress)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory.appendingPathComponent("llm-download-cache")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cachedURL = cacheDir.appendingPathComponent(location.lastPathComponent)
        try? fm.removeItem(at: cachedURL)
        do {
            try fm.copyItem(at: location, to: cachedURL)
            onCompletion?(.success(cachedURL))
        } catch {
            onCompletion?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            onCompletion?(.failure(error))
        }
    }
}
