import AVFoundation
import Foundation

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
