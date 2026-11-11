import Foundation
import Network

/// v3.14：测速模块（全球网测风格）——主动测速。
/// 流程：Ping（TCP 连接 223.5.5.5:443 阿里 DNS，5 次取最小/平均）
/// → 下载（Cloudflare __down，200MB，10 秒取样）→ 上传（Cloudflare __up，50MB，10 秒取样）。
/// 只在前台跑；蜂窝下开始前由 UI 提示耗流量。
/// 注意：iOS 没有公开 ICMP Ping API，延迟用 TCP 连接建立时间近似，不要谎称是 ICMP Ping。
/// 测速服务器：Cloudflare（speed.cloudflare.com），结果里会写明服务器名。
/// 下载/上传用 10 秒取样（不是下完整个文件）：够测出稳定速度，又不会拖太久；
/// 够 1MB 且满 2 秒才算有效，否则算失败。
final class SpeedTestEngine: NSObject, ObservableObject, URLSessionDataDelegate {
    enum Phase: String {
        case idle = "待测速"
        case ping = "测延迟…"
        case download = "测下载…"
        case upload = "测上传…"
        case done = "完成"
        case failed = "失败"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveRate: Double = 0
    @Published private(set) var liveRateText = "0 B/s"
    @Published private(set) var pingAvgMs: Double?
    @Published private(set) var pingMinMs: Double?
    @Published private(set) var downloadMbps: Double?
    @Published private(set) var uploadMbps: Double?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    let serverName = "Cloudflare"
    private(set) var ip = ""
    private(set) var carrier = ""
    private(set) var netType = ""

    private var task: Task<Void, Never>?
    private var currentTask: URLSessionTask?
    private var cancelled = false

    // 下载取样
    private var dlBytes: Int64 = 0
    private var dlStart = Date()
    private var dlLastBytes: Int64 = 0
    private var dlLastTime = Date()
    // 上传取样
    private var ulBytes: Int64 = 0
    private var ulStart = Date()
    private var ulLastBytes: Int64 = 0
    private var ulLastTime = Date()

    // MARK: - Public

    @MainActor
    func start() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        pingAvgMs = nil; pingMinMs = nil; downloadMbps = nil; uploadMbps = nil
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

    // MARK: - Run

    private func run() async {
        // 先判 Wi-Fi / 蜂窝，拿 IP 与运营商
        let wifi = await currentIsWiFi()
        await MainActor.run {
            self.ip = NetworkInfo.currentIP(isWiFi: wifi)
            self.carrier = NetworkInfo.carrierName()
            self.netType = wifi ? "Wi-Fi" : NetworkInfo.radioAccess(isWiFi: wifi)
        }

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

    // MARK: - Ping (TCP connect)

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

    // MARK: - Download（10 秒取样）

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

    // MARK: - Upload（10 秒取样）

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

    // MARK: - URLSessionDataDelegate

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
