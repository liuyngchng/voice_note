import AVFoundation
import Foundation
import os

/// 音频采集 — 16kHz / 16bit / PCM / Mono
/// 对齐 Android: AudioCapture.kt (AudioRecord 16kHz/16bit/PCM)
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var isRunning = false

    /// 目标采样率
    let sampleRate: Double = 16000

    /// 每帧采样数 ≈ 200ms @ 16kHz
    private let bufferSize: AVAudioFrameCount = 3200

    /// 开始采集，返回 PCM 数据流 (16-bit signed integer, mono)
    func startCapturing() throws -> AsyncThrowingStream<Data, Error> {
        guard !isRunning else {
            throw AudioCaptureError.alreadyRunning
        }

        // 配置 AudioSession 以支持后台录音
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // 目标格式：16kHz / 16-bit signed integer / mono / interleaved
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
                let outputFrameCapacity = AVAudioFrameCount(
                    recordingFormat.sampleRate / inputFormat.sampleRate * Double(buffer.frameLength)
                )
                guard let output = AVAudioPCMBuffer(
                    pcmFormat: recordingFormat,
                    frameCapacity: outputFrameCapacity
                ) else { return }

                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: output, error: &error, withInputFrom: inputBlock)

                if let error {
                    continuation.yield(with: .failure(error))
                    return
                }

                guard let channelData = output.int16ChannelData else { return }
                let frameLength = Int(output.frameLength)
                let byteLength = frameLength * MemoryLayout<Int16>.size
                let data = Data(bytes: channelData.pointee, count: byteLength)
                continuation.yield(data)
            }

            do {
                try engine.start()
                isRunning = true
            } catch {
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }

        return stream
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // 释放 AudioSession，避免影响后续播放
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger(subsystem: "com.voicenote", category: "audio").error("[AudioCapture] deactivate session error: \(error.localizedDescription)")
        }
        isRunning = false
    }
}

enum AudioCaptureError: LocalizedError {
    case alreadyRunning
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "录音已在运行中"
        case .formatCreationFailed: return "音频格式创建失败"
        case .converterCreationFailed: return "音频转换器创建失败"
        }
    }
}

// MARK: - 导入音频转换器

final class AudioConverter {
    /// 将各类音频文件转换为 16kHz / 16bit / mono / WAV
    static func convertToWav(sourceURL: URL) -> URL? {
        let asset = AVAsset(url: sourceURL)
        guard let reader = try? AVAssetReader(asset: asset),
              let audioTrack = asset.tracks(withMediaType: .audio).first
        else { return nil }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(readerOutput)
        reader.startReading()

        var pcmData = Data()
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                        lengthAtOffsetOut: nil, totalLengthOut: &length,
                                        dataPointerOut: &dataPointer)
            if let dataPointer, length > 0 {
                pcmData.append(UnsafeBufferPointer(start: dataPointer, count: length))
            }
        }
        reader.cancelReading()
        guard !pcmData.isEmpty else { return nil }

        // 写 WAV
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(UUID().uuidString).wav")
        let dataSize = Int32(pcmData.count)
        let fileSize = dataSize + 36
        let sampleRate: Int32 = 16000
        let byteRate: Int32 = sampleRate * 2

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian, Array.init))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: Int16(2).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: Int16(16).littleEndian, Array.init))
        wav.append("data".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        wav.append(pcmData)

        try? wav.write(to: wavURL)
        return wavURL
    }
}
