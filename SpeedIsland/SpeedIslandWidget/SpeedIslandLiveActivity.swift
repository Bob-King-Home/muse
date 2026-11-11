import ActivityKit
import SwiftUI
import WidgetKit

// v2.2 修 P2-4：紧凑模式只放数字不放单位，避免被截成 ↓12…；
// 最小模式放数字，不再只放一个 ↓；删掉“每秒刷新”的假话
// v2.4：18 Pro Max 灵动岛相对小，紧凑/最小模式字号 caption2(11pt) → caption(12pt)
// v2.5 外观自定义：字体颜色 / 字号 / 背景底色从 ContentState 读（Widget 读不到主 App 的
// UserDefaults，只能靠 Activity 推送带过来）。字色全量应用；字号按档位映射；
// 底色只应用到锁屏（activityBackgroundTint），灵动岛本身的底是系统黑，改不了。
struct SpeedIslandLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedActivityAttributes.self) { context in
            let fontColor = color(hex: context.state.fontColorHex)
            let lockSize = lockFontSize(level: context.state.fontSizeLevel)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.state.isWiFi ? "Wi-Fi" : "蜂窝").font(.caption2).bold()
                    Spacer()
                    Text("实时网速").font(.caption2).foregroundStyle(.secondary)
                }
                .foregroundStyle(fontColor)
                HStack(spacing: 16) {
                    Label("↓ \(context.state.downText)", systemImage: "arrow.down")
                        .animation(nil, value: context.state.downText)
                    Label("↑ \(context.state.upText)", systemImage: "arrow.up")
                        .animation(nil, value: context.state.upText)
                }
                .font(.system(size: lockSize, design: .monospaced))
                .foregroundStyle(fontColor)
                // v3.2：数字直接切换，不淡入淡出
                .contentTransition(.identity)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
            .padding(12)
            .activityBackgroundTint(color(hex: context.state.backgroundHex).opacity(0.85))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let fontColor = color(hex: context.state.fontColorHex)
            let islandSize = islandFontSize(level: context.state.fontSizeLevel)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("↓ \(context.state.downText)")
                        .font(.system(size: islandSize + 2, design: .monospaced))
                        .foregroundStyle(fontColor)
                        .contentTransition(.identity)
                        .animation(nil, value: context.state.downText)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("↑ \(context.state.upText)")
                        .font(.system(size: islandSize + 2, design: .monospaced))
                        .foregroundStyle(fontColor)
                        .contentTransition(.identity)
                        .animation(nil, value: context.state.upText)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.isWiFi ? "Wi-Fi" : "蜂窝")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } compactLeading: {
                // 只放短数字：12.4M，比 ↓12.4 MB/s 省一半宽度
                Text("↓\(short(context.state.downText))")
                    .font(.system(size: islandSize, design: .monospaced))
                    .foregroundStyle(fontColor)
                    .contentTransition(.identity)
                    .animation(nil, value: context.state.downText)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            } compactTrailing: {
                Text("↑\(short(context.state.upText))")
                    .font(.system(size: islandSize, design: .monospaced))
                    .foregroundStyle(fontColor)
                    .contentTransition(.identity)
                    .animation(nil, value: context.state.upText)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            } minimal: {
                Text("↓\(short(context.state.downText))")
                    .font(.system(size: islandSize, design: .monospaced))
                    .foregroundStyle(fontColor)
                    .contentTransition(.identity)
                    .animation(nil, value: context.state.downText)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
        }
    }

    private func short(_ s: String) -> String {
        // "12.4 MB/s" -> "12.4M"，"850 KB/s" -> "850K"，"0 B/s" -> "0"
        s.replacingOccurrences(of: " MB/s", with: "M")
            .replacingOccurrences(of: " KB/s", with: "K")
            .replacingOccurrences(of: " B/s", with: "")
    }

    /// v2.5：hex → Color（Widget 里单独一份，主 App 的 SpeedAppearance.swift 不在 Widget target 里）
    private func color(hex: String) -> Color {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return .white }
        return Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    /// v2.5：字号档位 → 灵动岛紧凑/最小字号（小 11 / 中 12 / 大 13pt，和主 App 的映射一致）
    private func islandFontSize(level: Int) -> CGFloat {
        [11, 12, 13][min(max(level, 0), 2)]
    }

    /// v2.5：字号档位 → 锁屏数字字号（小 15 / 中 16 / 大 20pt）
    private func lockFontSize(level: Int) -> CGFloat {
        [15, 16, 20][min(max(level, 0), 2)]
    }
}
