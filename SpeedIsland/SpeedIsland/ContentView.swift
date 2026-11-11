import SwiftUI

// v3.5：按市面测速 App（Speedtest / 全球网测）的做法重做 ——
// 表盘仪表 hero + 大号加粗数字（数字和单位分开渲染，单位小一号）+ 双线曲线 +
// 网络信息卡（Wi-Fi 名 / 5G / IP）；外观设置放右上角齿轮弹窗，不再藏在底部折叠里。
// 性能：大数字去掉阴影（每秒重绘的阴影是卡顿主因之一）；数字按屏宽算，18 Pro Max 适配。
// 黑边：Info.plist 加了 UILaunchScreen（深色启动底），根视图背景忽略安全区。
struct ContentView: View {
    @StateObject private var engine = SpeedEngine()
    @ObservedObject private var manager = LiveActivityManager.shared
    @ObservedObject private var keepAlive = LocationKeepAlive.shared

    @AppStorage(SpeedAppearance.fontColorKey) private var fontColorHex = SpeedAppearance.defaultFontColor
    @AppStorage(SpeedAppearance.fontSizeKey) private var fontSizeLevel = SpeedAppearance.defaultFontSize
    @AppStorage(SpeedAppearance.backgroundKey) private var backgroundHex = SpeedAppearance.defaultBackground
    @State private var showAppearance = false

    private static let accentHex = "#6FD8F0"
    private static let upHex = "#4ADE80"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SpeedAppearance.color(hex: backgroundHex).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    // 顶栏：标题 + 齿轮（外观设置入口放这里，一眼能看到）
                    HStack {
                        Text("网络测速")
                            .font(.title2).bold()
                            .foregroundStyle(SpeedAppearance.color(hex: fontColorHex))
                        Spacer()
                        Button { showAppearance = true } label: {
                            Image(systemName: "gearshape")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("外观设置")
                    }
                    .padding(.top, 6)

                    // 表盘 hero：当前下载速度
                    SpeedDialView(downBytesPerSec: engine.downBytesPerSec, downText: engine.downText, fontColorHex: fontColorHex)
                        .frame(height: dialHeight(height: geo.size.height))
                        .padding(.top, 8)

                    // 上传 + 网络 两张卡
                    HStack(spacing: 12) {
                        infoCard(label: "上传") {
                            SpeedNumberText(text: engine.upText, size: uploadSize(width: geo.size.width), fontColorHex: fontColorHex)
                        }
                        infoCard(label: "网络") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(engine.netType)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(SpeedAppearance.color(hex: fontColorHex))
                                Text(networkDetail)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 14)

                    // 双线曲线
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) {
                            legendDot(hex: Self.accentHex, text: "下载")
                            legendDot(hex: Self.upHex, text: "上传")
                            Spacer()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        DualSpeedGraphView(down: engine.downHistory, up: engine.upHistory)
                            .frame(height: graphHeight(height: geo.size.height))
                    }
                    .padding(.top, 16)

                    Spacer()

                    Button(engine.isRunning ? "停止" : "开始") {
                        engine.isRunning ? engine.stop() : engine.start()
                    }
                    .font(.headline)
                    .foregroundStyle(SpeedAppearance.color(hex: "#0B1026"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(SpeedAppearance.color(hex: Self.accentHex))
                    .clipShape(Capsule())
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(manager.isActive ? "运行中 · \(engine.intervalText)刷新" : "已停止")
                        Text(keepAlive.statusText)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 14)

                    if let err = engine.errorMessage ?? manager.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }

                    Text("开始后定位保活让 App 在后台持续运行，灵动岛每秒刷新；状态栏会显示定位箭头。点停止后保活结束，箭头消失。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
        }
        .onAppear { engine.restoreIfNeeded() }
        .sheet(isPresented: $showAppearance) {
            AppearanceSheetView(fontColorHex: $fontColorHex, fontSizeLevel: $fontSizeLevel, backgroundHex: $backgroundHex) {
                engine.refreshAppearance()
            }
        }
    }

    private var networkDetail: String {
        let ipPart = engine.ip
        if engine.isWiFi {
            let name = engine.ssid.isEmpty ? "Wi-Fi" : engine.ssid
            return ipPart.isEmpty ? name : "\(name) · \(ipPart)"
        } else {
            let c = engine.carrier.isEmpty ? engine.netType : engine.carrier
            return ipPart.isEmpty ? c : "\(c) · \(ipPart)"
        }
    }

    private func legendDot(hex: String, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(SpeedAppearance.color(hex: hex)).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private func infoCard<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // 18 Pro Max 宽 440pt：表盘数字约宽度的 18%，上传卡数字约 10%，再乘字号档系数；
    // minimumScaleFactor 兜底，再长的数字也不会溢出。
    private func dialHeight(height: CGFloat) -> CGFloat {
        min(max(height * 0.24, 190), 230)
    }
    private func uploadSize(width: CGFloat) -> CGFloat {
        width * 0.10 * [0.85, 1.0, 1.15][SpeedAppearance.clamped(fontSizeLevel)]
    }
    private func graphHeight(height: CGFloat) -> CGFloat {
        min(max(height * 0.13, 96), 130)
    }
}

/// 大号加粗网速数字：数字和单位分开渲染，单位小一号，数字用 .black 字重。
/// 不加阴影（每秒重绘的阴影是卡顿主因之一）。
private struct SpeedNumberText: View {
    var text: String
    var size: CGFloat
    var fontColorHex: String

    var body: some View {
        let parts = text.split(separator: " ")
        let digits = parts.first.map(String.init) ?? text
        let unit = parts.count > 1 ? String(parts[1]) : ""
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(digits)
                .font(.system(size: size, weight: .black, design: .monospaced))
                .foregroundStyle(SpeedAppearance.color(hex: fontColorHex))
            Text(unit)
                .font(.system(size: max(size * 0.32, 11), weight: .semibold, design: .monospaced))
                .foregroundStyle(SpeedAppearance.color(hex: fontColorHex).opacity(0.75))
        }
        .contentTransition(.identity)
        .animation(nil, value: text)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// 表盘：半圆仪表，刻度按对数排（0/5/10/20/50/100/200/500/1G/2G/5G，和市面测速 App 一样），
/// 指针 + 青色进度弧显示当前下载速度，中间是大号加粗数字。
private struct SpeedDialView: View {
    var downBytesPerSec: Double
    var downText: String
    var fontColorHex: String

    private let ticks: [(label: String, mbps: Double)] = [
        ("0", 0), ("5", 5), ("10", 10), ("20", 20), ("50", 50),
        ("100", 100), ("200", 200), ("500", 500), ("1G", 1000), ("2G", 2000), ("5G", 5000),
    ]
    private let maxMbps = 5000.0

    private func fraction(mbps: Double) -> Double {
        guard mbps > 0 else { return 0 }
        return min(log10(mbps + 1) / log10(maxMbps + 1), 1)
    }
    private func angle(fraction f: Double) -> Double { 180 - f * 180 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w / 2
            let cy = h - 8
            let r = min(w / 2 - 8, h - 16)
            let mbps = downBytesPerSec * 8 / 1_000_000
            let f = fraction(mbps: mbps)
            ZStack {
                // 刻度盘底弧
                Path { path in
                    path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                }
                .stroke(Color.white.opacity(0.10), lineWidth: 12)
                // 进度弧
                if f > 0.001 {
                    Path { path in
                        path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(180), endAngle: .degrees(angle(fraction: f)), clockwise: false)
                    }
                    .stroke(SpeedAppearance.color(hex: "#6FD8F0"), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                }
                // 刻度 + 数字
                ForEach(ticks, id: \.label) { tick in
                    let a = angle(fraction: fraction(mbps: tick.mbps)) * .pi / 180
                    let p1 = CGPoint(x: cx + (r - 16) * cos(a), y: cy - (r - 16) * sin(a))
                    let p2 = CGPoint(x: cx + (r - 6) * cos(a), y: cy - (r - 6) * sin(a))
                    Path { path in path.move(to: p1); path.addLine(to: p2) }
                        .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                    Text(tick.label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .position(x: cx + (r - 32) * cos(a), y: cy - (r - 32) * sin(a))
                }
                // 指针
                let na = angle(fraction: f) * .pi / 180
                Path { path in
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx + (r - 24) * cos(na), y: cy - (r - 24) * sin(na)))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Circle().fill(Color.white).frame(width: 10, height: 10).position(x: cx, y: cy)
                // 中间数字
                VStack(spacing: 0) {
                    SpeedNumberText(text: downText, size: min(w * 0.18, 72), fontColorHex: fontColorHex)
                    Text("下载").font(.caption).foregroundStyle(.secondary)
                }
                .position(x: cx, y: cy - r * 0.45)
            }
        }
    }
}

/// 双线实时曲线：下载青色、上传绿色，共用一个最大值归一化。
private struct DualSpeedGraphView: View {
    var down: [Double]
    var up: [Double]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    for f in [0.25, 0.5, 0.75] {
                        let y = geo.size.height * f
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                speedLine(history: down, size: geo.size, hex: "#6FD8F0")
                speedLine(history: up, size: geo.size, hex: "#4ADE80")
            }
        }
    }

    private func speedLine(history: [Double], size: CGSize, hex: String) -> some View {
        let maxV = max(down.max() ?? 0, up.max() ?? 0, 1)
        let n = history.count
        let pts: [CGPoint] = history.enumerated().map { i, v in
            CGPoint(
                x: n > 1 ? size.width * CGFloat(i) / CGFloat(n - 1) : 0,
                y: size.height * (1 - CGFloat(v / maxV))
            )
        }
        return Group {
            if pts.count > 1 {
                Path { path in
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(SpeedAppearance.color(hex: hex), lineWidth: 2)
            }
        }
    }
}

/// 外观设置弹窗：字体颜色 / 字号 / 背景底色，改完立即生效（推给灵动岛 / 锁屏）。
private struct AppearanceSheetView: View {
    @Binding var fontColorHex: String
    @Binding var fontSizeLevel: Int
    @Binding var backgroundHex: String
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("字体颜色") {
                    HStack(spacing: 12) {
                        ForEach(SpeedAppearance.fontColors) { opt in
                            Button {
                                fontColorHex = opt.hex
                                onChange()
                            } label: {
                                Circle()
                                    .fill(SpeedAppearance.color(hex: opt.hex))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                                    .overlay(Circle().stroke(Color.blue, lineWidth: fontColorHex == opt.hex ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(opt.name)
                        }
                    }
                }
                Section("字号") {
                    Picker("字号", selection: $fontSizeLevel) {
                        ForEach(0..<3) { i in
                            Text(SpeedAppearance.fontSizeNames[i]).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: fontSizeLevel) { _, _ in onChange() }
                }
                Section("背景底色") {
                    HStack(spacing: 12) {
                        ForEach(SpeedAppearance.backgrounds) { opt in
                            Button {
                                backgroundHex = opt.hex
                                onChange()
                            } label: {
                                Circle()
                                    .fill(SpeedAppearance.color(hex: opt.hex))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                                    .overlay(Circle().stroke(Color.blue, lineWidth: backgroundHex == opt.hex ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(opt.name)
                        }
                    }
                    Text("底色会应用到主界面、锁屏和灵动岛。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("外观设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
