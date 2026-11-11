import SwiftUI

// v3.4：深色仪表盘（18 Pro Max 440×956pt 适配）— 深海军底、超大发光数字、
// 实时速度曲线、青色开始按钮。数字字号按屏幕宽度算（GeometryReader），
// 不是写死的点数，换机型也不溢出；字号档（小/中/大）再乘一个系数。
// 布局：内容从灵动岛下方一直铺到 Home 指示条上方，中间用 Spacer 分摊空隙，
// 不留大段黑边；曲线用引擎里最近 60 次采样的下载速度画，不新增采样。
struct ContentView: View {
    @StateObject private var engine = SpeedEngine()
    @ObservedObject private var manager = LiveActivityManager.shared
    @ObservedObject private var keepAlive = LocationKeepAlive.shared

    @AppStorage(SpeedAppearance.fontColorKey) private var fontColorHex = SpeedAppearance.defaultFontColor
    @AppStorage(SpeedAppearance.fontSizeKey) private var fontSizeLevel = SpeedAppearance.defaultFontSize
    @AppStorage(SpeedAppearance.backgroundKey) private var backgroundHex = SpeedAppearance.defaultBackground
    @State private var appearanceExpanded = false

    private static let accentHex = "#6FD8F0"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SpeedAppearance.color(hex: backgroundHex).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    Text("NETWORK MONITOR")
                        .font(.caption)
                        .tracking(6)
                        .foregroundStyle(SpeedAppearance.color(hex: Self.accentHex))

                    Text(engine.isWiFi ? "Wi-Fi" : "蜂窝")
                        .font(.caption)
                        .foregroundStyle(SpeedAppearance.color(hex: Self.accentHex))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(
                            Capsule().stroke(SpeedAppearance.color(hex: Self.accentHex).opacity(0.6), lineWidth: 1)
                        )
                        .padding(.top, 12)

                    Spacer()

                    speedBlock(label: "下载", text: engine.downText, size: downloadSize(width: geo.size.width))

                    speedBlock(label: "上传", text: engine.upText, size: uploadSize(width: geo.size.width))
                        .padding(.top, 18)

                    Spacer()

                    SpeedGraphView(history: engine.downHistory)
                        .frame(height: graphHeight(height: geo.size.height))

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

                    // MARK: - 外观设置（默认收起，主界面保持干净）
                    DisclosureGroup("外观设置", isExpanded: $appearanceExpanded) {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("字体颜色").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    ForEach(SpeedAppearance.fontColors) { opt in
                                        Button {
                                            fontColorHex = opt.hex
                                            engine.refreshAppearance()
                                        } label: {
                                            Circle()
                                                .fill(SpeedAppearance.color(hex: opt.hex))
                                                .frame(width: 30, height: 30)
                                                .overlay(
                                                    Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1)
                                                )
                                                .overlay(
                                                    Circle().stroke(Color.blue, lineWidth: fontColorHex == opt.hex ? 2 : 0)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(opt.name)
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("字号").font(.caption).foregroundStyle(.secondary)
                                Picker("字号", selection: $fontSizeLevel) {
                                    ForEach(0..<3) { i in
                                        Text(SpeedAppearance.fontSizeNames[i]).tag(i)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: fontSizeLevel) { _, _ in engine.refreshAppearance() }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("背景底色").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    ForEach(SpeedAppearance.backgrounds) { opt in
                                        Button {
                                            backgroundHex = opt.hex
                                            engine.refreshAppearance()
                                        } label: {
                                            Circle()
                                                .fill(SpeedAppearance.color(hex: opt.hex))
                                                .frame(width: 30, height: 30)
                                                .overlay(
                                                    Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1)
                                                )
                                                .overlay(
                                                    Circle().stroke(Color.blue, lineWidth: backgroundHex == opt.hex ? 2 : 0)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(opt.name)
                                    }
                                }
                                Text("底色会应用到主界面、锁屏和灵动岛。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 16)

                    Text("开始后定位保活让 App 在后台持续运行，灵动岛每秒刷新；状态栏会显示定位箭头。点停止后保活结束，箭头消失。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        }
        .onAppear { engine.restoreIfNeeded() }
    }

    // 18 Pro Max 宽 440pt：下载数字约宽度的 19%，上传约 16%，再乘字号档系数；
    // minimumScaleFactor 兜底，再长的数字也不会溢出。
    private func downloadSize(width: CGFloat) -> CGFloat {
        width * 0.19 * [0.85, 1.0, 1.15][SpeedAppearance.clamped(fontSizeLevel)]
    }
    private func uploadSize(width: CGFloat) -> CGFloat {
        width * 0.16 * [0.85, 1.0, 1.15][SpeedAppearance.clamped(fontSizeLevel)]
    }
    private func graphHeight(height: CGFloat) -> CGFloat {
        min(max(height * 0.16, 120), 170)
    }

    private func speedBlock(label: String, text: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundStyle(SpeedAppearance.color(hex: fontColorHex))
                .contentTransition(.identity)
                .animation(nil, value: text)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .shadow(color: .white.opacity(0.25), radius: 8)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }
}

/// 实时速度曲线：最近 60 次采样（约 60 秒）的下载速度，归一化画线 + 渐变填充。
private struct SpeedGraphView: View {
    var history: [Double]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 横向网格线
                Path { path in
                    for f in [0.25, 0.5, 0.75] {
                        let y = geo.size.height * f
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                if history.count > 1 {
                    let maxV = max(history.max() ?? 1, 1)
                    let pts = points(size: geo.size, maxV: maxV)
                    Path { path in
                        path.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        path.addLines(pts)
                        path.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [SpeedAppearance.color(hex: "#6FD8F0").opacity(0.25), SpeedAppearance.color(hex: "#6FD8F0").opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    Path { path in
                        path.move(to: pts[0])
                        for p in pts.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(SpeedAppearance.color(hex: "#6FD8F0"), lineWidth: 2)
                }
            }
        }
    }

    private func points(size: CGSize, maxV: Double) -> [CGPoint] {
        let n = history.count
        return history.enumerated().map { i, v in
            CGPoint(
                x: n > 1 ? size.width * CGFloat(i) / CGFloat(n - 1) : 0,
                y: size.height * (1 - CGFloat(v / maxV))
            )
        }
    }
}
