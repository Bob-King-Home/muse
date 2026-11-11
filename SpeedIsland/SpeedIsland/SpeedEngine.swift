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
    /// v3.7：本节累计流量和峰值（主界面展示用）
    @Published private(set) var totalDown: Double = 0
    @Published private(set) var totalUp: Double = 0
    @Published private(set) var peakDown: Double = 0
    @Published private(set) var peakUp: Double = 0
    private var totalDownBytes: Double = 0
    private var totalUpBytes: Double = 0
    private var peakDownRate: Double = 0
    private var peakUpRate: Double = 0
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
    /// v3.6：上次推给界面的网络信息——切 5G/Wi-Fi 时这些变了就要立刻推，
    /// 不能只看速度变没变
    private var lastNetType = "Wi-Fi"
    private var lastIP = ""
    private var lastCarrier = ""
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
        lastNetType = "Wi-Fi"; lastIP = ""; lastCarrier = ""
        totalDownBytes = 0; totalUpBytes = 0; peakDownRate = 0; peakUpRate = 0
        totalDown = 0; totalUp = 0; peakDown = 0; peakUp = 0
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
        // v3.7：累计本节流量和峰值（平滑速率 × 间隔估算；低电量 5 秒间隔也适用）
        totalDownBytes += s.downSmoothed * refreshInterval
        totalUpBytes += s.upSmoothed * refreshInterval
        peakDownRate = max(peakDownRate, s.downSmoothed)
        peakUpRate = max(peakUpRate, s.upSmoothed)
        tickCount += 1
        // v3.6：网络信息每秒都刷新（原来 5 秒一次），切 5G/Wi-Fi 立刻感知。
        // IP/制式/运营商是同步读，很便宜；SSID 是异步回调。
        // v3.8：SSID 没拿到时每秒都重试（fetchCurrent 头几次常返回空），
        // 拿到以后每 5 秒查一次有没有换网 —— 之前只每 5 秒查一次，
        // 拿不到就一直空着，Wi-Fi 名出不来。
        // 注意：SSID 回调不一定在主线程，统一 dispatch 到主线程再写 @Published。
        let ip = NetworkInfo.currentIP(isWiFi: s.isWiFi)
        let radio = NetworkInfo.radioAccess(isWiFi: s.isWiFi)
        let carrier = NetworkInfo.carrierName()
        let netType = s.isWiFi ? "Wi-Fi" : radio
        let netChanged = netType != lastNetType || ip != lastIP || carrier != lastCarrier || s.isWiFi != lastIsWiFi
        if s.isWiFi && (ssid.isEmpty || tickCount % 5 == 1) {
            NetworkInfo.fetchSSID { [weak self] ssid in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    guard ssid != self.ssid else { return }
                    self.ssid = ssid
                    // SSID 变了也马上推一次灵动岛，不等下一秒
                    self.manager.refreshAppearance(downText: self.downText, upText: self.upText, isWiFi: self.isWiFi, ssid: ssid, ip: self.ip, netType: self.netType, carrier: self.carrier)
                }
            }
        }
        let d = NetworkSpeedSampler.format(s.downSmoothed)
        let u = NetworkSpeedSampler.format(s.upSmoothed)
        let now = Date()
        let changed = d != lastDownText || u != lastUpText || netChanged
        let sinceLastPush = now.timeIntervalSince(lastPush)
        // v3.8：灵动岛限速 —— iOS 会对持续每秒推送的 Live Activity 限流，
        // 1~2 分钟后岛就只剩 ~10 秒动一次（用户实测；锁屏是按需渲染所以看着正常）。
        // 主界面数字仍每秒刷新；岛每 2 秒最多推一次，留在系统预算内，岛才能一直动。
        // 心跳：文字不变也每 4 秒推一次，不然灵动岛 5 秒就 stale。
        let islandDue = changed && sinceLastPush >= 2.0
        let heartbeatDue = sinceLastPush >= 4.0
        let pushIsland = islandDue || heartbeatDue
        guard changed || heartbeatDue else { return }
        lastDownText = d; lastUpText = u; lastIsWiFi = s.isWiFi
        lastNetType = netType; lastIP = ip; lastCarrier = carrier
        if pushIsland { lastPush = now }

        // 后台队列不读 @Published，只用本地 lastIsWiFi，避免数据竞争
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downText = d
            self.upText = u
            self.isWiFi = s.isWiFi
            self.downHistory = self.historyBuffer
            self.upHistory = self.upHistoryBuffer
            self.totalDown = self.totalDownBytes
            self.totalUp = self.totalUpBytes
            self.peakDown = self.peakDownRate
            self.peakUp = self.peakUpRate
            self.ip = ip
            self.netType = netType
            self.carrier = carrier
            if !s.isWiFi { self.ssid = "" }
            // v3.8：岛按 2 秒限速推（上面 pushIsland 决定），主界面数字每秒都刷新。
            // v2.6：8 小时到期自动续期。不要只看 manager.isActive（系统结束 Activity 时
            // 它不会变 false），ensureActive() 每次都查系统里还活着的 Activity，没有就重建。
            if pushIsland {
                self.manager.ensureActive(downText: d, upText: u, down: s.downSmoothed, up: s.upSmoothed, isWiFi: s.isWiFi, ssid: self.ssid, ip: ip, netType: netType, carrier: carrier)
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

    /// v3.10：累计流量重置按钮 —— 本节流量和峰值清零，重新开始累计（不用停了再开）。
    @MainActor
    func resetSessionStats() {
        totalDownBytes = 0; totalUpBytes = 0; peakDownRate = 0; peakUpRate = 0
        totalDown = 0; totalUp = 0; peakDown = 0; peakUp = 0
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
        totalDownBytes = 0; totalUpBytes = 0; peakDownRate = 0; peakUpRate = 0
        totalDown = 0; totalUp = 0; peakDown = 0; peakUp = 0
        ssid = ""; ip = ""; netType = "Wi-Fi"; carrier = ""
        lastDownText = ""; lastUpText = ""; lastPush = .distantPast
        lastNetType = "Wi-Fi"; lastIP = ""; lastCarrier = ""
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
