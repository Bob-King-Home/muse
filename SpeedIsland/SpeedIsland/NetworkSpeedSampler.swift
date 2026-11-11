import Foundation
import Network

/// v2.3 采样器 — v2.2 基础上再修 2 项
/// 1) 双卡：v2.2 README 说“pdp_ip1 不再漏”是假话，代码只认 pdp_ip0。
///    现在蜂窝汇总所有 pdp_ip* 接口的计数（另一张卡没流量时增量为 0，不会双计）。
/// 2) 复位限速：32 位绕回按 +2^32 补差只对真绕回成立；开关飞行模式、切网、
///    重启后计数器是归零不是绕回。sample() 里对速率限速，超过 500 MB/s
///    当次按 0 算并重新记基线，不再跳一次 1330 MB/s。
/// 只统计 AF_LINK 的条目，VPN 时回退到 utun* 汇总。timebase 只算一次缓存。
final class NetworkSpeedSampler {
    struct Sample {
        let downBytesPerSec: Double
        let upBytesPerSec: Double
        let isWiFi: Bool
        let downSmoothed: Double
        let upSmoothed: Double
        let isVPN: Bool
    }

    private var lastDown: UInt64 = 0
    private var lastUp: UInt64 = 0
    private var lastMach: UInt64 = 0
    private var downSmooth: Double = 0
    private var upSmooth: Double = 0
    private var zeroStreak = 0
    private var timebaseNumer: Double = 1
    private var timebaseDenom: Double = 1
    private var timebaseCached = false

    private let monitor = NWPathMonitor()
    /// v3.6：默认 false，别默认 true——默认 true 会让蜂窝下也显示 Wi-Fi，
    /// 采样去读 en0 的计数（蜂窝流量在 pdp_ip 上），速度就一直是 0。
    /// 启动后立刻按当前路径校准一次，之后的更新走 pathUpdateHandler。
    private(set) var isWiFi = false
    private(set) var isVPN = false

    init() {
        var info = mach_timebase_info_data_t()
        if mach_timebase_info(&info) == KERN_SUCCESS {
            timebaseNumer = Double(info.numer)
            timebaseDenom = Double(info.denom)
            timebaseCached = true
        }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // isWiFi / isVPN 在 monitor 自己的队列里写，sample() 在引擎队列里读。
            // Bool 读写在 ARM64 上实际是原子的，最多某一秒读到旧值，不影响显示，
            // 不算严格同步，但无害。不要误以为这里有快照机制。
            self.isWiFi = path.usesInterfaceType(.wifi)
            self.isVPN = path.usesInterfaceType(.other) && path.availableInterfaces.contains { $0.name.hasPrefix("utun") }
        }
        monitor.start(queue: DispatchQueue(label: "speed.path", qos: .utility))
        // v3.6：启动后立刻按当前路径校准一次，别等第一次回调（回调来之前
        // 默认值会让蜂窝下错显示 Wi-Fi、采样读错接口导致速度一直是 0）。
        isWiFi = monitor.currentPath.usesInterfaceType(.wifi)
        isVPN = monitor.currentPath.usesInterfaceType(.other)
    }

    deinit { monitor.cancel() }

    private func currentBytes() -> (down: UInt64, up: UInt64, isVPNActive: Bool) {
        var down: UInt64 = 0
        var up: UInt64 = 0
        var vpnDown: UInt64 = 0
        var vpnUp: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0, false) }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            // 只统计 AF_LINK，AF_INET / AF_INET6 的 ifa_data 不可靠
            if p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
               let data = p.pointee.ifa_data {
                let name = String(cString: p.pointee.ifa_name)
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                if isWiFi && name == "en0" {
                    down = UInt64(d.ifi_ibytes); up = UInt64(d.ifi_obytes)
                    break
                } else if !isWiFi && name.hasPrefix("pdp_ip") {
                    // v2.3：双卡汇总所有 pdp_ip*（pdp_ip0 + pdp_ip1 …），
                    // 不再 break 在 pdp_ip0 上；没流量的卡增量为 0，不会双计
                    down += UInt64(d.ifi_ibytes); up += UInt64(d.ifi_obytes)
                } else if name.hasPrefix("utun") {
                    vpnDown += UInt64(d.ifi_ibytes); vpnUp += UInt64(d.ifi_obytes)
                }
            }
            ptr = p.pointee.ifa_next
        }
        // VPN 时主网卡读不到真实流量，回退到 utun 汇总，并标记出来
        if down == 0 && up == 0 && vpnDown > 0 {
            return (vpnDown, vpnUp, true)
        }
        return (down, up, false)
    }

    private func delta(_ cur: UInt64, _ last: UInt64) -> UInt64 {
        if cur >= last { return cur - last }
        // 32 位绕回：+2^32 补差，不再直接归零
        return cur + (UInt64(1) << 32) - last
    }

    func sample() -> Sample {
        let nowMach = mach_absolute_time()
        let cur = currentBytes()
        defer { lastDown = cur.down; lastUp = cur.up; lastMach = nowMach }

        guard lastMach != 0 else {
            return Sample(downBytesPerSec: 0, upBytesPerSec: 0, isWiFi: isWiFi, downSmoothed: 0, upSmoothed: 0, isVPN: cur.isVPNActive)
        }
        let elapsedNs: Double
        if timebaseCached {
            elapsedNs = Double(nowMach - lastMach) * timebaseNumer / timebaseDenom
        } else {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            elapsedNs = Double(nowMach - lastMach) * Double(info.numer) / Double(info.denom)
        }
        let dt = max(elapsedNs / 1_000_000_000, 0.1)
        // v2.3 复位限速：真 4GB 绕回的 delta 很小，不会到这里；开关飞行模式、
        // 切 Wi-Fi/蜂窝、重启后计数器归零，delta() 会按 +2^32 补出天价速率
        // （上次 3,000,000,000 → 本次 100,000,000 会算出约 1330 MB/s）。
        // 超过 500 MB/s 就视为复位，当次按 0 算；defer 已把基线记成当前值，
        // 下一秒就恢复正常。500 MB/s 是按速率限的，低电量 5 秒间隔也适用。
        let maxSaneRate = 500.0 * 1024 * 1024
        var downRaw = Double(delta(cur.down, lastDown)) / dt
        var upRaw = Double(delta(cur.up, lastUp)) / dt
        if downRaw > maxSaneRate { downRaw = 0 }
        if upRaw > maxSaneRate { upRaw = 0 }

        if downRaw == 0 && upRaw == 0 {
            zeroStreak += 1
            if zeroStreak >= 2 { downSmooth = 0; upSmooth = 0 }
        } else {
            zeroStreak = 0
            // 固定 alpha 平滑，删掉 v2.1 里“小于 0.4 就直接跳变”的分支，平滑不再被抵消
            downSmooth = downSmooth * 0.35 + downRaw * 0.65
            upSmooth = upSmooth * 0.35 + upRaw * 0.65
        }
        return Sample(downBytesPerSec: downRaw, upBytesPerSec: upRaw, isWiFi: isWiFi, downSmoothed: downSmooth, upSmoothed: upSmooth, isVPN: cur.isVPNActive)
    }

    func reset() {
        lastDown = 0; lastUp = 0; lastMach = 0
        downSmooth = 0; upSmooth = 0; zeroStreak = 0
    }

    static func format(_ bytesPerSec: Double) -> String {
        // v3.1：按用户要求只显示整数 KB、MB 只留一位小数：130 KB/s、2.4 MB/s，
        // 不再显示 82.3 KB/s 这类小数。
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        if bytesPerSec < 1024 * 1024 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        return String(format: "%.1f MB/s", bytesPerSec / 1024 / 1024)
    }

    /// v3.7：累计流量格式（不带 /s）：850 KB、12.3 MB、1.24 GB
    static func formatBytes(_ bytes: Double) -> String {
        if bytes < 1024 { return String(format: "%.0f B", bytes) }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", bytes / 1024 / 1024) }
        return String(format: "%.2f GB", bytes / 1024 / 1024 / 1024)
    }
}
