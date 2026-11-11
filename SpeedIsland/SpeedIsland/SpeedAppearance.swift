import SwiftUI

/// v2.5 外观自定义：字体颜色 / 字号 / 背景底色，用户在 App 里直接改，不用重装。
/// 存法：主 App 的 UserDefaults（普通 key，不用 App Group）。
/// 灵动岛 / 锁屏拿不到 App 的 UserDefaults，所以这三个值放进
/// SpeedActivityAttributes.ContentState，每次 start/update 一起推过去，
/// Widget 只读 ContentState 里的值，不读 UserDefaults。
/// 画中画在主 App 进程里，直接读 UserDefaults，不用走 ContentState。
enum SpeedAppearance {
    static let fontColorKey = "si_fontColor"
    static let fontSizeKey = "si_fontSize"
    static let backgroundKey = "si_background"

    static let defaultFontColor = "#FFFFFF"
    static let defaultFontSize = 1 // 0 小 / 1 中 / 2 大
    static let defaultBackground = "#000000"

    struct Option: Identifiable {
        let id: String
        let name: String
        let hex: String
    }

    /// 字体颜色：只给亮色，配深色底都看得清
    static let fontColors: [Option] = [
        .init(id: "white", name: "白", hex: "#FFFFFF"),
        .init(id: "yellow", name: "黄", hex: "#FFD60A"),
        .init(id: "green", name: "绿", hex: "#30D158"),
        .init(id: "cyan", name: "青", hex: "#64D2FF"),
        .init(id: "orange", name: "橙", hex: "#FF9F0A"),
        .init(id: "red", name: "红", hex: "#FF453A"),
    ]

    /// 背景底色：只给深色，亮字在上面都看得清
    static let backgrounds: [Option] = [
        .init(id: "black", name: "黑", hex: "#000000"),
        .init(id: "darkgray", name: "深灰", hex: "#1C1C1E"),
        .init(id: "navy", name: "藏青", hex: "#0A1931"),
        .init(id: "darkgreen", name: "深绿", hex: "#0B2E1F"),
        .init(id: "darkpurple", name: "深紫", hex: "#1E0A33"),
    ]

    static let fontSizeNames = ["小", "中", "大"]

    // MARK: - 当前值（读 UserDefaults）

    static var fontColorHex: String {
        UserDefaults.standard.string(forKey: fontColorKey) ?? defaultFontColor
    }
    static var fontSizeLevel: Int {
        let v = UserDefaults.standard.integer(forKey: fontSizeKey)
        return (0...2).contains(v) ? v : defaultFontSize
    }
    static var backgroundHex: String {
        UserDefaults.standard.string(forKey: backgroundKey) ?? defaultBackground
    }

    // MARK: - 字号映射

    /// 主界面数字字号
    static func mainFontSize(level: Int) -> CGFloat {
        [18, 22, 28][clamped(level)]
    }
    /// 画中画第一行字号（320 宽：大号 26pt 时“↓ 12.4M  ↑ 850K”约 234pt，仍放得下；
    /// 之前注释写“约 203pt”是按 13 字符算错了，实际 15 字符，结论不变）
    static func pipFontSize(level: Int) -> CGFloat {
        [18, 22, 26][clamped(level)]
    }
    /// 灵动岛紧凑 / 最小模式字号（v2.4 已加大到 12pt；大号 13pt 约 47pt 宽，仍在单侧宽度内）
    static func islandFontSize(level: Int) -> CGFloat {
        [11, 12, 13][clamped(level)]
    }
    /// 锁屏实时活动数字字号
    static func lockFontSize(level: Int) -> CGFloat {
        [15, 16, 20][clamped(level)]
    }

    static func clamped(_ level: Int) -> Int { min(max(level, 0), 2) }

    // MARK: - 颜色

    static func color(hex: String) -> Color {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return .white }
        return Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    static func uiColor(hex: String) -> UIColor {
        UIColor(color(hex: hex))
    }
}
