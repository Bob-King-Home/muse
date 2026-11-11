import SwiftUI
import UIKit
import UserNotifications

@main
struct SpeedIslandApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// v3.1：AppDelegate 只做两件事——
/// 1) 启动时请求一次通知授权，这样 App 会出现在“设置 > 通知”里；
/// 2) 后台抓取（Background Fetch）：系统定期唤醒 App 时采一次网速推给灵动岛。
///    没开过（没有活着的 Live Activity）就直接报 noData，不采样。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        return true
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard LiveActivityManager.shared.isActive else {
                completionHandler(.noData)
                return
            }
            let sampler = NetworkSpeedSampler()
            _ = sampler.sample()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let s = sampler.sample()
            LiveActivityManager.shared.ensureActive(
                downText: NetworkSpeedSampler.format(s.downSmoothed),
                upText: NetworkSpeedSampler.format(s.upSmoothed),
                down: s.downSmoothed,
                up: s.upSmoothed,
                isWiFi: s.isWiFi
            )
            completionHandler(.newData)
        }
    }
}
