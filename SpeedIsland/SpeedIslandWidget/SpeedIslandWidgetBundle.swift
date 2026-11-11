import SwiftUI
import WidgetKit

// v3.16：主屏幕小组件已删（用户不要了；免费账号下小组件读不到灵动岛的数据，
// 扩展进程看不到 App 的 Live Activity，留着只会一直显示“未开始”）。
// 只留灵动岛 / 锁屏的 Live Activity（它不用 App Groups，App 自己推数据）。
@main
struct SpeedIslandWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeedIslandLiveActivity()
    }
}
