import ActivityKit
import UIKit

// Drives the custom depth-bake Live Activity (Timer-style ring in the Dynamic Island) + holds a
// background-task assertion so the bake keeps running for a while if the app is minimised. Replaces
// the old BGContinuedProcessingTask, whose Dynamic Island couldn't be restyled into the ring look.
// ponytail: the assertion grants ~30 s of background time (enough for a photo / short clip); a long
// video backgrounded may suspend before it finishes — reinstate a background task if that matters.

@MainActor enum DepthBakeActivity {
    private static var activity: Activity<DepthBakeAttributes>?
    private static var bgTask: UIBackgroundTaskIdentifier = .invalid

    static func start(sourceName: String, total: Int) {
        // Keep the app alive in the background for the bake.
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "depthbake") { end() }
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }   // user disabled Live Activities
        let attrs = DepthBakeAttributes(sourceName: sourceName)
        let state = DepthBakeAttributes.ContentState(progress: 0, frame: 0, total: total, etaSeconds: 0)
        activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil))
    }

    static func update(progress: Double, frame: Int, total: Int, eta: Double) {
        guard let activity else { return }
        let state = DepthBakeAttributes.ContentState(progress: progress, frame: frame, total: total, etaSeconds: eta)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    static func end() {
        if let activity {
            let final = activity.content.state
            Task { await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .immediate) }
        }
        activity = nil
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }
}
