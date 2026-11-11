import WidgetKit
import SwiftUI
import ActivityKit

/// v3.12：主屏幕小组件 —— 在主屏幕直接看当前网速。
/// 数据来源：直接读当前 Live Activity 的状态（和灵动岛同一份数据，
/// 不用 App Group，免费签名也能用）。
/// 刷新由系统定时触发（约每 15 分钟一次，系统会再限流），所以小组件
/// 不是每秒实时 —— 真正的实时请看灵动岛 / 锁屏 / App 内。
/// 点小组件打开 App。
struct SpeedWidgetEntry: TimelineEntry {
    let date: Date
    let downText: String
    let upText: String
    let netType: String
    let isRunning: Bool
}

struct SpeedWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpeedWidgetEntry {
        SpeedWidgetEntry(date: Date(), downText: "850 KB/s", upText: "120 KB/s", netType: "Wi-Fi", isRunning: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SpeedWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpeedWidgetEntry>) -> Void) {
        let entry = currentEntry()
        // 15 分钟后系统再刷新（系统会限流，实际可能更久）
        let next = Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> SpeedWidgetEntry {
        if let state = Activity<SpeedActivityAttributes>.activities.first?.content.state {
            return SpeedWidgetEntry(date: Date(), downText: state.downText, upText: state.upText, netType: state.isWiFi ? "Wi-Fi" : state.netType, isRunning: true)
        }
        return SpeedWidgetEntry(date: Date(), downText: "—", upText: "—", netType: "", isRunning: false)
    }
}

struct SpeedHomeWidgetView: View {
    var entry: SpeedWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if entry.isRunning {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时网速")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    if family == .systemSmall {
                        Text(entry.downText)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("↓ \(entry.netType)")
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    } else {
                        HStack(spacing: 4) {
                            Text("↓")
                            Text(entry.downText)
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Text("↑")
                            Text(entry.upText)
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                        }
                        Text(entry.netType)
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时网速")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    Text("未开始")
                        .font(.system(size: 20, weight: .bold))
                    Text("点按打开 App 开始测速")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .containerBackground(for: .widget) {
            Color(red: 0.043, green: 0.063, blue: 0.149)
        }
    }
}

struct SpeedIslandHomeWidget: Widget {
    let kind: String = "SpeedIslandHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpeedWidgetProvider()) { entry in
            SpeedHomeWidgetView(entry: entry)
        }
        .configurationDisplayName("实时网速")
        .description("在主屏幕查看当前网速。由系统定时刷新（约每 15 分钟），不是每秒实时；灵动岛和 App 内才是每秒实时。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
