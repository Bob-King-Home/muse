import Foundation
import UIKit

/// v3.1 引擎 — 画中画已按用户要求移除
/// 后台刷新改为 iOS 后台抓取（Background Fetch，系统定期唤醒 App 采一次网速推给
/// 灵动岛，频率由系统决定）；前台打开 App 时仍是 1 秒定时器。
/// 保留：Live Activity 8 小时到期自动重建；上次开着被杀掉/重启后，再打开 App 自动续开；
/// 有流量 1 秒，闲时 4 秒心跳，低电量 5 秒；leeway 200ms。
final class SpeedEngine: ObservableObject {
    @Published private(set) var downText = "0 B/s"
    @Published private(set) var upText = "0 B/s"
    @Published private(set) var isWiFi = true
    @Published private(set) var isRunning = false
    /// v3.4：最近 60 次采样的下载速度，供主界面实时曲线画图（不新增采样）
    @Published private(set) var downHistory: [Double] = []
    private var historyBuffer: [Double] = []
    /// v3.5：最近 60 次采样的上传速度（双线曲线用）
    @Published private(set) var upHistory: [Double] = []
    private var upHistoryBuffer: [Double] = []
    /// v3.5：表盘用的当前下载速度（字节/秒，平滑后）
    @Published private(set) var downBytesPerSec = 0.0
    /// v3.5：网络信息（灵动岛展开页 + 主界面网络卡用），每 5 秒刷新一次
    @Published private(set) var ssid = ""
    @Published private(set) var ip = ""
    @Published private(set) var netType = "Wi-Fi"
    @Published private(set) var carrier = ""
    private var tickCount = 0
    @Published var errorMessage: String?

    // intervalText 改成计算属性，不再存一份可能脱节的 @Published
    var intervalText: String {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "5 秒（低电量）" }
        return "1 秒"
    }

    private let sampler = NetworkSpeedSampler()
    private let manager = LiveActivityManager.shared
    private let keepAlive = LocationKeepAlive.shared
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
        sampler.reset()
        lastDownText = ""; lastUpText = ""; lastPush = .distantPast
        historyBuffer = []; downHistory = []
        upHistoryBuffer = []; upHistory = []
        tickCount = 0
        ssid = ""; ip = ""; netType = "Wi-Fi"; carrier = ""
        startTimerOnly()
        // v3.5：约好后台刷新看门狗（系统定时把 App 拉起来推一次灵动岛），
        // 这样 App 万一被游戏等挤掉，也能自己恢复，不用等用户手动打开
        BackgroundWatchdog.schedule()
        // v3.3：定位保活和采样一起开（前台点开始，系统允许后台继续定位）
        keepAlive.start()
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
        // 曲线数据每次采样都记（后台队列的私有缓冲，主线程再发布）
        historyBuffer.append(s.downSmoothed)
        if historyBuffer.count > 60 { historyBuffer.removeFirst(historyBuffer.count - 60) }
        upHistoryBuffer.append(s.upSmoothed)
        if upHistoryBuffer.count > 60 { upHistoryBuffer.removeFirst(upHistoryBuffer.count - 60) }
        // v3.5：网络信息每 5 秒刷新一次（SSID 是异步回调，IP/制式/运营商是同步读）
        tickCount += 1
        if tickCount % 5 == 1 { refreshNetworkInfo(isWiFi: s.isWiFi) }
        let d = NetworkSpeedSampler.format(s.downSmoothed)
        let u = NetworkSpeedSampler.format(s.upSmoothed)
        let now = Date()
        let changed = d != lastDownText || u != lastUpText || s.isWiFi != lastIsWiFi
        // 心跳：文字不变也每 4 秒推一次，不然灵动岛 5 秒就 stale
        let heartbeatDue = now.timeIntervalSince(lastPush) >= 4.0
        guard changed || heartbeatDue else { return }
        lastDownText = d; lastUpText = u; lastIsWiFi = s.isWiFi; lastPush = now

        // 后台队列不读 @Published，只用本地 lastIsWiFi，避免数据竞争
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downText = d
            self.upText = u
            self.isWiFi = s.isWiFi
            self.downHistory = self.historyBuffer
            self.upHistory = self.upHistoryBuffer
            self.downBytesPerSec = s.downSmoothed
            // v2.6：8 小时到期自动续期。不要只看 manager.isActive（系统结束 Activity 时
            // 它不会变 false），ensureActive() 每次都查系统里还活着的 Activity，没有就重建。
            self.manager.ensureActive(downText: d, upText: u, down: s.downSmoothed, up: s.upSmoothed, isWiFi: s.isWiFi, ssid: self.ssid, ip: self.ip, netType: self.netType, carrier: self.carrier)
        }
    }

    /// v3.5：刷新网络信息。IP/制式/运营商同步读完先发布；SSID 异步回来再补。
    /// 注意：SSID 回调不一定在主线程，统一 dispatch 到主线程再写 @Published。
    private func refreshNetworkInfo(isWiFi: Bool) {
        let ip = NetworkInfo.currentIP(isWiFi: isWiFi)
        let radio = NetworkInfo.radioAccess(isWiFi: isWiFi)
        let carrier = NetworkInfo.carrierName()
        let netType = isWiFi ? "Wi-Fi" : radio
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ip = ip
            self.netType = netType
            self.carrier = carrier
            // v3.6：切到蜂窝后把旧 SSID 清掉，不然还显示上一个 Wi-Fi 的名字
            if !isWiFi { self.ssid = "" }
        }
        guard isWiFi else { return }
        NetworkInfo.fetchSSID { [weak self] ssid in
            DispatchQueue.main.async {
                self?.ssid = ssid
            }
        }
    }

    /// v2.5：用户在 App 里改了颜色/字号/底色，立即生效：
    /// 灵动岛 / 锁屏马上重推，不用等下一秒 tick，也不用重装。
    /// @MainActor：里面调 LiveActivityManager（@MainActor）的方法，不加会报
    /// “call to main actor-isolated instance method in a synchronous nonisolated context”。
    @MainActor
    func refreshAppearance() {
        guard isRunning else { return }
        manager.refreshAppearance(downText: downText, upText: upText, isWiFi: isWiFi, ssid: ssid, ip: ip, netType: netType, carrier: carrier)
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
        keepAlive.stop()
        if let token = powerObserver {
            NotificationCenter.default.removeObserver(token)
            powerObserver = nil
        }
        manager.stop()
        downText = "0 B/s"; upText = "0 B/s"
        historyBuffer = []; downHistory = []
        upHistoryBuffer = []; upHistory = []
        downBytesPerSec = 0
        ssid = ""; ip = ""; netType = "Wi-Fi"; carrier = ""
        lastDownText = ""; lastUpText = ""; lastPush = .distantPast
    }

    /// v3.5：从后台/全屏游戏切回来时恢复。App 可能在后台被挂起甚至被系统杀掉过，
    /// 回到前台就重建定时器、重开定位保活、立即采一次推给灵动岛。
    /// 注意：定时器和定位重开都是幂等的，重复调没事。
    @MainActor
    func resumeAfterBackground() {
        guard isRunning else { return }
        startTimerOnly()
        keepAlive.start()
    }

    /// App 打开时调用：上次是开着的状态，就自动续开，实现“不关就一直都在”
    /// 注意：重启手机 / 被系统杀掉后，iOS 不会自己启动 App，必须手动点开一次 App 才会续开，这是系统限制。
    func restoreIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.wasRunningKey) && !isRunning {
            start()
        }
    }
}
