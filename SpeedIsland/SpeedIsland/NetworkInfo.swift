import CoreTelephony
import Foundation
import NetworkExtension

/// v3.5：网络信息（灵动岛展开页 + 主界面网络卡用）。
/// - Wi-Fi 名字（SSID）：NEHotspotNetwork.fetchCurrent，iOS 13+ 只要有定位权限就能读，
///   不需要 Hotspot  entitlement；本 App 点开始时已拿到 When In Use 定位授权。
///   拿不到就返回 ""，界面显示 "—"。
/// - 本机 IP：getifaddrs，Wi-Fi 走 en0，蜂窝走 pdp_ip0，无需任何权限。
/// - 蜂窝制式：CTTelephonyNetworkInfo，5G / 4G / 3G，无需权限。
/// - Wi-Fi 频段（2.4G / 5G）：苹果没有开放给第三方 App 的接口，NEHotspotNetwork
///   只给 SSID/BSSID，所以这一项给不出来，不是没做。
enum NetworkInfo {
    /// 当前 Wi-Fi 名字（SSID），异步回调；不是 Wi-Fi 或读不到返回 ""。
    static func fetchSSID(completion: @escaping (String) -> Void) {
        NEHotspotNetwork.fetchCurrent { network in
            completion(network?.ssid ?? "")
        }
    }

    /// 本机 IPv4：Wi-Fi 走 en0，蜂窝走 pdp_ip0；拿不到返回 ""。
    static func currentIP(isWiFi: Bool) -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "" }
        defer { freeifaddrs(first) }
        let target = isWiFi ? "en0" : "pdp_ip0"
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if name == target, p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var addr = p.pointee.ifa_addr.pointee
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(&addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: buf)
                if !ip.isEmpty { return ip }
            }
            ptr = p.pointee.ifa_next
        }
        return ""
    }

    /// 蜂窝制式：5G / 4G / 3G / 蜂窝；Wi-Fi 时返回 "Wi-Fi"。
    static func radioAccess(isWiFi: Bool) -> String {
        if isWiFi { return "Wi-Fi" }
        let info = CTTelephonyNetworkInfo()
        guard let tech = info.serviceCurrentRadioAccessTechnology?.values.first else { return "蜂窝" }
        switch tech {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA:
            return "5G"
        case CTRadioAccessTechnologyLTE:
            return "4G"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA,
             CTRadioAccessTechnologyHSUPA, CTRadioAccessTechnologyCDMAEVDORev0,
             CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB,
             CTRadioAccessTechnologyeHRPD:
            return "3G"
        default:
            return "蜂窝"
        }
    }

    /// 运营商名字（蜂窝时用），拿不到返回 ""。
    static func carrierName() -> String {
        CTTelephonyNetworkInfo().serviceSubscriberCellularProviders?.values.first?.carrierName ?? ""
    }
}
