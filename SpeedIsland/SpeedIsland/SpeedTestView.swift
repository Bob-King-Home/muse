import SwiftUI

/// v3.17：测速页（全球网测风格）——多节点 + 推荐最快 + 失败自动换节点。
/// 流程：Ping → 下载 → 上传；结果：下载 / 上传 / Ping 时延 / 抖动 / 公网 IP / 运营商 / 测速服务器。
/// 只在前台跑；不弹窗（用户 2026-11-11：不要蜂窝提示弹窗，直接点开始就测）。
/// 界面：顶部节点选择（Cloudflare / Cachefly / 腾讯 CDN / 阿里 CDN，2 列网格，
/// 带延迟和“推荐”标记，选了就记住）
/// + 中央表盘（全球网测同款圆弧表盘：底圈 + 青色进度弧 + 中央大数字；不用刻度 ForEach，
/// 刻度几何曾让编译器超时）+ 阶段进度 + 结果卡片。
/// 表盘满格按 1000 Mbps 算，超过就顶满；中央数字测速中是实时速率，完成后是下载结果。
/// 完整性：单项失败不判整场失败（Ping/下载/上传哪项没测到，那行显示“—”，
/// 其余结果照常出）；下载失败自动按顺序换其他节点再试；三项全失败才算失败。
struct SpeedTestView: View {
    @StateObject private var tester = SpeedTestEngine()

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

                // 测速节点：进页自动测一遍延迟，延迟最低的标“推荐”
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("测速节点")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button(tester.measuringNodes ? "测节点中…" : "重新测节点") {
                            tester.measureNodes()
                        }
                        .font(.caption)
                        .foregroundStyle(SpeedAppearance.color(hex: Self.accentHex))
                        .disabled(tester.isRunning || tester.measuringNodes)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(SpeedTestNode.all) { n in
                            nodeButton(n)
                        }
                    }
                }
                .padding(.top, 14)
                .onChange(of: tester.node) { _, _ in tester.resetResults() }
                .onAppear { tester.measureNodes() }

                Spacer()

                // 中央表盘（全球网测风格）
                SpeedDialView(
                    progress: dialProgress,
                    numberText: dialNumber,
                    unitText: dialUnit,
                    phaseText: tester.isRunning ? tester.phase.rawValue : (tester.phase == .done ? "测速完成" : "测速"),
                    size: min(geo.size.width * 0.16, 64)
                )
                .frame(width: min(geo.size.width * 0.72, 280), height: min(geo.size.width * 0.72, 280))

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
                    resultRow("抖动", value: tester.jitterMs.map { String(format: "%.1f ms", $0) })
                    resultRow("IP 地址", value: tester.ip.isEmpty ? nil : tester.ip)
                    resultRow("运营商", value: tester.carrier.isEmpty ? nil : "\(tester.netType) · \(tester.carrier)")
                    resultRow("测速服务器", value: tester.serverName)
                }
                .font(.callout)
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Spacer()

                // 开始 / 取消（不弹窗，直接开始）
                Button(tester.isRunning ? "取消" : "开始测速") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if tester.isRunning {
                        tester.cancel()
                    } else {
                        tester.start()
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

                Text("测速会消耗流量（下载/上传几十 MB），只在前台进行；延迟为连接时间近似值，不是 ICMP Ping。下载失败会自动换其他节点再试。")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SpeedAppearance.color(hex: "#0B1026"))
        }
    }

    /// 节点按钮：名字 + 位置 + 延迟；延迟最低的标“推荐”；选中态青色边框。
    /// 测速中不能换节点。
    private func nodeButton(_ n: SpeedTestNode) -> some View {
        let selected = tester.node.id == n.id
        let recommended = tester.recommendedNode?.id == n.id
        let latency = tester.nodeLatencyMs[n.id]
        return Button {
            guard !tester.isRunning else { return }
            tester.node = n
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(n.name)
                        .font(.subheadline).bold()
                        .foregroundStyle(.white)
                    if recommended {
                        Text("推荐")
                            .font(.caption2).bold()
                            .foregroundStyle(SpeedAppearance.color(hex: "#0B1026"))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(SpeedAppearance.color(hex: Self.accentHex))
                            .clipShape(Capsule())
                    }
                }
                Text(n.location)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Text(latency.map { String(format: "延迟 %.0f ms", $0) } ?? (tester.measuringNodes ? "测延迟中…" : "延迟未测到"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(selected ? SpeedAppearance.color(hex: Self.accentHex).opacity(0.18) : Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? SpeedAppearance.color(hex: Self.accentHex) : Color.white.opacity(0.15), lineWidth: selected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(tester.isRunning)
    }

    /// 表盘进度：测速中按实时速率（Mbps）/ 1000；完成后按下载结果 / 1000；平时 0。
    private var dialProgress: Double {
        if tester.isRunning {
            let mbps = tester.liveRate * 8 / 1_000_000
            return min(max(mbps / 1000, 0), 1)
        }
        if let dl = tester.downloadMbps {
            return min(max(dl / 1000, 0), 1)
        }
        return 0
    }

    /// 表盘中央数字：测速中是实时速率，完成后是下载结果，平时是 "—"。
    private var dialSpeedText: String {
        if tester.isRunning { return tester.liveRateText }
        if let dl = tester.downloadMbps { return String(format: "%.1f Mbps", dl) }
        return "—"
    }

    private var dialNumber: String {
        let parts = dialSpeedText.split(separator: " ")
        return parts.first.map(String.init) ?? dialSpeedText
    }

    private var dialUnit: String {
        let parts = dialSpeedText.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : ""
    }

    private func pingText() -> String? {
        guard let avg = tester.pingAvgMs, let min = tester.pingMinMs else { return nil }
        return String(format: "平均 %.0f ms（最小 %.0f ms）", avg, min)
    }

    private func resultRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(value ?? "—").foregroundStyle(.white).bold()
        }
    }

    private func phaseLabel(_ text: String, done: Bool, active: Bool) -> some View {
        Text(text)
            .foregroundStyle(done ? SpeedAppearance.color(hex: Self.accentHex) : (active ? .white : .white.opacity(0.55)))
            .bold(done || active)
    }
}

/// 中央表盘（全球网测风格）：底圈 + 青色进度弧 + 中央大数字。
/// 只有两个 Circle().trim()，没有刻度 ForEach / 三角函数，不会触发编译器超时。
/// 圆弧是 270°（trim 0→0.75），转 135° 后缺口朝下，和仪表盘一样。
private struct SpeedDialView: View {
    var progress: Double
    var numberText: String
    var unitText: String
    var phaseText: String
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(Color.white.opacity(0.12), lineWidth: 14)
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0.0, to: 0.75 * max(progress, 0.001))
                .stroke(SpeedAppearance.color(hex: "#6FD8F0"), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
            VStack(spacing: 2) {
                Text(phaseText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(numberText)
                        .font(.system(size: size, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .contentTransition(.identity)
                        .animation(nil, value: numberText)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    if !unitText.isEmpty {
                        Text(unitText)
                            .font(.system(size: max(size * 0.32, 11), weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
        }
    }
}
