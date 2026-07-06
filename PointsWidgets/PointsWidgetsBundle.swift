import WidgetKit
import SwiftUI

// The widget bundle's entry point. Only carries the depth-bake Live Activity for now (no home-screen
// widgets yet). @main lives here so the extension has a single bundle entry.

@main
struct PointsWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DepthBakeLiveActivity()
    }
}
