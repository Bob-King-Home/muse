import ActivityKit
import Foundation

// v2.2 精简：只留界面真正用的两个文本 + isWiFi，删掉没人用的
// updatedAt / downBytesPerSec / title，减少每次推送的体积，省电省流量
// v2.5 外观自定义：字体颜色 / 字号 / 背景底色放进 ContentState，
// Widget 读不到主 App 的 UserDefaults，只能靠 Activity 推送带过去。
// 画中画在主 App 进程里，直接读 UserDefaults，不走这里。
struct SpeedActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var downText: String
        var upText: String
        var isWiFi: Bool
        var fontColorHex: String = "#FFFFFF"
        var fontSizeLevel: Int = 1
        var backgroundHex: String = "#000000"
    }
}
