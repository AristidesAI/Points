import SwiftUI
import WidgetKit
import ActivityKit

// The custom Live Activity for the depth bake — the Timer-app-style Dynamic Island: a small circular
// progress ring on the leading side, time-remaining on the trailing side. Replaces the system
// BGContinuedProcessingTask presentation (which can't be restyled).

private let bakeCyan = Color(red: 0.30, green: 0.82, blue: 1.0)
private let bakeBlue = Color(red: 0.18, green: 0.48, blue: 1.0)

/// Circular determinate progress ring (the "small circle" that wraps the camera).
struct BakeRing: View {
    var progress: Double
    var lineWidth: CGFloat = 4
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(LinearGradient(colors: [bakeCyan, bakeBlue], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.25), value: progress)
    }
}

struct DepthBakeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DepthBakeAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BakeRing(progress: context.state.progress, lineWidth: 5)
                        .frame(width: 36, height: 36)
                        .overlay(Text("\(pct(context.state.progress))")
                            .font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(DepthBakeAttributes.etaText(context.state.etaSeconds))
                            .font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        Text("left").font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text("Processing depth").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Text(context.attributes.sourceName)
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress).tint(bakeCyan)
                }
            } compactLeading: {
                BakeRing(progress: context.state.progress, lineWidth: 3).frame(width: 18, height: 18)
            } compactTrailing: {
                Text(DepthBakeAttributes.etaText(context.state.etaSeconds))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            } minimal: {
                BakeRing(progress: context.state.progress, lineWidth: 3).frame(width: 18, height: 18)
            }
            .keylineTint(bakeCyan)
        }
    }
    private func pct(_ p: Double) -> Int { Int((max(0, min(1, p)) * 100).rounded()) }
}

/// Lock-screen / banner presentation (also shown on devices without a Dynamic Island).
struct LockScreenView: View {
    let context: ActivityViewContext<DepthBakeAttributes>
    var body: some View {
        HStack(spacing: 14) {
            BakeRing(progress: context.state.progress, lineWidth: 6)
                .frame(width: 46, height: 46)
                .overlay(Text("\(Int((context.state.progress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text("Processing depth").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(context.attributes.sourceName)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                if context.state.total > 0 {
                    Text("Frame \(context.state.frame) of \(context.state.total) · \(DepthBakeAttributes.etaText(context.state.etaSeconds)) left")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
