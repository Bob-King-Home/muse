import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks

/// v3.5：后台刷新看门狗。系统定时把 App 拉起来采一次网速推给灵动岛——
/// App 万一被全屏游戏等挤掉（系统为省内存杀后台），不用等用户手动打开也能自己恢复。
/// 注意：用户手动划掉 App 后系统不会再拉起，直到下次手动打开，这是 iOS 的规矩。
enum BackgroundWatchdog {
    static let taskID = "com.speedisland.app.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main
struct SpeedIslandApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // v3.4：白色主题换深色仪表盘，先迁移存量外观设置，再建界面
        SpeedAppearance.migrateIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            // v3.18：测速功能已删（用户 2026-11-11：太费劲，删了吧）——
            // 只剩监测（实时网速仪表盘），不再有底部 Tab。
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
        // v3.5：注册后台刷新看门狗任务
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundWatchdog.taskID, using: nil) { task in
            self.handleRefresh(task: task as! BGAppRefreshTask)
        }
        BackgroundWatchdog.schedule()
        return true
    }

    /// 看门狗到点：先约下一次，再采一次网速推给灵动岛。没有活着的 Activity
    /// （用户点了停止）就直接收尾，不采样。
    private func handleRefresh(task: BGAppRefreshTask) {
        BackgroundWatchdog.schedule()
        let work = Task { @MainActor in
            guard LiveActivityManager.shared.isActive else {
                task.setTaskCompleted(success: true)
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
                isWiFi: s.isWiFi,
                ip: NetworkInfo.currentIP(isWiFi: s.isWiFi),
                netType: NetworkInfo.radioAccess(isWiFi: s.isWiFi),
                carrier: NetworkInfo.carrierName()
            )
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
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
                isWiFi: s.isWiFi,
                ip: NetworkInfo.currentIP(isWiFi: s.isWiFi),
                netType: NetworkInfo.radioAccess(isWiFi: s.isWiFi),
                carrier: NetworkInfo.carrierName()
            )
            completionHandler(.newData)
        }
    }
}
