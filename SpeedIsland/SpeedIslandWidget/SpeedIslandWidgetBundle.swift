import SwiftUI
import WidgetKit

@main
struct SpeedIslandWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeedIslandLiveActivity()
        SpeedIslandHomeWidget()
    }
}
