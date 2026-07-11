import Foundation

/// 离线模型质量
enum ModelQuality: String, CaseIterable, Codable {
    case int8 = "int8"
    case fp32 = "fp32"

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
