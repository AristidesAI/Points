import ActivityKit

// Shared attributes for the depth-bake Live Activity (DepthBakeActivity drives it).
// Lives in its own file so a widget extension can compile it too for the Dynamic
// Island / Lock Screen UI — without one the activity runs but renders no custom UI.
struct DepthBakeAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double     // 0-1 bake progress (the Timer-style ring)
        var frame: Int
        var total: Int
        var etaSeconds: Double
    }
    var sourceName: String       // "IMG_1234.MOV" etc — shown next to the ring
}
