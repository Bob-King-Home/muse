import Foundation
import UIKit

/// v2.2 引擎 — 修了 v2.1 验证报告里的 P0
/// P0-3 修：低电量切换不再永久停刷。原来 restart() 调 start() 会被 guard 挡住，
/// 现在拆成 startTimerOnly()，重启只重建 timer，不走 start() 的 guard。
/// P0-6 修：NotificationCenter 用 token 保存，stop() 时按 token 删，不再越积越多。
/// P1-5 修：文字不变也不断更，每 4 秒推一次心跳，灵动岛 / PiP 闲时也不冻住。
/// 永远开：App 活着时 Live Activity 8 小时到期会自动重建，不用手动点（v2.6 修了
/// 实现：原来只看 isActive，系统结束 Activity 时它不会变 false，永远不重建；
/// 现在每次 tick 都查系统里还活着的 Activity，没有就重建）；
/// 上次开着就被杀掉 / 重启后，再打开 App 会自动续开（UserDefaults 记状态）。
/// 低耗电：有流量 1 秒，闲时 4 秒心跳，低电量 5 秒；leeway 放到 200ms 让系统合并唤醒。
final class SpeedEngine: ObservableObject {
    @Published private(set) var downText = "0 B/s"
    @Published private(set) var upText = "0 B/s"
    @Published private(set) var isWiFi = true
    @Published private(set) var isRunning = false
    @Published private(set) var isPiPOn = false
    @Published var errorMessage: String?

    // intervalText 改成计算属性，不再存一份可能脱节的 @Published
    var intervalText: String {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "5 秒（低电量）" }
        return "1 秒"
    }

    private let sampler = NetworkSpeedSampler()
    private let manager = LiveActivityManager.shared
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "speed.engine", qos: .utility)
    private var lastDownText = ""
    private var lastUpText = ""
    private var lastPush = Date.distantPast
    private var lastIsWiFi = true
    private var powerObserver: NSObjectProtocol?
    private static let wasRunningKey = "SpeedIsland.wasRunning"

    var refreshInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 5.0 : 1.0
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        UserDefaults.standard.set(true, forKey: Self.wasRunningKey)
        BackgroundKeepAlive.shared.start()
        sampler.reset()
        lastDownText = ""; lastUpText = ""; lastPush = .distantPast
        startTimerOnly()
        // 只注册一次，token 保存好，stop() 时按 token 删
        if powerObserver == nil {
            powerObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
                object: nil, queue: nil
            ) { [weak self] _ in
                guard let self, self.isRunning else { return }
                DispatchQueue.main.async { self.restartTimerForPowerMode() }
            }
        }
    }

    private func startTimerOnly() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // leeway 200ms：让系统合并唤醒，比 50ms 省电，1 秒级显示看不出差别
        t.schedule(deadline: .now(), repeating: refreshInterval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func restartTimerForPowerMode() {
        // v2.1 的 bug 就在这里：原来调 start() 会被 guard 挡住，timer 永远不重建
        // 现在只重建 timer，不动 isRunning
        startTimerOnly()
    }

    private func tick() {
        let s = sampler.sample()
        let d = NetworkSpeedSampler.format(s.downSmoothed)
        let u = NetworkSpeedSampler.format(s.upSmoothed)
        let now = Date()
        let changed = d != lastDownText || u != lastUpText || s.isWiFi != lastIsWiFi
        // 心跳：文字不变也每 4 秒推一次，不然灵动岛 5 秒就 stale，PiP 也会断帧
        let heartbeatDue = now.timeIntervalSince(lastPush) >= 4.0
        guard changed || heartbeatDue else { return }
        lastDownText = d; lastUpText = u; lastIsWiFi = s.isWiFi; lastPush = now

        // 后台队列不读 @Published，只用本地 lastIsWiFi，避免数据竞争
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downText = d
            self.upText = u
            self.isWiFi = s.isWiFi
            // v2.6：8 小时到期自动续期。不要只看 manager.isActive（系统结束 Activity 时
            // 它不会变 false），ensureActive() 每次都查系统里还活着的 Activity，没有就重建。
            self.manager.ensureActive(downText: d, upText: u, down: s.downSmoothed, up: s.upSmoothed, isWiFi: s.isWiFi)
            if self.isPiPOn {
                PiPManager.shared.update(downText: d, upText: u, isWiFi: s.isWiFi)
            }
        }
    }

    func togglePiP() {
        // 不再置灰难用：没开始就先开始，再开小窗，一键就能用
        if !isRunning { start() }
        isPiPOn.toggle()
        if isPiPOn {
            // v2.3：先赋值回调再启动。原来先调 startPiP() 后赋值，
            // 不支持 PiP 的设备上同步失败那次回调是 nil，isPiPOn 会一直为 true
            PiPManager.shared.onPiPFailed = { [weak self] in
                self?.isPiPOn = false
                self?.errorMessage = "这台设备不支持画中画小窗，已自动切回灵动岛"
            }
            PiPManager.shared.update(downText: downText, upText: upText, isWiFi: isWiFi)
            PiPManager.shared.startPiP()
        } else {
            PiPManager.shared.stopPiP()
        }
    }

    /// v2.5：用户在 App 里改了颜色/字号/底色，立即生效：
    /// 灵动岛 / 锁屏马上重推，画中画马上重画，不用等下一秒 tick，也不用重装。
    /// @MainActor：里面调 LiveActivityManager（@MainActor）的方法，不加会报
    /// “call to main actor-isolated instance method in a synchronous nonisolated context”。
    @MainActor
    func refreshAppearance() {
        guard isRunning else { return }
        manager.refreshAppearance(downText: downText, upText: upText, isWiFi: isWiFi)
        if isPiPOn {
            PiPManager.shared.update(downText: downText, upText: upText, isWiFi: isWiFi)
        }
    }

    /// v2.3：用户在小窗上点了 X，PiPManager 发通知，ContentView 转调这里同步状态。
    /// 原来 ContentView 收到通知后什么都没做，按钮还显示“关闭小窗”，点一下是空操作，
    /// 再点一下才能重开。现在收到通知就把 isPiPOn 置 false，下一按直接重开。
    /// onReceive 在主线程跑，直接改 @Published 没问题。
    func syncPiPStopped() {
        if isPiPOn { isPiPOn = false }
    }

    private func stopTimerOnly() {
        timer?.cancel()
        timer = nil
    }

    /// @MainActor：里面调 manager.stop()（LiveActivityManager 是 @MainActor），
    /// 不加会报 “call to main actor-isolated instance method in a synchronous nonisolated context”。
    @MainActor
    func stop() {
        isRunning = false
        UserDefaults.standard.set(false, forKey: Self.wasRunningKey)
        stopTimerOnly()
        if let token = powerObserver {
            NotificationCenter.default.removeObserver(token)
            powerObserver = nil
        }
        BackgroundKeepAlive.shared.stop()
        manager.stop()
        if isPiPOn { PiPManager.shared.stopPiP(); isPiPOn = false }
        downText = "0 B/s"; upText = "0 B/s"
        lastDownText = ""; lastUpText = ""; lastPush = .distantPast
    }

    /// App 打开时调用：上次是开着的状态，就自动续开，实现“不关就一直都在”
    /// 注意：重启手机 / 被系统杀掉后，iOS 不会自己启动 App，必须手动点开一次 App 才会续开，这是系统限制。
    func restoreIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.wasRunningKey) && !isRunning {
            start()
        }
    }
}
