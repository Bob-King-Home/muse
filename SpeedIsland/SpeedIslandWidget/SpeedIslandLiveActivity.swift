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
                    // v3.5：这里不能用 Label（系统图标箭头）——文字里已经有 ↓↑，
                    // 用 Label 会画两个箭头（"↓ ↓ 0 B/s"），就是锁屏上看到的重复箭头
                    Text("↓ \(context.state.downText)")
                        .animation(nil, value: context.state.downText)
                    Text("↑ \(context.state.upText)")
                        .animation(nil, value: context.state.upText)
                }
                .font(.system(size: lockSize, weight: .bold, design: .monospaced))
                .foregroundStyle(fontColor)
                // v3.2：数字直接切换，不淡入淡出
                .contentTransition(.identity)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                // v3.5：锁屏也显示网络信息（Wi-Fi 名 / 5G / IP）
                Text(infoLine(state: context.state))
                    .font(.caption2).foregroundStyle(.secondary)
                if !context.state.ip.isEmpty {
                    Text("IP \(context.state.ip)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                // v3.13：苹果倒计时的逻辑 —— Text(startDate, style: .timer)
                // 由系统本地每秒渲染，不用 App 推送，所以计时一直在走、一直在刷新
                HStack(spacing: 4) {
                    Text("已运行")
                    Text(context.state.startDate, style: .timer)
                }
                .font(.caption2).foregroundStyle(.secondary)
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
                        .font(.system(size: islandSize + 2, weight: .bold, design: .monospaced))
                        .foregroundStyle(fontColor)
                        .contentTransition(.identity)
                        .animation(nil, value: context.state.downText)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("↑ \(context.state.upText)")
                        .font(.system(size: islandSize + 2, weight: .bold, design: .monospaced))
                        .foregroundStyle(fontColor)
                        .contentTransition(.identity)
                        .animation(nil, value: context.state.upText)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // v3.5：展开页显示网络信息（Wi-Fi 名 / 5G / 运营商 / IP）
                    VStack(spacing: 2) {
                        Text(infoLine(state: context.state))
                            .font(.caption2).foregroundStyle(fontColor)
                        if !context.state.ip.isEmpty {
                            Text("IP \(context.state.ip)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        // v3.13：苹果倒计时的逻辑 —— 系统本地每秒渲染，不用 App 推送
                        HStack(spacing: 4) {
                            Text("已运行")
                            Text(context.state.startDate, style: .timer)
                        }
                        .font(.caption2).foregroundStyle(fontColor)
                    }
                }
            } compactLeading: {
                // v3.5：定宽显示（"↓ 850K" / "↓ 10.8M" 都是 6 字符），
                // 宽度不再随网速变长变短来回跳
                Text("↓\(fixedShort(context.state.downText))")
                    .font(.system(size: islandSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(fontColor)
                    .contentTransition(.identity)
                    .animation(nil, value: context.state.downText)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            } compactTrailing: {
                Text("↑\(fixedShort(context.state.upText))")
                    .font(.system(size: islandSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(fontColor)
                    .contentTransition(.identity)
                    .animation(nil, value: context.state.upText)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            } minimal: {
                // v3.6：小圆点里地方小，用不补空格的短格式，少截断（定宽只在主岛有用）
                Text("↓\(short(context.state.downText))")
                    .font(.system(size: islandSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(fontColor)
                    .contentTransition(.identity)
                    .animation(nil, value: context.state.downText)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
        }
    }

    /// v3.5：网络信息行。Wi-Fi："Wi-Fi · SSID名"；蜂窝："5G · 中国电信"。
    /// SSID 读不到时只显示 "Wi-Fi"。
    private func infoLine(state: SpeedActivityAttributes.ContentState) -> String {
        if state.isWiFi {
            return state.ssid.isEmpty ? "Wi-Fi" : "Wi-Fi · \(state.ssid)"
        } else {
            return state.carrier.isEmpty ? state.netType : "\(state.netType) · \(state.carrier)"
        }
    }

    /// v3.5：定宽短格式。先缩成 "12.4M" / "850K" / "0"，再补空格到 5 字符，
    /// 等宽字体下宽度恒定，灵动岛不再一会长一会短。
    private func fixedShort(_ s: String) -> String {
        var t = short(s)
        if t.count > 5, let dot = t.firstIndex(of: ".") {
            // "1234.5M" -> "1234M"（去小数点保宽度）
            let intPart = t[..<dot]
            let unit = t.last.map { String($0) } ?? ""
            t = String(intPart) + unit
        }
        if t.count >= 5 { return String(t.prefix(5)) }
        return String(repeating: " ", count: 5 - t.count) + t
    }

    private func short(_ s: String) -> String {
        // "12.4 MB/s" -> "12.4M"，"850 KB/s" -> "850K"
        // v3.10：不到 1KB 的按 1KB 显示（"0 B/s" -> "1K"），岛上不出现 0
        if s.hasSuffix(" B/s") { return "1K" }
        return s.replacingOccurrences(of: " MB/s", with: "M")
            .replacingOccurrences(of: " KB/s", with: "K")
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
