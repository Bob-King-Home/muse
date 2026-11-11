import CoreLocation
import Foundation

/// v3.3：定位保活 — 让 App 在后台持续运行，灵动岛每秒刷新。
/// 机制（苹果官方）：UIBackgroundModes=location + allowsBackgroundLocationUpdates=true
/// + 前台开始 startUpdatingLocation，系统把 App 当导航类应用，不挂起。
/// 注意：必须在前台开始（开始按钮就是前台点）；pausesLocationUpdatesAutomatically=false，
/// distanceFilter 不设（iOS 16.4 后低精度+距离过滤可能被挂起）；精度用百米级，省电；
/// 位置只用来保活，不记录、不上传。
final class LocationKeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationKeepAlive()

    @Published private(set) var statusText = "定位保活：未启动"

    private let manager = CLLocationManager()
    private var session: CLBackgroundActivitySession?
    private var wantsRunning = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        // v3.6：不显示系统定位指示（灵动岛里的蓝色箭头和状态栏的定位箭头）。
        // 定位保活照常用，App 自己界面里有“定位保活：运行中”，用户自己知道在定位。
        // 注意：这是苹果提供的开关，但不保证在所有 iOS 版本上都藏得住岛上的箭头；
        // 如果这版装上箭头还在，就只能关定位保活（岛会冻住），到时再加开关让用户自己选。
        manager.showsBackgroundLocationIndicator = false
    }

    /// 主线程调用（开始按钮、restoreIfNeeded 都是前台主线程）。
    func start() {
        wantsRunning = true
        switch manager.authorizationStatus {
        case .notDetermined:
            statusText = "定位保活：等待授权…"
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            wantsRunning = false
            statusText = "定位保活：未授权（去设置里允许定位）"
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        @unknown default:
            break
        }
    }

    func stop() {
        wantsRunning = false
        manager.stopUpdatingLocation()
        session?.invalidate()
        session = nil
        statusText = "定位保活：未启动"
    }

    private func begin() {
        guard wantsRunning else { return }
        if session == nil {
            session = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
        statusText = "定位保活：运行中"
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsRunning else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        case .denied, .restricted:
            wantsRunning = false
            statusText = "定位保活：未授权（去设置里允许定位）"
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusText = "定位保活：定位出错"
    }
}
