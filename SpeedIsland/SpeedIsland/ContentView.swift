import SwiftUI

// v3.2：白色简洁版（18 Pro Max）— 白底黑字、数字放大；
// 画中画已移除，没有悬浮小窗按钮；外观设置收进可折叠区，默认收起，主界面只剩
// 速度、开始/停止、状态三行。
// v3.2：网速数字直接切换，不做淡入淡出（见下方两个速度 Text 的
// .contentTransition(.identity) + .transaction disablesAnimations）。
struct ContentView: View {
    @StateObject private var engine = SpeedEngine()
    @ObservedObject private var manager = LiveActivityManager.shared
    @ObservedObject private var keepAlive = LocationKeepAlive.shared

    @AppStorage(SpeedAppearance.fontColorKey) private var fontColorHex = SpeedAppearance.defaultFontColor
    @AppStorage(SpeedAppearance.fontSizeKey) private var fontSizeLevel = SpeedAppearance.defaultFontSize
    @AppStorage(SpeedAppearance.backgroundKey) private var backgroundHex = SpeedAppearance.defaultBackground
    @State private var appearanceExpanded = false

    var body: some View {
        ZStack {
            SpeedAppearance.color(hex: backgroundHex).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Text(engine.isWiFi ? "Wi-Fi" : "蜂窝")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(Capsule())

                    HStack(spacing: 32) {
                        VStack {
                            Text("↓ 下载").font(.caption).foregroundStyle(.secondary)
                            Text(engine.downText)
                                .font(.system(size: SpeedAppearance.mainFontSize(level: fontSizeLevel), design: .monospaced))
                                .bold()
                                .foregroundStyle(SpeedAppearance.color(hex: fontColorHex))
                                // v3.2：数字直接切换，不淡入淡出
                                .contentTransition(.identity)
                                .animation(nil, value: engine.downText)
                                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                        }
                        VStack {
                            Text("↑ 上传").font(.caption).foregroundStyle(.secondary)
                            Text(engine.upText)
                                .font(.system(size: SpeedAppearance.mainFontSize(level: fontSizeLevel), design: .monospaced))
                                .bold()
                                .foregroundStyle(SpeedAppearance.color(hex: fontColorHex))
                                // v3.2：数字直接切换，不淡入淡出
                                .contentTransition(.identity)
                                .animation(nil, value: engine.upText)
                                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                        }
                    }

                    Button(engine.isRunning ? "停止" : "开始") {
                        engine.isRunning ? engine.stop() : engine.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text(manager.isActive ? "运行中 · \(engine.intervalText)刷新" : "已停止")
                        .font(.caption).foregroundStyle(.secondary)

                    Text(keepAlive.statusText)
                        .font(.caption).foregroundStyle(.secondary)

                    if let err = engine.errorMessage ?? manager.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // MARK: - v3.1 外观设置（默认收起，主界面保持干净）
                    DisclosureGroup("外观设置", isExpanded: $appearanceExpanded) {
                        VStack(alignment: .leading, spacing: 16) {
                        // 字体颜色
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
                                                // 选中态：白圈
                                                Circle().stroke(Color.white, lineWidth: fontColorHex == opt.hex ? 2 : 0)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(opt.name)
                                }
                            }
                        }
                        // 字号
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
                        // 背景底色
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
                                                Circle().stroke(Color.white, lineWidth: backgroundHex == opt.hex ? 2 : 0)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(opt.name)
                                }
                            }
                            Text("底色应用到主界面和锁屏；灵动岛本身的底是系统黑，改不了。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        }
                    }
                    .padding(16)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Text("开始后定位保活让 App 在后台持续运行，灵动岛每秒刷新；状态栏会显示定位箭头。点停止后保活结束，箭头消失。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
        .onAppear { engine.restoreIfNeeded() }
    }
}
