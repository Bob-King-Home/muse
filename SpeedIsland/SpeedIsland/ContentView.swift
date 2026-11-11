import SwiftUI
import UIKit

// v3.5：按用户选定的深色仪表盘 mockup（media-generation-speedisland-ui-dark）
// 结合实际功能改 ——
// 居中 NETWORK MONITOR 标题 + 网络徽章 + 下载超大数字 + UPLOAD 超大数字 +
// 网格曲线（下载青色带渐变填充 / 上传绿色）+ 网络信息行 + 青色大开始按钮。
// mockup 里的 LATENCY/JITTER/PACKET LOSS 没有（苹果不给测 Ping 的接口），
// 换成我们真实能拿到的：Wi-Fi 名 / 5G / 运营商 / IP。
// 性能：大数字不加阴影（每秒重绘的阴影是卡顿主因之一）；数字按屏宽算，18 Pro Max 适配。
// 黑边：Info.plist 加了 UILaunchScreen（深色启动底），根视图背景忽略安全区。
struct ContentView: View {
    @StateObject private var engine = SpeedEngine()
    @ObservedObject private var manager = LiveActivityManager.shared
    @ObservedObject private var keepAlive = LocationKeepAlive.shared
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SpeedAppearance.fontColorKey) private var fontColorHex = SpeedAppearance.defaultFontColor
    @AppStorage(SpeedAppearance.fontSizeKey) private var fontSizeLevel = SpeedAppearance.defaultFontSize
    @AppStorage(SpeedAppearance.backgroundKey) private var backgroundHex = SpeedAppearance.defaultBackground
    @AppStorage(SpeedAppearance.fontWeightKey) private var fontWeightRaw = SpeedAppearance.defaultFontWeight
    @AppStorage(SpeedAppearance.fontDesignKey) private var fontDesignRaw = SpeedAppearance.defaultFontDesign
    @State private var showAppearance = false

    private static let accentHex = "#6FD8F0"
    private static let upHex = "#4ADE80"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SpeedAppearance.color(hex: backgroundHex).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    // 顶栏：居中标题 + 右上角齿轮（外观设置入口放这里，一眼能看到）
                    ZStack {
                        Text("NETWORK MONITOR")
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(4)
                            .foregroundStyle(SpeedAppearance.color(hex: Self.accentHex))
                            .frame(maxWidth: .infinity)
                        HStack {
                            Spacer()
                            Button { showAppearance = true } label: {
                                Image(systemName: "gearshape")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 40, height: 40)
                                    .background(Color.gray.opacity(0.15))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("外观设置")
                        }
                    }
                    .padding(.top, 6)

                    // 网络徽章：Wi-Fi / 5G · 运营商（频段苹果不开放，拿不到，不写）
                    netBadge
                        .padding(.top, 18)

                    // 下载超大数字（mockup 里的主数字）
                    SpeedNumberText(text: engine.downText, size: downSize(width: geo.size.width), unitScale: 0.55, fontColorHex: fontColorHex, weight: SpeedAppearance.fontWeight, design: SpeedAppearance.fontDesign)
                        .padding(.top, 10)

                    // 上传
                    Text("UPLOAD")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(SpeedAppearance.color(hex: Self.accentHex))
                        .padding(.top, 18)
                    SpeedNumberText(text: engine.upText, size: upSize(width: geo.size.width), unitScale: 0.55, fontColorHex: fontColorHex, weight: SpeedAppearance.fontWeight, design: SpeedAppearance.fontDesign)
                        .padding(.top, 2)

                    // 图例 + 网格曲线
                    HStack(spacing: 16) {
                        legendDot(hex: Self.accentHex, text: "下载")
                        legendDot(hex: Self.upHex, text: "上传")
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.white)
                    .padding(.top, 20)
                    DashboardGraphView(down: engine.downHistory, up: engine.upHistory)
                        .frame(height: graphHeight(height: geo.size.height))
                        .padding(.top, 6)

                    // 网络信息行：Wi-Fi 名 / 运营商 / IP
                    Text(networkDetail)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.top, 12)

                    // v3.7：本节流量和峰值
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本节流量  ↓ \(NetworkSpeedSampler.formatBytes(engine.totalDown))  ·  ↑ \(NetworkSpeedSampler.formatBytes(engine.totalUp))")
                            Text("峰值速度  ↓ \(NetworkSpeedSampler.format(engine.peakDown))  ·  ↑ \(NetworkSpeedSampler.format(engine.peakUp))")
                        }
                        Spacer()
                        // v3.10：累计流量重置按钮（不清零就一直往上加）
                        Button("重置") {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            engine.resetSessionStats()
                        }
                        .font(.caption)
                        .foregroundStyle(SpeedAppearance.color(hex: Self.accentHex))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(Capsule().stroke(SpeedAppearance.color(hex: Self.accentHex).opacity(0.6), lineWidth: 1))
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                    Spacer()

                    Button(engine.isRunning ? "停止" : "开始") {
                        // v3.7：点按给个轻震动，按钮立刻有反馈，不会觉得“没反应”
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        engine.isRunning ? engine.stop() : engine.start()
                    }
                    .font(.headline)
                    .foregroundStyle(SpeedAppearance.color(hex: "#0B1026"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(SpeedAppearance.color(hex: Self.accentHex))
                    .clipShape(Capsule())
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.isRunning ? (engine.islandEnabled ? (manager.isActive ? "运行中 · \(engine.intervalText)刷新" : "运行中 · 灵动岛启动中") : "运行中 · 灵动岛已关") : "已停止")
                        Text(keepAlive.statusText)
                    }
                    .font(.caption).foregroundStyle(.white)
                    .padding(.top, 14)

                    // v3.12：灵动岛开关 —— 关掉后 App 继续跑、主界面照常显示，只是不推灵动岛
                    HStack {
                        Text("灵动岛")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { engine.islandEnabled },
                            set: { engine.setIslandEnabled($0) }
                        ))
                        .labelsHidden()
                    }
                    .font(.caption).foregroundStyle(.white)
                    .padding(.top, 10)

                    if let err = engine.errorMessage ?? manager.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }

                    // v3.15：脚注改短（之前四句太啰嗦）+ 小字改白（用户说灰字看不清）。
                    // 内容：定位保活让 App 后台持续运行，状态栏会显示定位箭头；
                    // 点停止后箭头消失；关掉灵动岛会同时停掉保活，岛上什么都不留，再打开一起恢复。
                    Text("定位保活让 App 在后台持续运行，状态栏会显示定位箭头；点停止后箭头消失。关掉灵动岛会同时停掉保活，岛上什么都不留，再打开一起恢复。")
                        .font(.caption2).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
        }
        .onAppear { engine.restoreIfNeeded() }
        .onChange(of: scenePhase) { _, newPhase in
            // v3.5：从全屏游戏/后台切回来，立即恢复定时器和定位保活，灵动岛马上续上
            if newPhase == .active { engine.resumeAfterBackground() }
        }
        .sheet(isPresented: $showAppearance) {
            AppearanceSheetView(fontColorHex: $fontColorHex, fontSizeLevel: $fontSizeLevel, backgroundHex: $backgroundHex, fontWeightRaw: $fontWeightRaw, fontDesignRaw: $fontDesignRaw) {
                engine.refreshAppearance()
            }
        }
    }

    private var netBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: engine.isWiFi ? "wifi" : "antenna.radiowaves.left.and.right")
                .font(.caption)
            Text(badgeText)
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(SpeedAppearance.color(hex: Self.accentHex))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(Capsule().stroke(SpeedAppearance.color(hex: Self.accentHex).opacity(0.6), lineWidth: 1))
    }

    private var badgeText: String {
        if engine.isWiFi { return "Wi-Fi" }
        return engine.carrier.isEmpty ? engine.netType : "\(engine.netType) · \(engine.carrier)"
    }

    private var networkDetail: String {
        let ipPart = engine.ip
        if engine.isWiFi {
            let name = engine.ssid.isEmpty ? "Wi-Fi" : engine.ssid
            return ipPart.isEmpty ? name : "\(name) · IP \(ipPart)"
        } else {
            let c = engine.carrier.isEmpty ? engine.netType : engine.carrier
            return ipPart.isEmpty ? c : "\(c) · IP \(ipPart)"
        }
    }

    private func legendDot(hex: String, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(SpeedAppearance.color(hex: hex)).frame(width: 8, height: 8)
            Text(text)
        }
    }

    // 18 Pro Max 宽 440pt：下载数字约宽度的 22%，上传约 18%，再乘字号档系数；
    // minimumScaleFactor 兜底，再长的数字也不会溢出。
    private func downSize(width: CGFloat) -> CGFloat {
        width * 0.22 * [0.85, 1.0, 1.15][SpeedAppearance.clamped(fontSizeLevel)]
    }
    private func upSize(width: CGFloat) -> CGFloat {
        width * 0.18 * [0.85, 1.0, 1.15][SpeedAppearance.clamped(fontSizeLevel)]
    }
    private func graphHeight(height: CGFloat) -> CGFloat {
        min(max(height * 0.16, 110), 150)
    }
}

/// 大号加粗网速数字：数字和单位分开渲染，单位小一号。
/// v3.8：用户要求调用系统字体 + 加粗 —— 默认系统字体（design .default），
/// 字重从外观设置读（默认加粗）；数字加 .monospacedDigit() 让数字等宽，
/// 数字变长变短时宽度不跳（不加这个，系统字体下 "1" 比 "8" 窄，数字会左右晃）。
/// v3.10：字体可选手册（默认 / 圆体 / 衬线 / 等宽），从外观设置读。
/// 不加阴影（每秒重绘的阴影是卡顿主因之一）。
private struct SpeedNumberText: View {
    var text: String
    var size: CGFloat
    var unitScale: CGFloat = 0.32
    var fontColorHex: String
    var weight: Font.Weight = .bold
    var design: Font.Design = .default

    var body: some View {
        let parts = text.split(separator: " ")
        let digits = parts.first.map(String.init) ?? text
        let unit = parts.count > 1 ? String(parts[1]) : ""
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(digits)
                .font(.system(size: size, weight: weight, design: design).monospacedDigit())
                .foregroundStyle(SpeedAppearance.color(hex: fontColorHex))
            Text(unit)
                .font(.system(size: max(size * unitScale, 11), weight: .semibold, design: design))
                .foregroundStyle(SpeedAppearance.color(hex: fontColorHex).opacity(0.75))
        }
        .contentTransition(.identity)
        .animation(nil, value: text)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// 网格实时曲线（mockup 风格）：淡网格 + 下载青色线带渐变填充 + 上传绿色线。
/// 拆成小函数，免得编译器对一整个 body 做类型推断超时。
private struct DashboardGraphView: View {
    var down: [Double]
    var up: [Double]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                gridLines(size: geo.size)
                downFill(size: geo.size)
                downLine(size: geo.size)
                upLine(size: geo.size)
            }
        }
    }

    private func maxValue() -> Double {
        max(down.max() ?? 0, up.max() ?? 0, 1)
    }

    private func points(history: [Double], size: CGSize) -> [CGPoint] {
        let maxV = maxValue()
        let n = history.count
        return history.enumerated().map { i, v in
            CGPoint(
                x: n > 1 ? size.width * CGFloat(i) / CGFloat(n - 1) : 0,
                y: size.height * (1 - CGFloat(v / maxV))
            )
        }
    }

    private func gridLines(size: CGSize) -> some View {
        Path { path in
            for i in 1...4 {
                let y = size.height * CGFloat(i) / 5
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            for i in 1...5 {
                let x = size.width * CGFloat(i) / 6
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(Color.white.opacity(0.06), lineWidth: 1)
    }

    private func linePath(history: [Double], size: CGSize) -> Path {
        let pts = points(history: history, size: size)
        var path = Path()
        guard pts.count > 1 else { return path }
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }

    private func downFill(size: CGSize) -> some View {
        let pts = points(history: down, size: size)
        var path = Path()
        if pts.count > 1 {
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
        return path.fill(
            LinearGradient(
                colors: [SpeedAppearance.color(hex: "#6FD8F0").opacity(0.25), .clear],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func downLine(size: CGSize) -> some View {
        linePath(history: down, size: size)
            .stroke(SpeedAppearance.color(hex: "#6FD8F0"), lineWidth: 2)
    }

    private func upLine(size: CGSize) -> some View {
        linePath(history: up, size: size)
            .stroke(SpeedAppearance.color(hex: "#4ADE80"), lineWidth: 2)
    }
}

/// 外观设置弹窗：字体颜色 / 字号 / 字体粗细 / 字体 / 背景底色，改完立即生效（推给灵动岛 / 锁屏）。
private struct AppearanceSheetView: View {
    @Binding var fontColorHex: String
    @Binding var fontSizeLevel: Int
    @Binding var backgroundHex: String
    @Binding var fontWeightRaw: String
    @Binding var fontDesignRaw: String
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
                Section("字体粗细") {
                    // v3.8：用户要求系统字体 + 加粗可调
                    Picker("字体粗细", selection: $fontWeightRaw) {
                        ForEach(SpeedAppearance.fontWeightNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: fontWeightRaw) { _, _ in onChange() }
                }
                Section("字体") {
                    // v3.10：字体选择（默认系统 / 圆体 / 衬线 / 等宽），只改主界面大数字
                    Picker("字体", selection: $fontDesignRaw) {
                        ForEach(SpeedAppearance.fontDesignNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: fontDesignRaw) { _, _ in onChange() }
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
