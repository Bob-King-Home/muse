import Foundation
import CryptoKit

/// v3.15：测速节点。两种协议：
/// - Cloudflare：原有协议（__down/__up，TCP Ping 到 223.5.5.5:443）。
/// - LibreSpeed：中科大 test.ustc.edu.cn（empty.php / garbage.php）。
///   测前要过一道 Proof of Work（见 USTCPow），不然 empty/garbage 直接回 500。
///   做法照抄开源 CLI speedtest-cli-ustc（Exynos-8890/speedtest-cli-ustc）：
///   先 GET 首页建会话 → GET backend/pow.php 拿 challenge → 算 nonce →
///   POST backend/pow_verify.php → 再 GET backend/getIP.php 拿公网 IP。
/// 节点存在 UserDefaults（si_speedtest_node），默认中科大（国内线路优先，
/// Cloudflare 在部分公司网/校园网下不通，截图里下载就是这么失败的）。
/// speedtest.im / 全球网测用的是自家/ Ookla 的闭源节点，没有公开接口可直接调，
/// 所以节点选择照它们的思路做（可换节点、默认记住），节点本身用公开的 USTC + Cloudflare。
enum SpeedTestNodeKind: String {
    case cloudflare
    case librespeed
}

struct SpeedTestNode: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let location: String
    let kind: SpeedTestNodeKind
    let baseURL: String

    static let ustc = SpeedTestNode(
        id: "ustc",
        name: "中科大",
        location: "合肥 · 教育网",
        kind: .librespeed,
        baseURL: "https://test.ustc.edu.cn"
    )
    static let cloudflare = SpeedTestNode(
        id: "cloudflare",
        name: "Cloudflare",
        location: "全球 · 自动",
        kind: .cloudflare,
        baseURL: "https://speed.cloudflare.com"
    )

    static let all: [SpeedTestNode] = [.ustc, .cloudflare]
    static let `default` = ustc

    static func by(id: String) -> SpeedTestNode {
        all.first { $0.id == id } ?? .default
    }
}

/// USTC 测速站的 Proof of Work（照抄 CLI 的算法，见上面注释）。
/// GET backend/pow.php 返回 {"challenge": "...", "difficulty": N, "token": "..."}。
/// 找一个 nonce（十进制字符串），使 SHA256(challenge + nonce) 的 hex 以
/// ceil(difficulty/4) 个 0 开头；再 POST {"token": token, "nonce": nonce}
/// 到 backend/pow_verify.php，服务器认下这个会话（靠 Cookie）。
/// 注意：这里按 hex 前缀比，不是按 bit 数比 —— difficulty=18 也要 5 个 hex 0
/// （20 bit），和 CLI 的 hexdigest().startswith("0" * ceil(difficulty/4)) 完全一致。
/// 纯 CPU 循环，调用方务必放后台线程（Task.detached），别堵主线程。
enum USTCPow {
    static func solve(challenge: String, difficulty: Int, maxNonce: Int = 100_000_000) -> String? {
        let zeroHexChars = (difficulty + 3) / 4
        let zeroBits = zeroHexChars * 4
        let fullBytes = zeroBits / 8
        let remBits = zeroBits % 8
        var nonce = 0
        while nonce < maxNonce {
            let payload = Data((challenge + String(nonce)).utf8)
            // SHA256Digest 不支持下标，先转 Data 再按字节比
            let digest = Data(SHA256.hash(data: payload))
            var ok = true
            for i in 0..<fullBytes where digest[i] != 0 {
                ok = false
                break
            }
            if ok, remBits > 0 {
                let mask = UInt8(0xFF) << (8 - remBits)
                if digest[fullBytes] & mask != 0 { ok = false }
            }
            if ok { return String(nonce) }
            nonce += 1
        }
        return nil
    }
}
