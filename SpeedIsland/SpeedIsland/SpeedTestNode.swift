import Foundation

/// v3.16：测速节点（全球网测风格 —— 多节点 + 推荐最快节点）。
/// 中科大已去掉（用户 2026-11-11：没必要中科大；它在公司网下预检就连不上）。
/// 两个节点都是 HTTPS 直连，不用 POW、不用 SDK、不用登录：
/// - Cloudflare：speed.cloudflare.com（__down/__up，全球 CDN）。
///   Ping = TCP 连接 223.5.5.5:443（阿里 DNS，5 次取最小/平均）。
/// - Cachefly：cachefly.cachefly.net（10mb.test / 100mb.test，全球 CDN）。
///   Ping = TCP 连接到 cachefly.cachefly.net:443。
///   上传没有公开端点，所以两个节点的上传都走 Cloudflare 的 __up
///   （上传只是往服务器发数据、测发送速率，用谁的端点不影响结果）。
/// 节点存在 UserDefaults（si_speedtest_node），默认 Cloudflare。
/// “推荐最快节点”：进测速页时对两个节点各测一次延迟（TCP 连接），
/// 延迟最低的那个标“推荐”；用户也可以手动换节点，换了就记住。
/// speedtest.im / 全球网测用的是 Ookla 的闭源服务器群，没有公开接口可直接调，
/// 所以这里用公开的 Cloudflare + Cachefly 两个 CDN 节点，思路和它们一样
/// （多节点可选、按延迟推荐最快）。
enum SpeedTestNodeKind: String {
    case cloudflare
    case cachefly
}

struct SpeedTestNode: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let location: String
    let kind: SpeedTestNodeKind
    /// 测延迟用的主机（TCP 连接到它的 443 端口）。
    let pingHost: String
    /// 下载地址（单文件，够大，10 秒取样不会下完）。
    let downloadURL: String

    static let cloudflare = SpeedTestNode(
        id: "cloudflare",
        name: "Cloudflare",
        location: "全球 · 自动",
        kind: .cloudflare,
        pingHost: "223.5.5.5",
        downloadURL: "https://speed.cloudflare.com/__down?bytes=200000000"
    )
    static let cachefly = SpeedTestNode(
        id: "cachefly",
        name: "Cachefly",
        location: "全球 · CDN",
        kind: .cachefly,
        pingHost: "cachefly.cachefly.net",
        downloadURL: "https://cachefly.cachefly.net/100mb.test"
    )

    static let all: [SpeedTestNode] = [.cloudflare, .cachefly]
    static let `default` = cloudflare

    static func by(id: String) -> SpeedTestNode {
        all.first { $0.id == id } ?? .default
    }
}
