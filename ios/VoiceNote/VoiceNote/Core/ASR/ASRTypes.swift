import Foundation

/// ASR 模式：在线（FunASR 服务端）或离线（SenseVoice 本地推理）
enum ASRMode: String, CaseIterable, Codable {
    case online = "online"
    case offline = "offline"

    var displayName: String {
        switch self {
        case .online: return "在线 (FunASR)"
        case .offline: return "离线 (SenseVoice)"
        }
    }
}

/// 离线模型质量
enum ModelQuality: String, CaseIterable, Codable {
    case int8 = "int8"
    case fp32 = "fp32"

    /// 预估模型体积（含安全余量），单位 MB
    /// 预估下载+解压所需磁盘空间（含安全余量），单位 MB
    var estimatedSizeMB: Int {
        switch self {
        case .int8: return 170  // tar.bz2 ~158MB + 解压后模型 ~229MB
        case .fp32: return 860  // tar.bz2 ~845MB + 解压后模型 ~895MB
        }
    }

    var displayName: String {
        switch self {
        case .int8: return "INT8 (~\(estimatedSizeMB)MB)"
        case .fp32: return "FP32 (~\(estimatedSizeMB)MB)"
        }
    }

    /// ONNX 模型文件名
    var modelFilename: String {
        switch self {
        case .int8: return "model.int8.onnx"
        case .fp32: return "model.onnx"
        }
    }

    /// GitHub Releases 上的 tar.bz2 归档文件名
    var archiveFilename: String {
        switch self {
        case .int8: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
        case .fp32: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2"
        }
    }
}
