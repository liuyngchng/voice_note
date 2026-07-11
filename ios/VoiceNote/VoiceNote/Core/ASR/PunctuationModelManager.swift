import Foundation
import os

/// 标点符号模型下载管理器
/// 从 GitHub Releases 下载 sherpa-onnx 标点模型 tar.bz2 归档，解压提取 ONNX 文件
/// 对齐 Android: ASRModelManager.kt (punctuation model 部分)
@MainActor
final class PunctuationModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var downloadState: DownloadState = .idle
    @Published var activeOperation: ActiveOperation = .download

    enum ActiveOperation: String { case download, import_ }

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case extracting(progress: Double)
        case completed(Date)
        case failed(String)
    }

    private var currentTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    @Published var isDownloading = false

    deinit {
        downloadSession?.invalidateAndCancel()
    }

    // MARK: - 路径（对齐 Android）

    /// GitHub Releases 地址（punctuation-models tag）
    private static let baseURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models"
    /// 归档文件名
    private static let archiveFilename = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar.bz2"
    /// 解压后的 ONNX 模型文件名
    private static let punctONNXFilename = "punct_ct_transformer.onnx"

    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/punctuation", isDirectory: true)
    }

    nonisolated static func modelFilePath() -> URL {
        modelsDirectory.appendingPathComponent(punctONNXFilename)
    }

    // MARK: - 检查模型状态

    nonisolated static func isModelDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: modelFilePath().path)
    }

    // MARK: - 下载（下载 tar.bz2 → 解压 → 提取 ONNX）

    func downloadModel() async throws {
        guard !isDownloading else {
            Log.asr("标点模型操作已在进行中，忽略重复请求")
            return
        }
        isDownloading = true
        activeOperation = .download

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        let tempDir = fm.temporaryDirectory.appendingPathComponent("punct-download")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let archiveURL = tempDir.appendingPathComponent(Self.archiveFilename)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        // 下载 tar.bz2
        guard let url = URL(string: "\(Self.baseURL)/\(Self.archiveFilename)") else {
            downloadState = .failed("无效的下载地址")
            isDownloading = false
            throw DownloadError.invalidURL
        }

        Log.asr("开始下载标点模型: \(url.absoluteString)")
        downloadState = .downloading(progress: 0)

        do {
            try await downloadArchive(from: url, to: archiveURL)
        } catch {
            isDownloading = false
            if error is CancellationError {
                downloadState = .idle
                throw error
            }
            let msg = "下载失败: \(error.localizedDescription)"
            downloadState = .failed(msg)
            throw error
        }

        // 解压 tar.bz2 → 提取 ONNX
        Log.asr("标点模型下载完成，开始解压...")
        downloadState = .extracting(progress: 0.5)
        do {
            try await extractPunctModel(from: archiveURL, isTar: false)
        } catch {
            isDownloading = false
            let msg = "解压失败: \(error.localizedDescription)"
            downloadState = .failed(msg)
            throw DownloadError.extractionFailed(error.localizedDescription)
        }

        guard Self.isModelDownloaded() else {
            let msg = "完成但验证失败，文件缺失"
            downloadState = .failed(msg)
            isDownloading = false
            throw DownloadError.verificationFailed
        }

        isDownloading = false
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: Self.modelFilePath().path)[.size] as? UInt64) ?? 0
        downloadState = .completed(Date())
        Log.asr("标点模型安装完成: \(fileSize) bytes")
    }

    private func downloadArchive(from url: URL, to targetURL: URL) async throws {
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
                            continuation.resume()
                        } catch {
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
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            let task = session.downloadTask(with: url)
            self.currentTask = task
            task.resume()
        }
    }

    /// 从 tar.bz2 或 tar 归档中提取 ONNX 模型
    private func extractPunctModel(from archiveURL: URL, isTar: Bool) async throws {
        let fm = FileManager.default

        let tarURL: URL
        if isTar {
            // 已经是 tar 文件，无需 bzip2 解压
            tarURL = archiveURL
        } else {
            // bzip2 解压 → tar
            let decompressedURL = archiveURL.deletingPathExtension().appendingPathExtension("tar")
            let result = bzip2_decompress_file(archiveURL.path, decompressedURL.path)
            guard result == 0 else {
                throw DownloadError.extractionFailed("bzip2 解压错误，错误码: \(result)")
            }
            tarURL = decompressedURL
        }

        // 从 tar 中提取 .onnx 文件
        let fileHandle = try FileHandle(forReadingFrom: tarURL)
        defer { try? fileHandle.close() }

        var found = false

        while true {
            guard let headerData = try? fileHandle.read(upToCount: 512),
                  headerData.count == 512 else { break }

            if headerData.allSatisfy({ $0 == 0 }) {
                if let nextBlock = try? fileHandle.read(upToCount: 512),
                   nextBlock.allSatisfy({ $0 == 0 }) { break }
                try? fileHandle.seek(toOffset: fileHandle.offsetInFile - 512)
                break
            }

            let nameData = headerData[0..<100]
            guard let name = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { continue }

            let sizeData = headerData[124..<136]
            guard let sizeStr = String(data: sizeData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")),
                  let fileSize = UInt64(sizeStr, radix: 8) else { continue }

            let paddedSize = ((fileSize + 511) / 512) * 512
            let shortName = name.contains("/") ? String(name[name.range(of: "/")!.upperBound...]) : name

            if shortName.hasSuffix(".onnx") {
                let fileData: Data
                if fileSize > 0 {
                    guard let data = try? fileHandle.read(upToCount: Int(fileSize)) else {
                        throw DownloadError.extractionFailed("读取 tar 条目失败: \(shortName)")
                    }
                    fileData = data
                } else {
                    fileData = Data()
                }

                let targetURL = Self.modelFilePath()
                try? fm.removeItem(at: targetURL)
                try fileData.write(to: targetURL)
                Log.asr("标点模型提取完成: \(shortName) (\(fileData.count) bytes)")
                found = true
                break
            } else {
                if paddedSize > 0 {
                    try? fileHandle.seek(toOffset: fileHandle.offsetInFile + paddedSize)
                }
            }
        }

        // 清理 tar（仅当是 bzip2 解压产生的临时文件时才删除，不删用户原始文件）
        if !isTar {
            try? fm.removeItem(at: tarURL)
        }

        guard found else {
            throw DownloadError.extractionFailed("归档中未找到 .onnx 文件")
        }
    }

    // MARK: - 导入

    /// 安全范围访问由调用方（ModelFilePicker）管理，调用方会在 import 完成后释放
    func importModel(from sourceURL: URL) async throws {
        guard !isDownloading else { return }
        isDownloading = true
        activeOperation = .import_

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        let fileName = sourceURL.lastPathComponent.lowercased()

        // 支持直接导入 ONNX 文件，也支持导入 tar.bz2 / tar 归档
        // 所有文件 I/O 在后台线程执行，避免阻塞 UI
        if fileName.hasSuffix(".onnx") {
            let targetURL = Self.modelFilePath()
            downloadState = .downloading(progress: 0)
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: targetURL)
                    let data = try Data(contentsOf: sourceURL, options: [])
                    try data.write(to: targetURL)
                }.value
            } catch {
                isDownloading = false
                downloadState = .failed("文件导入失败: \(error.localizedDescription)")
                throw DownloadError.fileImportFailed(error.localizedDescription)
            }
        } else if fileName.hasSuffix(".tar.bz2") || fileName.hasSuffix(".bz2") {
            // 导入 bzip2 压缩归档：先复制到本地临时目录，再解压提取
            let tempDir = fm.temporaryDirectory.appendingPathComponent("punct-import")
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let archiveURL = tempDir.appendingPathComponent("uploaded.tar.bz2")
            defer { try? fm.removeItem(at: tempDir) }

            downloadState = .downloading(progress: 0)
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: archiveURL)
                    let data = try Data(contentsOf: sourceURL, options: [])
                    try data.write(to: archiveURL)
                }.value
            } catch {
                isDownloading = false
                downloadState = .failed("文件读取失败: \(error.localizedDescription)")
                throw DownloadError.fileImportFailed(error.localizedDescription)
            }

            downloadState = .extracting(progress: 0.5)
            do {
                try await extractPunctModel(from: archiveURL, isTar: false)
            } catch {
                isDownloading = false
                downloadState = .failed(error.localizedDescription)
                throw error
            }
        } else if fileName.hasSuffix(".tar") {
            // 导入未压缩 tar 归档：先复制到本地临时目录，再提取
            let tempDir = fm.temporaryDirectory.appendingPathComponent("punct-import")
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let archiveURL = tempDir.appendingPathComponent("uploaded.tar")
            defer { try? fm.removeItem(at: tempDir) }

            downloadState = .downloading(progress: 0)
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: archiveURL)
                    let data = try Data(contentsOf: sourceURL, options: [])
                    try data.write(to: archiveURL)
                }.value
            } catch {
                isDownloading = false
                downloadState = .failed("文件读取失败: \(error.localizedDescription)")
                throw DownloadError.fileImportFailed(error.localizedDescription)
            }

            downloadState = .extracting(progress: 0.5)
            do {
                try await extractPunctModel(from: archiveURL, isTar: true)
            } catch {
                isDownloading = false
                downloadState = .failed(error.localizedDescription)
                throw error
            }
        } else {
            // 尝试直接复制（当作 ONNX 文件）
            let targetURL = Self.modelFilePath()
            downloadState = .downloading(progress: 0)
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: targetURL)
                    let data = try Data(contentsOf: sourceURL, options: [])
                    try data.write(to: targetURL)
                }.value
            } catch {
                isDownloading = false
                downloadState = .failed("文件导入失败: \(error.localizedDescription)")
                throw DownloadError.fileImportFailed(error.localizedDescription)
            }
        }

        isDownloading = false
        downloadState = .completed(Date())
        Log.asr("标点模型导入完成")
    }

    // MARK: - 取消

    func cancelDownload() {
        currentTask?.cancel()
        currentTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        isDownloading = false
        downloadState = .idle
    }

    // MARK: - 删除

    func deleteModel() {
        try? FileManager.default.removeItem(at: Self.modelFilePath())
        // 清理空目录
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: Self.modelsDirectory.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: Self.modelsDirectory)
        }
        downloadState = .idle
        downloadProgress = 0
        Log.asr("标点模型已删除")
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
        let cacheDir = fm.temporaryDirectory.appendingPathComponent("punct-download-cache")
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
