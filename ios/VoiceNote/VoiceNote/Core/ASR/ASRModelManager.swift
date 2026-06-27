import Foundation
import os

/// 离线 ASR 模型管理器
/// 从 GitHub Releases 下载 / 本地导入 SenseVoice ONNX 模型（tar.bz2 / tar 归档），解压提取所需文件
/// 对齐 Android: ASRModelManager.kt
@MainActor
final class ASRModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var downloadState: DownloadState = .idle
    /// 当前操作类型：下载 or 导入（UI 据此显示不同文案）
    enum ActiveOperation: String { case download, import_ }
    @Published var activeOperation: ActiveOperation = .download

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case extracting(progress: Double)
        case completed(Date)
        case failed(String)
    }

    // MARK: - 下载任务持有

    private var currentTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    @Published var isDownloading = false  // 防重复点击（UI 绑定）

    deinit {
        downloadSession?.invalidateAndCancel()
    }

    // MARK: - 路径

    /// GitHub Releases 地址（asr-models tag）
    private static let baseURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

    /// 模型本地存储根目录
    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/sherpa-onnx-sense-voice", isDirectory: true)
    }

    /// tokens.txt 本地路径（所有模型共享）
    nonisolated static func tokensFilePath() -> URL {
        modelsDirectory.appendingPathComponent("tokens.txt")
    }

    /// 模型文件本地路径
    nonisolated static func modelFilePath(_ quality: ModelQuality) -> URL {
        modelsDirectory.appendingPathComponent(quality.modelFilename)
    }

    // MARK: - 检查模型状态

    /// 检查指定质量的模型是否已下载（模型文件 + tokens.txt 都存在）
    nonisolated static func isModelDownloaded(_ quality: ModelQuality) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelFilePath(quality).path)
            && fm.fileExists(atPath: tokensFilePath().path)
    }

    /// 获取当前已下载的最高质量模型（用于 RecordingManager fallback）
    nonisolated static func bestDownloadedQuality() -> ModelQuality? {
        if isModelDownloaded(.fp32) { return .fp32 }
        if isModelDownloaded(.int8) { return .int8 }
        return nil
    }

    /// 从 UserDefaults 读取用户偏好的模型质量
    nonisolated static func savedQuality() -> ModelQuality {
        let raw = UserDefaults.standard.string(forKey: "offline_model_quality") ?? "int8"
        return ModelQuality(rawValue: raw) ?? .int8
    }

    /// 获取已下载模型的文件大小
    nonisolated static func downloadedModelSize(_ quality: ModelQuality) -> UInt64 {
        let path = modelFilePath(quality).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64
        else { return 0 }
        return size
    }

    // MARK: - 磁盘空间检查

    /// 检查是否有足够磁盘空间（模型压缩包 + 解压后 + 10% 余量）
    nonisolated static func hasSufficientDiskSpace(for quality: ModelQuality) -> Bool {
        let estimated = Int64(quality.estimatedSizeMB) * 1024 * 1024
        let margin = Int64(Double(estimated) * 0.1)
        let totalRequired = estimated + margin

        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let values = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            guard let available = values.volumeAvailableCapacity, available > 0 else {
                return true
            }
            return Int64(available) > totalRequired
        } catch {
            return true
        }
    }

    // MARK: - 下载（下载 tar.bz2 → 解压 → 提取文件）

    /// 下载模型（tar.bz2 归档），解压并提取模型文件和 tokens.txt
    func downloadModel(quality: ModelQuality) async throws {
        guard !isDownloading else {
            Log.asr("操作已在進行中，忽略重复请求")
            return
        }
        isDownloading = true
        activeOperation = .download

        guard Self.hasSufficientDiskSpace(for: quality) else {
            let msg = "磁盘空间不足，需要至少 \(quality.estimatedSizeMB) MB"
            Log.asr("下载失败: \(msg)")
            downloadState = .failed(msg)
            isDownloading = false
            throw DownloadError.insufficientDiskSpace
        }
        Log.asr("磁盘空间检查通过，需要 ~\(quality.estimatedSizeMB)MB")

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        let archiveFilename = quality.archiveFilename
        let tempDir = fm.temporaryDirectory.appendingPathComponent("model-download")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let archiveURL = tempDir.appendingPathComponent(archiveFilename)

        defer {
            try? fm.removeItem(at: tempDir)
            Log.asrDebug("临时文件已清理")
        }

        // 下载 tar.bz2
        Log.asr("开始下载模型: \(quality.rawValue) 来自 \(Self.baseURL)/\(archiveFilename)")
        downloadState = .downloading(progress: 0)
        do {
            try await downloadArchive(filename: archiveFilename, to: archiveURL, quality: quality)
        } catch {
            isDownloading = false
            if error is CancellationError {
                Log.asr("下载已取消")
                downloadState = .idle
                throw error
            }
            let msg = "下载失败: \(error.localizedDescription)"
            Log.asr(msg)
            downloadState = .failed(msg)
            throw error
        }
        Log.asr("归档下载完成: \(archiveFilename)")

        // 共用：解压 → 提取 → 验证
        try await processArchive(at: archiveURL, quality: quality)
    }

    /// 从本地文件导入模型（用户提前下载好的 .tar.bz2 或 .tar）
    /// 安全范围访问由调用方（ModelFilePicker）管理，调用方会在 import 完成后释放
    func importModel(from sourceURL: URL, quality: ModelQuality) async throws {
        guard !isDownloading else {
            Log.asr("操作已在進行中，忽略重复请求")
            return
        }
        isDownloading = true
        activeOperation = .import_

        guard Self.hasSufficientDiskSpace(for: quality) else {
            let msg = "磁盘空间不足，需要至少 \(quality.estimatedSizeMB) MB"
            Log.asr("导入失败: \(msg)")
            downloadState = .failed(msg)
            isDownloading = false
            throw DownloadError.insufficientDiskSpace
        }
        Log.asr("磁盘空间检查通过，需要 ~\(quality.estimatedSizeMB)MB")

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        let tempDir = fm.temporaryDirectory.appendingPathComponent("model-import")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 根据源文件扩展名决定临时文件名
        let srcExt = sourceURL.pathExtension.lowercased()
        let isTar = (srcExt == "tar")
        let archiveFilename = isTar ? "uploaded.tar" : "uploaded.tar.bz2"
        let archiveURL = tempDir.appendingPathComponent(archiveFilename)

        defer {
            try? fm.removeItem(at: tempDir)
            Log.asrDebug("临时文件已清理")
        }

        // 读取用户选择的文件到临时目录
        // 在后台线程执行文件 I/O（大文件可能耗时数十秒），避免阻塞 UI
        // 分两级尝试：先用 Data(contentsOf:)（通过文件协调器触发下载），
        // 失败则用 FileHandle 流式读取作为兜底
        Log.asr("开始导入文件: \(sourceURL.lastPathComponent) (类型: \(isTar ? "tar" : "bz2"))")
        downloadState = .downloading(progress: 0)
        do {
            // 在后台线程执行所有阻塞 I/O，让主线程可以刷新进度 UI
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.removeItem(at: archiveURL)
                let data: Data
                do {
                    data = try Data(contentsOf: sourceURL, options: [])
                } catch {
                    Log.asr("Data(contentsOf:) 失败，尝试 FileHandle: \(error.localizedDescription)")
                    let handle = try FileHandle(forReadingFrom: sourceURL)
                    defer { try? handle.close() }
                    data = handle.readDataToEndOfFile()
                }
                try data.write(to: archiveURL)
            }.value
        } catch {
            isDownloading = false
            let msg = "文件读取失败: \(error.localizedDescription)"
            Log.asr(msg)
            downloadState = .failed(msg)
            throw DownloadError.fileImportFailed(error.localizedDescription)
        }

        let fileSize = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        Log.asr("导入文件就绪: \(sourceURL.lastPathComponent) (\(fileSize / 1_048_576)MB)")

        // 共用：解压 → 提取 → 验证
        try await processArchive(at: archiveURL, quality: quality, isTar: isTar)
    }

    // MARK: - 共用处理流程（解压 → 提取 → 验证）

    private func processArchive(at archiveURL: URL, quality: ModelQuality, isTar: Bool = false) async throws {
        let fm = FileManager.default

        let tarURL: URL
        if isTar {
            // 已经是 tar 文件，无需 bzip2 解压
            Log.asr("文件已是 tar 格式，跳过 bzip2 解压")
            tarURL = archiveURL
        } else {
            // bzip2 解压 → tar
            let decompressedURL = archiveURL.deletingPathExtension().appendingPathExtension("tar")
            Log.asr("开始解压 bzip2...")
            downloadState = .extracting(progress: 0)
            do {
                try await decompressBzip2(input: archiveURL, output: decompressedURL)
            } catch {
                isDownloading = false
                let msg = "解压失败: \(error.localizedDescription)"
                Log.asr(msg)
                downloadState = .failed(msg)
                throw DownloadError.extractionFailed(error.localizedDescription)
            }
            Log.asr("bzip2 解压完成")
            tarURL = decompressedURL
        }

        // 从 tar 中提取 model 文件 + tokens.txt
        Log.asr("开始从 tar 提取模型文件...")
        downloadState = .extracting(progress: 0.5)
        do {
            try await extractFilesFromTar(tarURL: tarURL, quality: quality)
        } catch {
            isDownloading = false
            let msg = "提取文件失败: \(error.localizedDescription)"
            Log.asr(msg)
            downloadState = .failed(msg)
            throw DownloadError.extractionFailed(error.localizedDescription)
        }

        // 验证
        guard Self.isModelDownloaded(quality) else {
            let msg = "完成但验证失败，文件缺失"
            Log.asr(msg)
            downloadState = .failed(msg)
            isDownloading = false
            throw DownloadError.verificationFailed
        }

        // 清理 tar（已不需要）
        try? fm.removeItem(at: tarURL)

        isDownloading = false
        downloadState = .completed(Date())
        let modelSize = Self.downloadedModelSize(quality)
        Log.asr("模型安装完成: \(quality.rawValue) (模型 \(modelSize / 1_048_576)MB)")
    }

    // MARK: - 下载归档文件（带进度）

    private func downloadArchive(filename: String, to targetURL: URL, quality: ModelQuality) async throws {
        guard let url = URL(string: "\(Self.baseURL)/\(filename)") else {
            throw DownloadError.invalidURL
        }
        Log.asrDebug("下载 URL: \(url.absoluteString)")

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
                            Log.asrDebug("归档文件已保存到: \(targetURL.path)")
                            continuation.resume()
                        } catch {
                            Log.asr("复制下载文件失败: \(error.localizedDescription)")
                            continuation.resume(throwing: error)
                        }
                        // 文件复制完成后再清理 session 和临时文件
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
                            Log.asr("下载网络错误: \(error.localizedDescription)")
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            let task = session.downloadTask(with: url)
            self.currentTask = task
            task.resume()
            Log.asrDebug("下载任务已启动")
        }
    }

    // MARK: - bzip2 解压

    private func decompressBzip2(input: URL, output: URL) async throws {
        Log.asrDebug("bzip2 解压: \(input.path) -> \(output.path)")
        let result = bzip2_decompress_file(input.path, output.path)
        guard result == 0 else {
            let msg = "bzip2 解压错误，错误码: \(result)"
            Log.asr(msg)
            throw DownloadError.extractionFailed(msg)
        }
        Log.asrDebug("bzip2 解压完成")
    }

    // MARK: - tar 提取

    private func extractFilesFromTar(tarURL: URL, quality: ModelQuality) async throws {
        let targetModelFile = quality.modelFilename
        var foundModel = false
        var foundTokens = false

        let fileHandle = try FileHandle(forReadingFrom: tarURL)
        defer { try? fileHandle.close() }

        let modelTargetURL = Self.modelFilePath(quality)
        let tokensTargetURL = Self.tokensFilePath()

        // 删除旧的 tokens.txt（如果存在且是其他版本的）
        // 保留不删，因为新下载会覆盖

        Log.asrDebug("开始解析 tar，目标文件: \(targetModelFile), tokens.txt")

        while true {
            // 读取 512 字节的 tar header
            guard let headerData = try? fileHandle.read(upToCount: 512),
                  headerData.count == 512 else {
                Log.asrDebug("无法读取 tar header，停止解析")
                break
            }

            // 检查是否到了 tar 结束标记（全零块）
            if headerData.allSatisfy({ $0 == 0 }) {
                // 读取下一个 block 确认
                if let nextBlock = try? fileHandle.read(upToCount: 512),
                   nextBlock.allSatisfy({ $0 == 0 }) {
                    Log.asrDebug("遇到 tar 结束标记")
                    break
                }
                // 如果不是全零，回退（不应该发生，但防御性处理）
                try? fileHandle.seek(toOffset: fileHandle.offsetInFile - 512)
                break
            }

            // 解析文件名（offset 0, 长度 100）
            let nameData = headerData[0..<100]
            guard let name = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
                continue
            }

            // 去掉归档根目录前缀
            let shortName: String
            if let slashRange = name.range(of: "/") {
                shortName = String(name[slashRange.upperBound...])
            } else {
                shortName = name
            }

            // 解析文件大小（offset 124, 长度 12, 八进制字符串）
            let sizeData = headerData[124..<136]
            guard let sizeStr = String(data: sizeData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")),
                  let fileSize = UInt64(sizeStr, radix: 8) else {
                continue
            }

            let isTargetModel = (shortName == targetModelFile)
            let isTargetTokens = (shortName == "tokens.txt")
            let isNeeded = isTargetModel || isTargetTokens

            if isNeeded {
                Log.asrDebug("找到目标文件: \(shortName) (\(fileSize / 1_048_576)MB)")
            }

            // 计算需要读取的数据块数（512 字节对齐）
            let paddedSize = ((fileSize + 511) / 512) * 512

            if isNeeded {
                // 读取文件数据
                let fileData: Data
                if fileSize > 0 {
                    guard let data = try? fileHandle.read(upToCount: Int(fileSize)) else {
                        throw DownloadError.extractionFailed("读取 tar 条目失败: \(shortName)")
                    }
                    fileData = data
                } else {
                    fileData = Data()
                }

                let targetURL = isTargetModel ? modelTargetURL : tokensTargetURL
                try? FileManager.default.removeItem(at: targetURL)
                try fileData.write(to: targetURL)

                if isTargetModel { foundModel = true }
                if isTargetTokens { foundTokens = true }
                Log.asr("提取完成: \(shortName) -> \(targetURL.lastPathComponent)")

                // 跳过 padding（数据已读取 fileSize 字节，还需跳过 padding - fileSize）
                let padding = Int(paddedSize - fileSize)
                if padding > 0 {
                    _ = try? fileHandle.read(upToCount: padding)
                }
            } else {
                // 不需要此文件，跳过
                if paddedSize > 0 {
                    try? fileHandle.seek(toOffset: fileHandle.offsetInFile + paddedSize)
                }
            }

            if foundModel && foundTokens {
                Log.asrDebug("两个目标文件均已找到，停止解析")
                break
            }
        }

        guard foundModel else {
            throw DownloadError.extractionFailed("归档中未找到 \(targetModelFile)")
        }
        guard foundTokens else {
            throw DownloadError.extractionFailed("归档中未找到 tokens.txt")
        }

        Log.asr("tar 提取完成: model=\(foundModel), tokens=\(foundTokens)")
    }

    /// 取消当前下载
    func cancelDownload() {
        Log.asr("用户取消下载")
        currentTask?.cancel()
        currentTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        isDownloading = false
        downloadState = .idle
    }

    // MARK: - 删除

    /// 删除指定质量的模型文件
    func deleteModel(quality: ModelQuality) {
        let modelPath = Self.modelFilePath(quality)
        try? FileManager.default.removeItem(at: modelPath)
        Log.asr("模型已删除: \(quality.rawValue)")
        downloadState = .idle
        downloadProgress = 0

        // 如果另一种质量的模型也不存在，连 tokens.txt 一起清掉
        let otherQuality: ModelQuality = (quality == .int8) ? .fp32 : .int8
        if !Self.isModelDownloaded(otherQuality) {
            try? FileManager.default.removeItem(at: Self.tokensFilePath())
            try? FileManager.default.removeItem(at: Self.modelsDirectory)
            Log.asr("所有模型已清空")
        }
    }
}

// MARK: - 错误

enum DownloadError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case insufficientDiskSpace
    case extractionFailed(String)
    case verificationFailed
    case fileImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的下载地址"
        case .httpError(let code): return "服务器错误 (HTTP \(code))"
        case .insufficientDiskSpace: return "磁盘空间不足"
        case .extractionFailed(let msg): return "解压错误: \(msg)"
        case .verificationFailed: return "下载完成但文件验证失败，请重试"
        case .fileImportFailed(let msg): return "文件导入失败: \(msg)"
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
        // 临时文件在回调返回后立即被系统删除，必须马上复制到我们的缓存目录
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory.appendingPathComponent("download-cache")
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
