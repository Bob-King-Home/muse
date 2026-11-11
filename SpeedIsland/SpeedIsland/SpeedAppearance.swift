import SwiftUI

/// v3.1 白色主题（18 Pro Max 大屏）：默认白底黑字，字号放大；
/// 字体颜色只给深色（白底上看得清），背景底色只给浅色。
/// 存法：主 App 的 UserDefaults（普通 key，不用 App Group）。
/// 灵动岛 / 锁屏拿不到 App 的 UserDefaults，所以这三个值放进
/// SpeedActivityAttributes.ContentState，每次 start/update 一起推过去，
/// Widget 只读 ContentState 里的值，不读 UserDefaults。
enum SpeedAppearance {
    static let fontColorKey = "si_fontColor"
    static let fontSizeKey = "si_fontSize"
    static let backgroundKey = "si_background"

    static let defaultFontColor = "#000000"
    static let defaultFontSize = 1 // 0 小 / 1 中 / 2 大
    static let defaultBackground = "#FFFFFF"

    struct Option: Identifiable {
        let id: String
        let name: String
        let hex: String
    }

    /// 字体颜色：只给深色，配白色底都看得清
    static let fontColors: [Option] = [
        .init(id: "black", name: "黑", hex: "#000000"),
        .init(id: "darkgray", name: "深灰", hex: "#3A3A3C"),
        .init(id: "blue", name: "蓝", hex: "#007AFF"),
        .init(id: "green", name: "绿", hex: "#248A3D"),
        .init(id: "red", name: "红", hex: "#D70015"),
        .init(id: "orange", name: "橙", hex: "#C93400"),
    ]

    /// 背景底色：只给浅色，深字在上面都看得清
    static let backgrounds: [Option] = [
        .init(id: "white", name: "白", hex: "#FFFFFF"),
        .init(id: "lightgray", name: "浅灰", hex: "#F2F2F7"),
        .init(id: "lightblue", name: "浅蓝", hex: "#E5F1FF"),
        .init(id: "lightgreen", name: "浅绿", hex: "#E6F4EA"),
        .init(id: "lightyellow", name: "浅黄", hex: "#FFF8E1"),
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

    /// 主界面数字字号（v3.1：18 Pro Max 大屏放大）
    static func mainFontSize(level: Int) -> CGFloat {
        [28, 36, 46][clamped(level)]
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
