import ActivityKit
import Foundation

// Shared between the app (starts/updates the Live Activity) and the PointsWidgets extension (renders
// it). MUST be the same source compiled into both targets — that's how ActivityKit matches the
// running Activity to its widget UI. Lives outside Points/ so it's added to both targets explicitly.

struct DepthBakeAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double     // 0…1 — drives the ring
        var frame: Int
        var total: Int
        var etaSeconds: Double    // remaining, for the "time on the other side"
    }
    var sourceName: String        // the clip / photo being baked (static for the activity's life)

    /// "1:23" / "12s" — the trailing time-remaining label (Timer-app style).
    static func etaText(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "—" }
        return s >= 60 ? String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) : "\(Int(s.rounded()))s"
    }
}
