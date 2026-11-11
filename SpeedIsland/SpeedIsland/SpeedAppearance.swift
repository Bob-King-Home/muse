import SwiftUI

/// v3.4 深色仪表盘：默认深海军底白字；字体颜色只给浅色、背景底色只给深色，
/// 深色底上都看得清。
/// 存法：主 App 的 UserDefaults（普通 key，不用 App Group）。
/// 灵动岛 / 锁屏拿不到 App 的 UserDefaults，所以这三个值放进
/// SpeedActivityAttributes.ContentState，每次 start/update 一起推过去，
/// Widget 只读 ContentState 里的值，不读 UserDefaults。
enum SpeedAppearance {
    static let fontColorKey = "si_fontColor"
    static let fontSizeKey = "si_fontSize"
    static let backgroundKey = "si_background"
    static let fontWeightKey = "si_fontWeight"
    static let appearanceVersionKey = "si_appearanceVersion"
    static let currentAppearanceVersion = 2

    static let defaultFontColor = "#FFFFFF"
    static let defaultFontSize = 1 // 0 小 / 1 中 / 2 大
    static let defaultBackground = "#0B1026"
    /// v3.8：数字字重：常规 / 加粗 / 特粗，默认加粗（用户要求系统字体 + 加粗）
    static let defaultFontWeight = "加粗"
    static let fontWeightNames = ["常规", "加粗", "特粗"]

    /// v3.4 从白色主题换成深色仪表盘：老版本存的黑字白底在深色底上看不见，
    /// 第一次打开时一次性重置为新默认值（用户之后再改就按他的来）。
    static func migrateIfNeeded() {
        let v = UserDefaults.standard.integer(forKey: appearanceVersionKey)
        guard v < currentAppearanceVersion else { return }
        UserDefaults.standard.set(defaultFontColor, forKey: fontColorKey)
        UserDefaults.standard.set(defaultBackground, forKey: backgroundKey)
        UserDefaults.standard.set(defaultFontSize, forKey: fontSizeKey)
        UserDefaults.standard.set(currentAppearanceVersion, forKey: appearanceVersionKey)
    }

    struct Option: Identifiable {
        let id: String
        let name: String
        let hex: String
    }

    /// 字体颜色：只给浅色，配深色底都看得清
    static let fontColors: [Option] = [
        .init(id: "white", name: "白", hex: "#FFFFFF"),
        .init(id: "lightgray", name: "浅灰", hex: "#C7C7CC"),
        .init(id: "cyan", name: "青", hex: "#6FD8F0"),
        .init(id: "green", name: "绿", hex: "#4ADE80"),
        .init(id: "yellow", name: "黄", hex: "#FACC15"),
        .init(id: "orange", name: "橙", hex: "#FB923C"),
    ]

    /// 背景底色：只给深色，浅字在上面都看得清
    static let backgrounds: [Option] = [
        .init(id: "navy", name: "深海军", hex: "#0B1026"),
        .init(id: "black", name: "纯黑", hex: "#000000"),
        .init(id: "darkgray", name: "深灰", hex: "#1C1C1E"),
        .init(id: "darkblue", name: "藏青", hex: "#152059"),
        .init(id: "darkgreen", name: "墨绿", hex: "#0F2A1D"),
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
    /// v3.8：数字字重（主界面数字用；灵动岛 / 锁屏默认加粗）
    static var fontWeight: Font.Weight {
        switch UserDefaults.standard.string(forKey: fontWeightKey) ?? defaultFontWeight {
        case "常规": return .regular
        case "特粗": return .black
        default: return .bold
        }
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
