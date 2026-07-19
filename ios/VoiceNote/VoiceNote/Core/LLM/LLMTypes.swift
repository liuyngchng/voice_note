import Foundation
import os

// MARK: - 日志

extension Log {
    private static let llmLogger = Logger(subsystem: "com.voicenote", category: "llm")
    static func llm(_ msg: String) {
        llmLogger.info("\(msg)")
        LogFile.shared.append("llm", msg)
    }
}
