import Foundation

/// GPS 位置点
/// 对齐 Android: LocationPoint
struct LocationPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date

    init(latitude: Double, longitude: Double, timestamp: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }
}
