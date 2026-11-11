import SwiftUI

// v2.2：2 个按钮，没有广告
// v2.5 加了外观设置区（字体颜色 / 字号 / 背景底色），在主界面里直接改，不是独立设置页
// 修 P1-7：失败会显示一句话，不再只显示“已停止”让人猜
// 修 P3-6：@StateObject 不接共享单例，改 @ObservedObject
// 永远开：打开 App 时如果上次是开着的，自动续开
// v2.5 外观自定义：字体颜色 / 字号 / 背景底色，App 里直接改，改完立即生效，
// 灵动岛 / 锁屏 / 小窗一起变，不用重装。设置存在 UserDefaults，推给灵动岛时走 ContentState。
struct ContentView: View {
    @StateObject private var engine = SpeedEngine()
    @ObservedObject private var manager = LiveActivityManager.shared

    @AppStorage(SpeedAppearance.fontColorKey) private var fontColorHex = SpeedAppearance.defaultFontColor
    @AppStorage(SpeedAppearance.fontSizeKey) private var fontSizeLevel = SpeedAppearance.defaultFontSize
    @AppStorage(SpeedAppearance.backgroundKey) private var backgroundHex = SpeedAppearance.defaultBackground

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
                        }
                        VStack {
                            Text("↑ 上传").font(.caption).foregroundStyle(.secondary)
                            Text(engine.upText)
                                .font(.system(size: SpeedAppearance.mainFontSize(level: fontSizeLevel), design: .monospaced))
                                .bold()
                                .foregroundStyle(SpeedAppearance.color(hex: fontColorHex))
                        }
                    }

                    Button(engine.isRunning ? "停止" : "开始") {
                        engine.isRunning ? engine.stop() : engine.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    // 不再置灰：没开始就先开始再开小窗，一键就能用
                    Button(engine.isPiPOn ? "关闭小窗" : "悬浮小窗") {
                        engine.togglePiP()
                    }
                    .buttonStyle(.bordered)

                    Text(manager.isActive ? "运行中 · \(engine.intervalText)刷新" : "已停止")
                        .font(.caption).foregroundStyle(.secondary)

                    if let err = engine.errorMessage ?? manager.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // MARK: - v2.5 外观设置
                    VStack(alignment: .leading, spacing: 16) {
                        Text("外观").font(.headline)
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
                            Text("底色应用到主界面、小窗和锁屏；灵动岛本身的底是系统黑，改不了。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Text("不关就一直都在：8 小时到期自动续，重启手机后打开 App 自动续开")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
        .onAppear { engine.restoreIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .init("SpeedIslandPiPDidStop"))) { _ in
            // v2.3：小窗被用户点 X 关掉，马上同步按钮状态，不等下一次 tick
            engine.syncPiPStopped()
        }
    }
}
