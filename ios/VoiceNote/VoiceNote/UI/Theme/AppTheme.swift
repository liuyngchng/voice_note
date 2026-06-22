import SwiftUI

/// App 主题常量
/// 对齐 Android: ui/theme/Color.kt + Theme.kt
enum AppTheme {
    static let accentColor = Color.accentColor
    static let recordingRed = Color(red: 0xD3 / 255, green: 0x2F / 255, blue: 0x2F / 255)
    static let cardBackground = Color(.systemBackground)
    static let secondaryBackground = Color(.systemGroupedBackground)

    /// 格式化时长
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
