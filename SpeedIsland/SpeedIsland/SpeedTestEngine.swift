import Foundation
import Network

/// v3.15：测速模块（全球网测风格）——主动测速，节点可选。
/// 节点（SpeedTestNode）：中科大（LibreSpeed，默认，国内线路优先）/ Cloudflare。
/// 流程：Ping → 下载 → 上传；结果：下载 / 上传 / Ping 时延 / 抖动 / 公网 IP / 运营商 / 测速服务器。
/// 只在前台跑；不弹窗（用户 2026-11-11：不要蜂窝提示弹窗，直接开始测）。
/// 注意：iOS 没有公开 ICMP Ping API，延迟用 TCP 连接建立时间（Cloudflare）
/// 或 empty.php 的 HTTP 往返时间（中科大）近似，不要谎称是 ICMP Ping。
///
/// Cloudflare 协议：Ping=TCP 连接 223.5.5.5:443（5 次取最小/平均）→
/// 下载（__down，200MB，10 秒取样）→ 上传（__up，50MB，10 秒取样）。
/// 下载/上传用 10 秒取样（不是下完整个文件）：够测出稳定速度，又不会拖太久；
/// 够 1MB 且满 2 秒才算有效，否则算失败。
///
/// 中科大（LibreSpeed）协议：照抄开源 CLI speedtest-cli-ustc。
/// 先建会话：GET 首页 → GET backend/pow.php 拿 challenge → 后台算 nonce
/// （SHA256，见 SpeedTestNode.USTCPow）→ POST backend/pow_verify.php →
/// GET backend/getIP.php 拿公网 IP。整个过程共用一个 URLSession，
/// Cookie 靠这个 session 自己的 HTTPCookieStorage 带着走。
/// 再 Ping（GET backend/empty.php，10 次取最小/平均 + 抖动）→
/// 下载（3 并发，各循环拉 backend/garbage.php?ckSize=4，10 秒取样，
/// 结果 ×1.06 补协议开销）→ 上传（3 并发，各循环 POST 1MB 到 backend/empty.php，
/// 10 秒取样，×1.06）。下载/上传都用 async/await + 共享字节计数器，
/// 0.5 秒取样一次推 live 速率，不用 delegate。
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

    /// 测速节点（中科大 / Cloudflare），选了就记住，下次还用这个。
    @Published var node: SpeedTestNode {
        didSet {
            UserDefaults.standard.set(node.id, forKey: Self.nodeKey)
            serverName = node.kind == .librespeed ? "\(node.name) · 合肥" : node.name
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

    private(set) var ip = ""
    private(set) var carrier = ""
    private(set) var netType = ""

    private var task: Task<Void, Never>?
    private var currentTask: URLSessionTask?
    private var cancelled = false

    // 下载取样（Cloudflare delegate 用）
    private var dlBytes: Int64 = 0
    private var dlStart = Date()
    private var dlLastBytes: Int64 = 0
    private var dlLastTime = Date()
    // 上传取样（Cloudflare delegate 用）
    private var ulBytes: Int64 = 0
    private var ulStart = Date()
    private var ulLastBytes: Int64 = 0
    private var ulLastTime = Date()

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.nodeKey) ?? SpeedTestNode.default.id
        let n = SpeedTestNode.by(id: saved)
        self.node = n
        self.serverName = n.kind == .librespeed ? "\(n.name) · 合肥" : n.name
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

    // MARK: - Run

    private func run() async {
        // 先判 Wi-Fi / 蜂窝，拿运营商；IP 尽量拿公网的（节点能给就给），拿不到再用本机 IP
        let wifi = await currentIsWiFi()
        let publicIP = await fetchPublicIP()
        await MainActor.run {
            self.ip = publicIP.isEmpty ? NetworkInfo.currentIP(isWiFi: wifi) : publicIP
            self.carrier = NetworkInfo.carrierName()
            self.netType = wifi ? "Wi-Fi" : NetworkInfo.radioAccess(isWiFi: wifi)
        }
        switch node.kind {
        case .cloudflare:
            await runCloudflare()
        case .librespeed:
            await runLibreSpeed()
        }
    }

    /// 公网 IP：中科大用 getIP.php；Cloudflare 用 cdn-cgi/trace 的 ip= 行。
    /// 拿不到就回 ""，调用方再用本机 IP 兜底。
    private func fetchPublicIP() async -> String {
        if node.kind == .librespeed {
            guard let url = URL(string: node.baseURL + "/backend/getIP.php?r=\(Double.random(in: 0..<1))") else { return "" }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let s = obj["processedString"] as? String, !s.isEmpty {
                    return s
                }
            } catch { }
            return ""
        }
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

    @MainActor
    private func fail(_ msg: String) {
        errorMessage = msg
        phase = .failed
        statusText = msg
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

    /// 抖动 = 相邻两次延迟差的绝对值的平均（和中科大 CLI 同款算法）。
    private func jitter(of samples: [Double]) -> Double {
        guard samples.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<samples.count { sum += abs(samples[i] - samples[i - 1]) }
        return sum / Double(samples.count - 1)
    }

    // MARK: - Cloudflare

    private func runCloudflare() async {
        // 1) Ping
        await MainActor.run { phase = .ping; statusText = "正在测延迟…" }
        let pings = await measurePing()
        guard !cancelled else { return }
        if pings.isEmpty {
            await fail("延迟测试失败：连不上测速服务器")
            return
        }
        let avg = pings.reduce(0, +) / Double(pings.count)
        let min = pings.min() ?? avg
        await MainActor.run {
            pingAvgMs = avg * 1000
            pingMinMs = min * 1000
            jitterMs = jitter(of: pings) * 1000
            progress = 0.2
        }

        // 2) Download
        await MainActor.run { phase = .download; statusText = "正在测下载速度…" }
        let dl = await measureDownload()
        guard !cancelled else { return }
        if let dl {
            await MainActor.run { downloadMbps = dl; progress = 0.6 }
        } else {
            await fail("下载测试失败")
            return
        }

        // 3) Upload
        await MainActor.run { phase = .upload; statusText = "正在测上传速度…" }
        let ul = await measureUpload()
        guard !cancelled else { return }
        if let ul {
            await MainActor.run {
                uploadMbps = ul
                progress = 1.0
                phase = .done
                statusText = "测速完成"
                isRunning = false
                liveRate = 0; liveRateText = "0 B/s"
            }
        } else {
            await fail("上传测试失败")
            return
        }
    }

    // MARK: - Ping (TCP connect, Cloudflare)

    private func measurePing() async -> [TimeInterval] {
        var results: [TimeInterval] = []
        for _ in 0..<5 {
            if cancelled { break }
            if let t = await tcpConnect(host: "223.5.5.5", port: 443, timeout: 3) {
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

    // MARK: - Download（Cloudflare，10 秒取样）

    private func measureDownload() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=200000000") else { return nil }
        dlBytes = 0; dlStart = Date(); dlLastBytes = 0; dlLastTime = Date()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        let sess = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let result: Double? = await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let task = sess.dataTask(with: url) { [weak self] _, _, _ in
                guard let self else { cont.resume(returning: nil); return }
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

    // MARK: - Upload（Cloudflare，10 秒取样）

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
            let task = sess.uploadTask(with: request, from: data) { [weak self] _, _, _ in
                guard let self else { cont.resume(returning: nil); return }
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

    // MARK: - 中科大（LibreSpeed）

    private func runLibreSpeed() async {
        let base = node.baseURL
        // 整个中科大测试共用一个 session + 一个 Cookie 罐：POW 会话就存在这里，
        // 后面的 empty/garbage 都靠这个 Cookie 才不回 500。
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        let sess = URLSession(configuration: config)

        // 预检：建会话 → POW → 拿公网 IP
        await MainActor.run { phase = .ping; statusText = "正在连接测速节点…" }
        do {
            _ = try await sess.data(from: URL(string: base + "/")!)
            try await completePow(session: sess, base: base)
            let publicIP = try await librePublicIP(session: sess, base: base)
            if !publicIP.isEmpty {
                await MainActor.run { self.ip = publicIP }
            }
        } catch {
            await fail("连不上测速节点（中科大），换个节点试试")
            return
        }
        guard !cancelled else { return }

        // 1) Ping：GET empty.php，10 次
        await MainActor.run { statusText = "正在测延迟…" }
        let pings = await measureLibrePing(session: sess, base: base)
        guard !cancelled else { return }
        if pings.isEmpty {
            await fail("延迟测试失败：连不上测速节点")
            return
        }
        let avg = pings.reduce(0, +) / Double(pings.count)
        let min = pings.min() ?? avg
        await MainActor.run {
            pingAvgMs = avg * 1000
            pingMinMs = min * 1000
            jitterMs = jitter(of: pings) * 1000
            progress = 0.2
        }

        // 2) Download：3 并发拉 garbage，10 秒取样
        await MainActor.run { phase = .download; statusText = "正在测下载速度…" }
        let dl = await measureLibreDownload(session: sess, base: base)
        guard !cancelled else { return }
        if let dl {
            await MainActor.run { downloadMbps = dl; progress = 0.6 }
        } else {
            await fail("下载测试失败")
            return
        }

        // 3) Upload：3 并发 POST 1MB 到 empty.php，10 秒取样
        await MainActor.run { phase = .upload; statusText = "正在测上传速度…" }
        let ul = await measureLibreUpload(session: sess, base: base)
        guard !cancelled else { return }
        if let ul {
            await MainActor.run {
                uploadMbps = ul
                progress = 1.0
                phase = .done
                statusText = "测速完成"
                isRunning = false
                liveRate = 0; liveRateText = "0 B/s"
            }
        } else {
            await fail("上传测试失败")
            return
        }
    }

    /// 中科大 POW：GET pow.php（404 = 不用 POW，直接过）→ 后台算 nonce →
    /// POST pow_verify.php。nonce 计算是纯 CPU 循环，放 Task.detached 跑，别堵主线程。
    private func completePow(session: URLSession, base: String) async throws {
        guard let url = URL(string: base + "/backend/pow.php") else { return }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 { return }
        guard http.statusCode == 200 else {
            throw NSError(domain: "SpeedTest", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "pow.php HTTP \(http.statusCode)"])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challenge = obj["challenge"] as? String,
              let difficulty = obj["difficulty"] as? Int,
              let token = obj["token"] as? String else {
            throw NSError(domain: "SpeedTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "pow.php 返回异常"])
        }
        guard let nonce = await Task.detached(priority: .userInitiated) {
            USTCPow.solve(challenge: challenge, difficulty: difficulty)
        }.value else {
            throw NSError(domain: "SpeedTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "POW 计算失败"])
        }
        guard let verifyURL = URL(string: base + "/backend/pow_verify.php") else { return }
        var request = URLRequest(url: verifyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "nonce": nonce])
        let (_, verifyResponse) = try await session.data(for: request)
        guard let verifyHTTP = verifyResponse as? HTTPURLResponse, verifyHTTP.statusCode == 200 else {
            throw NSError(domain: "SpeedTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "POW 验证失败"])
        }
    }

    private func librePublicIP(session: URLSession, base: String) async throws -> String {
        guard let url = URL(string: base + "/backend/getIP.php?r=\(Double.random(in: 0..<1))") else { return "" }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "" }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["processedString"] as? String {
            return s
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func measureLibrePing(session: URLSession, base: String) async -> [TimeInterval] {
        var results: [TimeInterval] = []
        for _ in 0..<10 {
            if cancelled { break }
            guard let url = URL(string: "\(base)/backend/empty.php?r=\(Double.random(in: 0..<1))") else { break }
            let start = Date()
            do {
                let (_, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                results.append(Date().timeIntervalSince(start))
            } catch { continue }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return results
    }

    private func measureLibreDownload(session: URLSession, base: String) async -> Double? {
        let seconds = 10.0
        let deadline = Date().addingTimeInterval(seconds)
        let start = Date()
        let counter = ByteCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    while !self.cancelled && Date() < deadline {
                        guard let url = URL(string: "\(base)/backend/garbage.php?r=\(Double.random(in: 0..<1))&ckSize=4") else { return }
                        do {
                            let (data, response) = try await session.data(from: url)
                            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                            await counter.add(Int64(data.count))
                        } catch { return }
                    }
                }
            }
            group.addTask {
                await self.sampleLiveRate(counter: counter, deadline: deadline)
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let total = await counter.total
        guard total >= 1_000_000 && elapsed >= 2 else { return nil }
        return Double(total) * 8 * 1.06 / elapsed / 1_000_000
    }

    private func measureLibreUpload(session: URLSession, base: String) async -> Double? {
        let seconds = 10.0
        let deadline = Date().addingTimeInterval(seconds)
        let start = Date()
        let counter = ByteCounter()
        var payload = Data(count: 1024 * 1024)
        payload.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            arc4random_buf(base, ptr.count)
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    while !self.cancelled && Date() < deadline {
                        guard let url = URL(string: "\(base)/backend/empty.php?r=\(Double.random(in: 0..<1))") else { return }
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        do {
                            let (_, response) = try await session.upload(for: request, from: payload)
                            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                            await counter.add(Int64(payload.count))
                        } catch { return }
                    }
                }
            }
            group.addTask {
                await self.sampleLiveRate(counter: counter, deadline: deadline)
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let total = await counter.total
        guard total >= 1_000_000 && elapsed >= 2 else { return nil }
        return Double(total) * 8 * 1.06 / elapsed / 1_000_000
    }

    /// 每 0.5 秒读一次共享字节计数器，推 live 速率（中科大下载/上传共用）。
    private func sampleLiveRate(counter: ByteCounter, deadline: Date) async {
        var lastBytes: Int64 = 0
        var lastTime = Date()
        while !cancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let total = await counter.total
            let now = Date()
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0 {
                let rate = Double(total - lastBytes) / dt
                lastBytes = total; lastTime = now
                await MainActor.run {
                    self.liveRate = rate
                    self.liveRateText = NetworkSpeedSampler.format(rate)
                }
            }
        }
    }

    // MARK: - URLSessionDataDelegate（Cloudflare 下载/上传的 live 速率）

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

/// 并发下载/上传共享的字节计数器（actor，线程安全）。
private actor ByteCounter {
    private(set) var total: Int64 = 0
    func add(_ n: Int64) { total += n }
}
