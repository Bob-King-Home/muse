import Foundation
import Network

/// v3.16：测速模块（全球网测风格）——多节点 + 推荐最快 + 失败自动换节点。
/// 节点（SpeedTestNode）：Cloudflare / Cachefly，都是 HTTPS 直连。
/// 中科大已去掉（用户 2026-11-11：没必要中科大；它在公司网下预检就连不上）。
/// 流程：Ping → 下载 → 上传；结果：下载 / 上传 / Ping 时延 / 抖动 / 公网 IP / 运营商 / 测速服务器。
/// 只在前台跑；不弹窗（用户 2026-11-11：不要蜂窝提示弹窗，直接开始测）。
/// 注意：iOS 没有公开 ICMP Ping API，延迟用 TCP 连接建立时间近似，不要谎称是 ICMP Ping。
///
/// 完整性（用户 2026-11-11：不要半成品，问题和可能出现的结果要想清楚并处理掉）：
/// - 延迟测不到：不判整场失败，Ping 显示“—”，继续测下载/上传。
/// - 下载失败：自动换另一个节点再试一次；两个都失败才判下载失败，
///   但整场不失败 —— Ping 和上传的结果照常出，不让用户白等一场。
/// - 上传失败：同理，下载和 Ping 的结果照常出。
/// - 只有 Ping、下载、上传三项全失败，才算整场失败。
/// - 测一半切后台 / 点取消：任务取消干净，不残留、不报错。
/// - 换节点：测速进行中不让换（Picker 已禁用），换节点清掉旧结果。
///
/// 下载/上传用 10 秒取样（不是下完整个文件）：够测出稳定速度，又不会拖太久；
/// 够 1MB 且满 2 秒才算有效，否则算该项失败。
/// 上传两个节点都走 Cloudflare 的 __up（Cachefly 没有公开上传端点；
/// 上传只是往服务器发数据、测发送速率，用谁的端点不影响结果）。
final class SpeedTestEngine: NSObject, ObservableObject, URLSessionDataDelegate {
    enum Phase: String {
        case idle = "待测速"
        case ping = "测延迟…"
        case download = "测下载…"
        case upload = "测上传…"
        case done = "完成"
        case failed = "失败"
    }

    static let nodeKey = "si_speedtest_node"

    /// 测速节点（Cloudflare / Cachefly），选了就记住，下次还用这个。
    @Published var node: SpeedTestNode {
        didSet {
            UserDefaults.standard.set(node.id, forKey: Self.nodeKey)
            serverName = node.name
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveRate: Double = 0
    @Published private(set) var liveRateText = "0 B/s"
    @Published private(set) var pingAvgMs: Double?
    @Published private(set) var pingMinMs: Double?
    @Published private(set) var jitterMs: Double?
    @Published private(set) var downloadMbps: Double?
    @Published private(set) var uploadMbps: Double?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var serverName: String
    /// 各节点的延迟（毫秒），进测速页时测一次，用来标“推荐最快”。
    /// 没测到的节点不在字典里。
    @Published private(set) var nodeLatencyMs: [String: Double] = [:]
    @Published private(set) var measuringNodes = false

    private(set) var ip = ""
    private(set) var carrier = ""
    private(set) var netType = ""

    private var task: Task<Void, Never>?
    private var currentTask: URLSessionTask?
    private var cancelled = false

    // 下载取样（delegate 用）
    private var dlBytes: Int64 = 0
    private var dlStart = Date()
    private var dlLastBytes: Int64 = 0
    private var dlLastTime = Date()
    // 上传取样（delegate 用）
    private var ulBytes: Int64 = 0
    private var ulStart = Date()
    private var ulLastBytes: Int64 = 0
    private var ulLastTime = Date()

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.nodeKey) ?? SpeedTestNode.default.id
        let n = SpeedTestNode.by(id: saved)
        self.node = n
        self.serverName = n.name
        super.init()
    }

    // MARK: - Public

    @MainActor
    func start() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        pingAvgMs = nil; pingMinMs = nil; jitterMs = nil; downloadMbps = nil; uploadMbps = nil
        liveRate = 0; liveRateText = "0 B/s"; progress = 0
        ip = ""; carrier = ""; netType = ""
        cancelled = false
        task = Task { await run() }
    }

    @MainActor
    func cancel() {
        cancelled = true
        task?.cancel()
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        phase = .idle
        statusText = "已取消"
        liveRate = 0; liveRateText = "0 B/s"
    }

    /// 换节点时清掉上一个节点的结果，免得旧数字还挂在新节点名下。
    @MainActor
    func resetResults() {
        guard !isRunning else { return }
        pingAvgMs = nil; pingMinMs = nil; jitterMs = nil; downloadMbps = nil; uploadMbps = nil
        errorMessage = nil
        phase = .idle
        progress = 0
        statusText = ""
        liveRate = 0; liveRateText = "0 B/s"
    }

    /// 测一遍所有节点的延迟，用来推荐最快节点。
    /// 进测速页时调一次；用户点“重新测节点”也能调。
    /// 测速进行中不测（别抢带宽）。
    @MainActor
    func measureNodes() {
        guard !isRunning && !measuringNodes else { return }
        measuringNodes = true
        Task {
            var result: [String: Double] = [:]
            for n in SpeedTestNode.all {
                if Task.isCancelled { break }
                if let t = await tcpConnect(host: n.pingHost, port: 443, timeout: 3) {
                    result[n.id] = t * 1000
                }
            }
            await MainActor.run {
                self.nodeLatencyMs = result
                self.measuringNodes = false
            }
        }
    }

    /// 延迟最低的节点（都测不到时回 nil）。UI 上给它标“推荐”。
    var recommendedNode: SpeedTestNode? {
        guard !nodeLatencyMs.isEmpty else { return nil }
        return SpeedTestNode.all
            .filter { nodeLatencyMs[$0.id] != nil }
            .min { (nodeLatencyMs[$0.id] ?? .infinity) < (nodeLatencyMs[$1.id] ?? .infinity) }
    }

    // MARK: - Run

    private func run() async {
        // 先判 Wi-Fi / 蜂窝，拿运营商；IP 尽量拿公网的，拿不到再用本机 IP
        let wifi = await currentIsWiFi()
        let publicIP = await fetchPublicIP()
        await MainActor.run {
            self.ip = publicIP.isEmpty ? NetworkInfo.currentIP(isWiFi: wifi) : publicIP
            self.carrier = NetworkInfo.carrierName()
            self.netType = wifi ? "Wi-Fi" : NetworkInfo.radioAccess(isWiFi: wifi)
        }
        await runTest()
    }

    /// 公网 IP：Cloudflare 的 cdn-cgi/trace 里有 ip= 行。拿不到就回 ""，调用方用本机 IP 兜底。
    private func fetchPublicIP() async -> String {
        guard let url = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace") else { return "" }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                if line.hasPrefix("ip=") { return String(line.dropFirst(3)) }
            }
        } catch { }
        return ""
    }

    /// 整场只有三项全失败才算失败；否则出部分结果、phase = .done。
    @MainActor
    private func finish() {
        let allFailed = pingAvgMs == nil && downloadMbps == nil && uploadMbps == nil
        if allFailed {
            errorMessage = "测速失败：三个节点都连不上，换个网络再试试"
            phase = .failed
            statusText = "测速失败"
        } else {
            phase = .done
            var parts: [String] = []
            if pingAvgMs == nil { parts.append("延迟没测到") }
            if downloadMbps == nil { parts.append("下载没测到") }
            if uploadMbps == nil { parts.append("上传没测到") }
            statusText = parts.isEmpty ? "测速完成" : "测速完成（\(parts.joined(separator: "、")）"
        }
        progress = 1.0
        isRunning = false
        liveRate = 0; liveRateText = "0 B/s"
    }

    private func currentIsWiFi() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                cont.resume(returning: path.usesInterfaceType(.wifi))
            }
            monitor.start(queue: .global())
        }
    }

    /// 抖动 = 相邻两次延迟差的绝对值的平均。
    private func jitter(of samples: [Double]) -> Double {
        guard samples.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<samples.count { sum += abs(samples[i] - samples[i - 1]) }
        return sum / Double(samples.count - 1)
    }

    // MARK: - Test flow

    private func runTest() async {
        // 1) Ping：测不到不判失败，继续往下测
        await MainActor.run { phase = .ping; statusText = "正在测延迟…" }
        let pings = await measurePing()
        guard !cancelled else { return }
        if !pings.isEmpty {
            let avg = pings.reduce(0, +) / Double(pings.count)
            let min = pings.min() ?? avg
            await MainActor.run {
                pingAvgMs = avg * 1000
                pingMinMs = min * 1000
                jitterMs = jitter(of: pings) * 1000
                progress = 0.2
            }
        }

        // 2) Download：先测选中的节点，失败自动换另一个节点再试
        await MainActor.run { phase = .download; statusText = "正在测下载速度…" }
        var dl: Double? = await measureDownload(node: node)
        if dl == nil && !cancelled {
            let fallback = SpeedTestNode.all.first { $0.id != node.id }
            if let fallback {
                await MainActor.run { statusText = "当前节点下载失败，换 \(fallback.name) 再试…" }
                dl = await measureDownload(node: fallback)
                if dl != nil {
                    await MainActor.run { serverName = "\(node.name) → \(fallback.name)" }
                }
            }
        }
        guard !cancelled else { return }
        if let dl {
            await MainActor.run { downloadMbps = dl; progress = 0.6 }
        }

        // 3) Upload：走 Cloudflare 的 __up（Cachefly 没有上传端点）
        await MainActor.run { phase = .upload; statusText = "正在测上传速度…" }
        let ul = await measureUpload()
        guard !cancelled else { return }
        if let ul {
            await MainActor.run { uploadMbps = ul }
        }

        await MainActor.run { finish() }
    }

    // MARK: - Ping (TCP connect)

    /// 对选中节点的 pingHost 做 5 次 TCP 连接，取回延迟列表（秒）。
    /// 测不到回空数组 —— 调用方不判失败，Ping 那行显示“—”。
    private func measurePing() async -> [TimeInterval] {
        var results: [TimeInterval] = []
        for _ in 0..<5 {
            if cancelled { break }
            if let t = await tcpConnect(host: node.pingHost, port: 443, timeout: 3) {
                results.append(t)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return results
    }

    private func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) async -> TimeInterval? {
        await withCheckedContinuation { (cont: CheckedContinuation<TimeInterval?, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ v: TimeInterval?) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(returning: v)
            }
            let params = NWParameters.tcp
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
            let start = Date()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let t = Date().timeIntervalSince(start)
                    conn.cancel()
                    finish(t)
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                conn.cancel()
                finish(nil)
            }
        }
    }

    // MARK: - Download（10 秒取样，单流）

    private func measureDownload(node: SpeedTestNode) async -> Double? {
        guard let url = URL(string: node.downloadURL) else { return nil }
        dlBytes = 0; dlStart = Date(); dlLastBytes = 0; dlLastTime = Date()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        let sess = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let result: Double? = await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let task = sess.dataTask(with: url) { [weak self] _, response, error in
                guard let self else { cont.resume(returning: nil); return }
                // HTTP 状态不是 200 也算失败（比如节点回了错误页）
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    cont.resume(returning: nil)
                    return
                }
                if error != nil && self.dlBytes == 0 {
                    cont.resume(returning: nil)
                    return
                }
                let elapsed = Date().timeIntervalSince(self.dlStart)
                let bytes = Double(self.dlBytes)
                // 够 1MB 且满 2 秒才算有效（建连失败 / 秒断不算数）
                if bytes >= 1_000_000 && elapsed >= 2 {
                    cont.resume(returning: bytes / elapsed * 8 / 1_000_000)
                } else {
                    cont.resume(returning: nil)
                }
            }
            self.currentTask = task
            task.resume()
            // 10 秒后停：够测出稳定速度，又不会拖太久
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                task.cancel()
            }
        }
        currentTask = nil
        return result
    }

    // MARK: - Upload（Cloudflare __up，10 秒取样）

    private func measureUpload() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        var data = Data(count: 50 * 1024 * 1024)
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            arc4random_buf(base, ptr.count)
        }
        ulBytes = 0; ulStart = Date(); ulLastBytes = 0; ulLastTime = Date()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let sess = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let result: Double? = await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let task = sess.uploadTask(with: request, from: data) { [weak self] _, response, error in
                guard let self else { cont.resume(returning: nil); return }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    cont.resume(returning: nil)
                    return
                }
                if error != nil && self.ulBytes == 0 {
                    cont.resume(returning: nil)
                    return
                }
                let elapsed = Date().timeIntervalSince(self.ulStart)
                let bytes = Double(self.ulBytes)
                if bytes >= 1_000_000 && elapsed >= 2 {
                    cont.resume(returning: bytes / elapsed * 8 / 1_000_000)
                } else {
                    cont.resume(returning: nil)
                }
            }
            self.currentTask = task
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                task.cancel()
            }
        }
        currentTask = nil
        return result
    }

    // MARK: - URLSessionDataDelegate（下载/上传的 live 速率）

    /// 下载时数 live 速率（每 0.5 秒刷新一次主界面数字）
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dlBytes += Int64(data.count)
        let now = Date()
        let dt = now.timeIntervalSince(dlLastTime)
        if dt >= 0.5 {
            let bytes = dlBytes - dlLastBytes
            let rate = dt > 0 ? Double(bytes) / dt : 0
            dlLastBytes = dlBytes; dlLastTime = now
            Task { @MainActor in
                self.liveRate = rate
                self.liveRateText = NetworkSpeedSampler.format(rate)
            }
        }
    }

    /// 上传时数 live 速率
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        ulBytes = totalBytesSent
        let now = Date()
        let dt = now.timeIntervalSince(ulLastTime)
        if dt >= 0.5 {
            let bytes = totalBytesSent - ulLastBytes
            let rate = dt > 0 ? Double(bytes) / dt : 0
            ulLastBytes = totalBytesSent; ulLastTime = now
            Task { @MainActor in
                self.liveRate = rate
                self.liveRateText = NetworkSpeedSampler.format(rate)
            }
        }
    }
}
