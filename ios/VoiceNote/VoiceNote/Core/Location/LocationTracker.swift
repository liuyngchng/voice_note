import CoreLocation
import Foundation

/// GPS 位置追踪
/// 对齐 Android: LocationTracker.kt (LocationManager)
final class LocationTracker: NSObject {
    private let manager = CLLocationManager()
    private var continuation: AsyncStream<LocationPoint>.Continuation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10           // 每 10 米更新一次
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// 开始追踪，返回位置点流
    func startTracking() -> AsyncStream<LocationPoint> {
        manager.requestWhenInUseAuthorization()

        return AsyncStream { continuation in
            self.continuation = continuation
            manager.startUpdatingLocation()
        }
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        continuation?.finish()
        continuation = nil
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            let point = LocationPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timestamp: location.timestamp
            )
            continuation?.yield(point)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 静默处理 — 不中断流
    }
}
