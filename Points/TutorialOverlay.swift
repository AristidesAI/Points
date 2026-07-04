import SwiftUI

/// Real app actions drive the tutorial: ContentView pokes these; the overlay advances gated steps.
@Observable final class TutorialSignals {
    var swipedDeck = false
    var tappedPad = false
    var enteredNodes = false
}

/// First-launch guide. Dims only the picture — the bottom bar stays LIVE and visible, so the
/// user performs the real gesture (swipe the bar, tap a pad, swipe to nodes) and that advances
/// the tutorial. Replays from Settings → "Replay tutorial".
struct TutorialOverlay: View {
    var signals: TutorialSignals
    var onDone: () -> Void
    @State private var step = 0

    private enum Gate { case none, swipeDeck, tapPad, enterNodes }
    private enum Hint { case dragVertical, swipeRight, tap, swipeLeft, menu }

    private struct Step {
        let symbol: String
        let title: String
        let body: LocalizedStringKey
        let hint: Hint
        let gate: Gate
        var menuCutout = false
    }

    private let steps: [Step] = [
        Step(symbol: "slider.vertical.3",
             title: "Sliders live at the bottom",
             body: "Drag UP and DOWN on a slider to change it.\nThe number rides on the handle.\nTry DEPTH first — it's the big one.",
             hint: .dragVertical, gate: .none),
        Step(symbol: "arrow.left.and.right",
             title: "Swipe the bar for more pages",
             body: "The bottom bar has more pages of sliders.\nSwipe LEFT or RIGHT on the bar to see them.\nDo it now to continue.",
             hint: .swipeRight, gate: .swipeDeck),
        Step(symbol: "square.grid.2x2.fill",
             title: "The square pads are instant",
             body: "Tap a pad to switch an effect on — it turns WHITE while active.\nThe \(Image(systemName: "bolt.fill")) pad strobes, the \(Image(systemName: "snowflake")) pad freezes you.\nTap one to continue.",
             hint: .tap, gate: .tapPad),
        Step(symbol: "point.topleft.down.to.point.bottomright.curvepath",
             title: "Swipe LEFT for the node view",
             body: "Swipe left on the picture and the NODES fade in —\nthe wiring that makes everything work.\nSwipe left now to continue.",
             hint: .swipeLeft, gate: .enterNodes),
        Step(symbol: "circle.grid.2x2",
             title: "The four circles are the menu",
             body: "Top-left \(Image(systemName: "circle.grid.2x2")) → camera flip, pin count, stems,\ncolor, import, settings and more.\nEverything else in the app starts there.",
             hint: .menu, gate: .none, menuCutout: true),
    ]

    private var current: Step { steps[step] }

    var body: some View {
        GeometryReader { geo in
            let barH: CGFloat = 210          // leave the live bar uncovered at the bottom
            ZStack(alignment: .top) {
                // Dim only the picture; punch a hole for the 4-circle menu on the menu step.
                dim(topHeight: geo.size.height - barH)
                    .allowsHitTesting(false)

                // Card floats in the dimmed picture area (also non-interactive → gestures pass through).
                VStack(spacing: 18) {
                    Spacer()
                    Image(systemName: current.symbol)
                        .font(.system(size: 50, weight: .light)).foregroundStyle(Theme.text).frame(height: 64)
                    Text(current.title).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text)
                    Text(current.body).font(.system(size: 13)).foregroundStyle(Theme.text2)
                        .multilineTextAlignment(.center).lineSpacing(5).padding(.horizontal, 30)
                    hintView(current.hint).frame(height: 42)
                    Spacer()
                }
                .frame(height: geo.size.height - barH)
                .allowsHitTesting(false)

                // Progress dots + buttons sit ABOVE the live bar (never over the sliders/pads).
                VStack(spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(steps.indices, id: \.self) { i in
                            Rectangle().fill(i == step ? Theme.text : Theme.line).frame(width: 16, height: 2)
                        }
                    }
                    buttons
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, barH + 10)
            }
        }
        .ignoresSafeArea()
        // Gated steps advance when the REAL action happens in the app.
        .onChange(of: signals.swipedDeck) { if current.gate == .swipeDeck { advance() } }
        .onChange(of: signals.tappedPad) { if current.gate == .tapPad { advance() } }
        .onChange(of: signals.enteredNodes) { if current.gate == .enterNodes { advance() } }
    }

    private func advance() {
        if step < steps.count - 1 { withAnimation(.easeInOut(duration: 0.2)) { step += 1 } }
        else { onDone() }
    }

    @ViewBuilder private func dim(topHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.82))
            .frame(height: max(topHeight, 0))
            .overlay(alignment: .topLeading) {
                if current.menuCutout {
                    // Fade the overlay where the 4-circle menu is, so it stays visible.
                    Rectangle().fill(Color.black).frame(width: 210, height: 44)
                        .blendMode(.destinationOut)
                        .padding(.top, 8).padding(.leading, 8)
                }
            }
            .compositingGroup()
    }

    private var buttons: some View {
        HStack(spacing: 1) {
            Button { onDone() } label: {
                Text("SKIP").font(.system(size: 12, weight: .semibold)).tracking(1.5)
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity).padding(.vertical, 15).background(Theme.panel)
            }
            .buttonStyle(.plain)
            // Gated steps have NO Next — you must do the action. Others keep Next.
            if current.gate == .none {
                Button { advance() } label: {
                    Text(step < steps.count - 1 ? "NEXT" : "START PLAYING")
                        .font(.system(size: 12, weight: .bold)).tracking(1.5).foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 15).background(Theme.text)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .padding(.horizontal, 24)
    }

    @ViewBuilder private func hintView(_ hint: Hint) -> some View {
        switch hint {
        case .dragVertical:
            VStack(spacing: 2) { Image(systemName: "chevron.up"); Image(systemName: "chevron.down") }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).modifier(Bob())
        case .swipeRight: ChevronDrift(symbol: "chevron.right", dx: 26)
        case .swipeLeft: ChevronDrift(symbol: "chevron.left", dx: -26)
        case .tap:
            Circle().stroke(Theme.text, lineWidth: 2).frame(width: 26, height: 26).modifier(Pulse())
        case .menu:
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.2x2").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text).frame(width: 22, height: 22)
                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                Image(systemName: "arrow.up").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
    }
}

private struct ChevronDrift: View {
    let symbol: String
    let dx: CGFloat
    @State private var on = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Image(systemName: symbol).opacity(0.6)
            Image(systemName: symbol).opacity(0.3)
        }
        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
        .offset(x: on ? dx : 0).opacity(on ? 0.25 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false), value: on)
        .onAppear { on = true }
    }
}

private struct Bob: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.offset(y: on ? -6 : 6)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1.5 : 0.8).opacity(on ? 0 : 1)
            .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}
