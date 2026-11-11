import ActivityKit
import Foundation

/// v2.2 Live Activity 管理
/// 修 P1-2：startTask 和 updateTask 分开，不再互相取消；start 用 await 串行化。
/// 修 P1-1：不再宣传“灵动岛 1 秒”。前台 App 内约 1 秒；灵动岛已开频繁刷新
/// （Info.plist 有 NSSupportsLiveActivitiesFrequentUpdates），正常情况下约 1 秒一跳，
/// 系统繁忙、低电量时可能放慢。FrequentUpdates 提高预算，不能取消预算。
/// 闲时每 4 秒推一次心跳保鲜。
/// 修 P1-7：失败不再只 print，写进 errorMessage 让界面能提示用户去设置里开。
@MainActor
final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()
    @Published private(set) var isActive = false
    @Published var errorMessage: String?

    private var activity: Activity<SpeedActivityAttributes>?
    private var lastDownText = ""
    private var lastUpText = ""
    private var lastPush = Date.distantPast
    // v3.5：记上次推的网络信息，变了也要推一次（和外观一样，不然只改 SSID/IP
    // 不改网速时 update() 的 changed 判断会直接 return）
    private var lastSsid = ""
    private var lastIp = ""
    private var lastNetType = ""
    private var lastCarrier = ""
    /// v3.13：本次测速开始时间（苹果倒计时的逻辑 —— 系统本地每秒渲染计时，
    /// 不用 App 每秒推送）。新开一个 Activity 时记一次，Activity 重建时重记。
    private var sessionStart = Date()
    private var startTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    // v2.5：记上次推的外观，改了颜色/字号/底色就算“变了”，也要推一次，
    // 不然只改外观不改网速时 update() 的 changed 判断会直接 return。
    private var lastFontColorHex = ""
    private var lastFontSizeLevel = -1
    private var lastBackgroundHex = ""

    /// v2.5：从 UserDefaults 读当前外观，打包进 ContentState 推给 Widget。
    private func currentState(downText: String, upText: String, isWiFi: Bool, ssid: String = "", ip: String = "", netType: String = "Wi-Fi", carrier: String = "") -> SpeedActivityAttributes.ContentState {
        SpeedActivityAttributes.ContentState(
            downText: downText,
            upText: upText,
            isWiFi: isWiFi,
            fontColorHex: SpeedAppearance.fontColorHex,
            fontSizeLevel: SpeedAppearance.fontSizeLevel,
            backgroundHex: SpeedAppearance.backgroundHex,
            ssid: ssid,
            ip: ip,
            netType: netType,
            carrier: carrier,
            startDate: sessionStart
        )
    }

    private func appearanceChanged() -> Bool {
        SpeedAppearance.fontColorHex != lastFontColorHex
            || SpeedAppearance.fontSizeLevel != lastFontSizeLevel
            || SpeedAppearance.backgroundHex != lastBackgroundHex
    }

    private func netInfoChanged(ssid: String, ip: String, netType: String, carrier: String) -> Bool {
        ssid != lastSsid || ip != lastIp || netType != lastNetType || carrier != lastCarrier
    }

    private func rememberAppearance() {
        lastFontColorHex = SpeedAppearance.fontColorHex
        lastFontSizeLevel = SpeedAppearance.fontSizeLevel
        lastBackgroundHex = SpeedAppearance.backgroundHex
    }

    private func rememberNetInfo(ssid: String, ip: String, netType: String, carrier: String) {
        lastSsid = ssid; lastIp = ip; lastNetType = netType; lastCarrier = carrier
    }

    var frequentUpdatesEnabled: Bool {
        ActivityAuthorizationInfo().frequentPushesEnabled
    }

    func start(downText: String, upText: String, down: Double, up: Double, isWiFi: Bool, ssid: String = "", ip: String = "", netType: String = "Wi-Fi", carrier: String = "") {
        let info = ActivityAuthorizationInfo()
        guard info.areActivitiesEnabled else {
            errorMessage = "实时活动被关了：去设置 > SpeedIsland > 实时活动打开"
            return
        }
        if !info.frequentPushesEnabled {
            errorMessage = "已开灵动岛，但系统限制了频繁刷新，灵动岛约 5-15 秒一跳（前台 App 内仍约 1 秒）"
        }
        if let existing = Activity<SpeedActivityAttributes>.activities.first {
            activity = existing
            isActive = true
            update(downText: downText, upText: upText, down: down, up: up, isWiFi: isWiFi, ssid: ssid, ip: ip, netType: netType, carrier: carrier)
            return
        }
        startTask?.cancel()
        startTask = Task {
            // v3.16：先开新岛，成功了再结束旧岛 —— 这样新岛 request 万一在后台失败，
            // 旧岛还在（岛上继续显示旧速度），下一秒 tick 会再试；不会像之前那样
            // 旧岛已结束、新岛又开失败，岛直接空掉，非要点开 App 才恢复。
            // （旧岛的 end 在后台跑，不等它，岛的空档只有一瞬间。）
            let old = activity
            let attrs = SpeedActivityAttributes()
            // v3.13：新开一个 Activity 就是一次新的测速，计时从现在开始
            sessionStart = Date()
            let state = currentState(downText: downText, upText: upText, isWiFi: isWiFi, ssid: ssid, ip: ip, netType: netType, carrier: carrier)
            do {
                activity = try Activity.request(attributes: attrs, content: .init(state: state, staleDate: Date().addingTimeInterval(10)))
                lastDownText = downText; lastUpText = upText; lastPush = Date()
                rememberAppearance()
                rememberNetInfo(ssid: ssid, ip: ip, netType: netType, carrier: carrier)
                isActive = true
                errorMessage = nil
                if let old { Task { await old.end(nil, dismissalPolicy: .immediate) } }
            } catch {
                errorMessage = "灵动岛启动失败：\(error.localizedDescription)"
            }
        }
    }

    func update(downText: String, upText: String, down: Double, up: Double, isWiFi: Bool, ssid: String = "", ip: String = "", netType: String = "Wi-Fi", carrier: String = "") {
        guard let activity else { return }
        let now = Date()
        let changed = downText != lastDownText || upText != lastUpText || appearanceChanged() || netInfoChanged(ssid: ssid, ip: ip, netType: netType, carrier: carrier)
        let overdue = now.timeIntervalSince(lastPush) >= 4.0
        guard changed || overdue else { return }
        lastDownText = downText; lastUpText = upText; lastPush = now
        rememberAppearance()
        rememberNetInfo(ssid: ssid, ip: ip, netType: netType, carrier: carrier)
        updateTask?.cancel()
        updateTask = Task {
            let state = currentState(downText: downText, upText: upText, isWiFi: isWiFi, ssid: ssid, ip: ip, netType: netType, carrier: carrier)
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(10)))
        }
    }

    /// v2.6：8 小时到期自动续真的修了。原来 tick() 只看 manager.isActive，但系统
    /// 8 小时后结束 Activity 时不会通知 App，isActive 一直是 true，tick() 就一直调
    /// update()（对已结束的 Activity 无效），Activity 死透了也永远不重建，README
    /// “8 小时到期自动续”是假话。现在每次 tick 都查一次系统里还活着的 Activity：
    /// 有就 update，没有就 start() 重建。
    /// 注意：灵动岛被用户手动划掉也会重建（App 还在跑就认为还要显示），要彻底关掉
    /// 点 App 里的“停止”。
    func ensureActive(downText: String, upText: String, down: Double, up: Double, isWiFi: Bool, ssid: String = "", ip: String = "", netType: String = "Wi-Fi", carrier: String = "") {
        if let live = Activity<SpeedActivityAttributes>.activities.first {
            activity = live
            isActive = true
            update(downText: downText, upText: upText, down: down, up: up, isWiFi: isWiFi, ssid: ssid, ip: ip, netType: netType, carrier: carrier)
        } else {
            activity = nil
            isActive = false
            start(downText: downText, upText: upText, down: down, up: up, isWiFi: isWiFi, ssid: ssid, ip: ip, netType: netType, carrier: carrier)
        }
    }

    /// v2.5：用户在 App 里改了颜色/字号/底色，立即把当前网速 + 新外观推给灵动岛 / 锁屏，
    /// 不用等下一秒 tick，也不用重装。
    func refreshAppearance(downText: String, upText: String, isWiFi: Bool, ssid: String = "", ip: String = "", netType: String = "Wi-Fi", carrier: String = "") {
        guard let activity else { return }
        lastPush = Date()
        rememberAppearance()
        rememberNetInfo(ssid: ssid, ip: ip, netType: netType, carrier: carrier)
        updateTask?.cancel()
        updateTask = Task {
            let state = currentState(downText: downText, upText: upText, isWiFi: isWiFi, ssid: ssid, ip: ip, netType: netType, carrier: carrier)
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(10)))
        }
    }

    /// v3.14：重建 Live Activity（重置系统限流预算）。
    /// v3.16：重建加速 + 后台失败不丢岛 —— 先开新岛，成功了再结束旧岛。
    /// 新岛 request 在后台失败时旧岛还在（岛上继续显示旧速度），下一秒 tick 会再试；
    /// 不会像 v3.15 那样旧岛先结束、新岛又开失败，岛直接空掉，非要点开 App 才恢复。
    /// v3.19：重建不再重置 sessionStart（用户 2026-11-12：重建要用户无感知）。
    /// 之前每次重建都把 sessionStart 设成现在，“已运行”计时每 5 分钟跳回 00:00，
    /// 用户一眼就能看出来重建了。sessionStart 只在 start()（用户点开始）时重置。
    /// 调用方（Engine 每 2 分钟调一次）需传入当前速度与网络信息。
    func restart(downText: String, upText: String, isWiFi: Bool, ssid: String = "", ip: String = "", netType: String = "Wi-Fi", carrier: String = "") {
        guard activity != nil else { return }
        startTask?.cancel()
        updateTask?.cancel()
        startTask = Task {
            let old = activity
            let attrs = SpeedActivityAttributes()
            let state = currentState(downText: downText, upText: upText, isWiFi: isWiFi, ssid: ssid, ip: ip, netType: netType, carrier: carrier)
            // 后台 request 偶尔会失败一次（系统忙），失败就 2 秒后再试一次；
            // 两次都失败也不丢岛（旧岛还在），下一秒 tick / 下次 5 分钟会再试。
            for attempt in 0..<2 {
                do {
                    activity = try Activity.request(attributes: attrs, content: .init(state: state, staleDate: Date().addingTimeInterval(10)))
                    lastDownText = downText; lastUpText = upText; lastPush = Date()
                    rememberAppearance()
                    rememberNetInfo(ssid: ssid, ip: ip, netType: netType, carrier: carrier)
                    isActive = true
                    errorMessage = nil
                    if let old { Task { await old.end(nil, dismissalPolicy: .immediate) } }
                    return
                } catch {
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            }
            // 两次都失败：旧岛还在，先不报错（下一秒 tick / 下次 2 分钟会再试重建），
            // 避免 App 里一直挂着“重建失败”。注意 activity 仍指向旧岛。
            errorMessage = nil
        }
    }

    func end() async {
        startTask?.cancel()
        updateTask?.cancel()
        if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
        isActive = false
        lastDownText = ""; lastUpText = ""
        lastFontColorHex = ""; lastFontSizeLevel = -1; lastBackgroundHex = ""
        lastSsid = ""; lastIp = ""; lastNetType = ""; lastCarrier = ""
    }

    func stop() { Task { await end() } }
}
