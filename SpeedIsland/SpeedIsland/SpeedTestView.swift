import SwiftUI

/// v3.14：测速页（全球网测风格）——主动测速。
/// 流程：Ping → 下载 → 上传；结果：下载 / 上传 / Ping 时延 / IP / 运营商 / 测速服务器。
/// 只在前台跑；蜂窝下开始前提示耗流量（测速会下载/上传几十 MB）。
/// 界面与主仪表盘同款深色风格，不用复杂表盘几何（表盘几何曾让编译器超时）。
struct SpeedTestView: View {
    @StateObject private var tester = SpeedTestEngine()
    @State private var showCellularAlert = false

    private static let accentHex = "#6FD8F0"

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // 标题
                Text("网络测速")
                    .font(.title2).bold()
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)

                Spacer()

                // 大数字：测速中显示实时速度，完成后显示下载结果
                VStack(spacing: 4) {
                    Text(tester.isRunning ? tester.phase.rawValue : (tester.phase == .done ? "测速完成" : "测速"))
                        .font(.caption)
                        .foregroundStyle(SpeedAppearance.color(hex: Self.accentHex))
                    Text(tester.isRunning ? tester.liveRateText : (tester.downloadMbps.map { String(format: "%.1f Mbps", $0) } ?? "—"))
                        .font(.system(size: min(geo.size.width * 0.17, 72), weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .contentTransition(.identity)
                        .animation(nil, value: tester.liveRateText)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    Text(tester.isRunning ? "当前速度" : (tester.phase == .done ? "下载速度" : "点开始测速"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 阶段进度条
                ProgressView(value: tester.progress)
                    .tint(SpeedAppearance.color(hex: Self.accentHex))
                    .padding(.top, 20)

                HStack(spacing: 0) {
                    phaseLabel("Ping", done: tester.pingAvgMs != nil, active: tester.phase == .ping)
                    Spacer()
                    phaseLabel("下载", done: tester.downloadMbps != nil, active: tester.phase == .download)
                    Spacer()
                    phaseLabel("上传", done: tester.uploadMbps != nil, active: tester.phase == .upload)
                    Spacer()
                    phaseLabel("完成", done: tester.phase == .done, active: false)
                }
                .font(.caption2)
                .padding(.top, 8)

                Spacer()

                // 结果卡片
                VStack(spacing: 10) {
                    resultRow("下载速度", value: tester.downloadMbps.map { String(format: "%.1f Mbps", $0) })
                    resultRow("上传速度", value: tester.uploadMbps.map { String(format: "%.1f Mbps", $0) })
                    resultRow("Ping 时延", value: pingText())
                    resultRow("IP 地址", value: tester.ip.isEmpty ? nil : tester.ip)
                    resultRow("运营商", value: tester.carrier.isEmpty ? nil : "\(tester.netType) · \(tester.carrier)")
                    resultRow("测速服务器", value: tester.serverName)
                }
                .font(.callout)
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Spacer()

                // 开始 / 取消
                Button(tester.isRunning ? "取消" : "开始测速") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if tester.isRunning {
                        tester.cancel()
                    } else {
                        // 蜂窝下先提示耗流量（测速会下载/上传几十 MB）
                        showCellularAlert = true
                    }
                }
                .font(.headline)
                .foregroundStyle(SpeedAppearance.color(hex: "#0B1026"))
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(SpeedAppearance.color(hex: Self.accentHex))
                .clipShape(Capsule())
                .buttonStyle(.plain)

                if let err = tester.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }

                Text("测速会消耗流量（下载/上传几十 MB），只在前台进行；延迟为 TCP 连接时间近似值，不是 ICMP Ping。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SpeedAppearance.color(hex: "#0B1026"))
            .alert("当前是蜂窝网络", isPresented: $showCellularAlert) {
                Button("开始测速", role: .destructive) { tester.start() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("测速会下载/上传几十 MB 流量，继续吗？")
            }
        }
    }

    private func pingText() -> String? {
        guard let avg = tester.pingAvgMs, let min = tester.pingMinMs else { return nil }
        return String(format: "平均 %.0f ms（最小 %.0f ms）", avg, min)
    }

    private func resultRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—").foregroundStyle(.white).bold()
        }
    }

    private func phaseLabel(_ text: String, done: Bool, active: Bool) -> some View {
        Text(text)
            .foregroundStyle(done ? SpeedAppearance.color(hex: Self.accentHex) : (active ? .white : .secondary))
            .bold(done || active)
    }
}
