import Foundation

/// LLM 模式：在线（OpenAI 兼容 API）或离线（本地 llama.cpp 推理）
/// 对齐 ASRMode 模式
enum LLMMode: String, CaseIterable, Codable {
    case online = "online"
    case offline = "offline"

    var displayName: String {
        switch self {
        case .online: return "在线 (API)"
        case .offline: return "离线 (本地模型)"
        }
    }
}

/// 离线 LLM 模型信息
/// 对齐 ModelQuality 模式
enum LLMModelInfo: String, CaseIterable, Codable {
    case qwen3_0_6b_q4km = "qwen3_0_6b_q4km"
    case qwen2_5_0_5b_q4km = "qwen2_5_0_5b_q4km"
    case custom = "custom"

    /// 预估模型文件大小，单位 MB
    var estimatedSizeMB: Int {
        switch self {
        case .qwen3_0_6b_q4km:     return 400
        case .qwen2_5_0_5b_q4km:   return 352
        case .custom:               return 500
        }
    }

    var displayName: String {
        switch self {
        case .qwen3_0_6b_q4km:     return "Qwen3-0.6B (~\(estimatedSizeMB)MB)"
        case .qwen2_5_0_5b_q4km:   return "Qwen2.5-0.5B (~\(estimatedSizeMB)MB)"
        case .custom:               return "自定义模型"
        }
    }

    /// GGUF 模型文件名
    var modelFilename: String {
        switch self {
        case .qwen3_0_6b_q4km:     return "qwen3-0.6b-q4_k_m.gguf"
        case .qwen2_5_0_5b_q4km:   return "qwen2.5-0.5b-instruct-q4_k_m.gguf"
        case .custom:               return "custom.gguf"
        }
    }

    /// ModelScope 直链下载 URL
    var modelscopeDownloadURL: String? {
        switch self {
        case .qwen3_0_6b_q4km:
            return "https://modelscope.cn/models/Qwen/Qwen3-0.6B-GGUF/resolve/master/Qwen3-0.6B-Q4_K_M.gguf"
        case .qwen2_5_0_5b_q4km:
            return "https://modelscope.cn/models/qwen/Qwen2.5-0.5B-Instruct-gguf/resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf"
        case .custom:
            return nil
        }
    }

    /// ModelScope 页面 URL（供手动下载参考）
    var modelscopePageURL: String? {
        switch self {
        case .qwen3_0_6b_q4km:
            return "https://modelscope.cn/models/Qwen/Qwen3-0.6B-GGUF"
        case .qwen2_5_0_5b_q4km:
            return "https://modelscope.cn/models/qwen/Qwen2.5-0.5B-Instruct-gguf"
        case .custom:
            return nil
        }
    }

    /// GitHub Releases 兜底下载 URL（可选，后续补充）
    var githubDownloadURL: String? {
        // TODO: 后续补充 GitHub Releases 镜像地址
        return nil
    }
}
