import SwiftUI

// Flat, Signal-Loss-style controls. Sharp rectangles everywhere; no pills, no circles.

// MARK: - Vertical slider — value on the flat handle, horizontal label at the BOTTOM.

struct VSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var enabled = true
    var onChange: ((Float) -> Void)? = nil

    @State private var vertical: Bool? = nil   // direction gate: nil until intent known

    private var norm: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let trackTop: CGFloat = 12
            let trackBottom = h - 20
            let trackLen = max(trackBottom - trackTop, 8)
            let handleY = trackTop + (1 - norm) * trackLen

            ZStack {
                Rectangle()
                    .fill(Theme.line)
                    .frame(width: 2, height: trackLen)
                    .position(x: geo.size.width / 2, y: trackTop + trackLen / 2)
                Text(String(format: "%.2f", value))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(enabled ? Theme.text : Theme.text2)
                    .frame(width: 38, height: 17)
                    .background(Theme.panel)
                    .overlay(Rectangle().stroke(enabled ? Theme.text : Theme.line, lineWidth: 1))
                    .position(x: geo.size.width / 2, y: handleY)
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.text2)
                    .position(x: geo.size.width / 2, y: h - 8)
            }
            .contentShape(Rectangle())
            .gesture(
                enabled ? DragGesture(minimumDistance: 6)
                    .onChanged { g in
                        if vertical == nil {
                            vertical = abs(g.translation.height) >= abs(g.translation.width)
                        }
                        guard vertical == true else { return }   // horizontal intent → page swipe
                        let n = 1 - min(max((g.location.y - trackTop) / trackLen, 0), 1)
                        let v = range.lowerBound + Float(n) * (range.upperBound - range.lowerBound)
                        value = v
                        onChange?(v)
                    }
                    .onEnded { _ in vertical = nil }
                : nil
            )
        }
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Square VJ pad — active = filled white/grey. Presses feel physical:
// the pad sinks under the finger, springs back, and clicks (haptic).

struct PadPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .brightness(configuration.isPressed ? 0.18 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

struct DeckPad: View {
    let symbol: String
    let side: CGFloat
    var momentary = false
    var enabled = true
    @Binding var active: Bool
    var onHit: (() -> Void)? = nil

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
            if momentary {
                active = true
                onHit?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { active = false }
            } else {
                active.toggle()
                onHit?()
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(active ? Color.black : (enabled ? Theme.text : Theme.text2.opacity(0.5)))
                .frame(width: side, height: side)              // perfect square
                .background(active ? Theme.text : Theme.panel)
                .overlay(Rectangle().stroke(active ? Theme.text : Theme.line, lineWidth: 1))
                .scaleEffect(active ? 1.04 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: active)
        }
        .buttonStyle(PadPressStyle())
        .disabled(!enabled)
    }
}

// MARK: - Micro-joystick pad: tap-and-swipe (or hold in a direction) to jog a value.
// While the finger is offset from center it pumps a normalized vector ~18×/s.

struct MicroJoystickPad: View {
    let side: CGFloat
    var label: String = ""
    var active: Binding<Bool>? = nil     // true WHILE dragging → the deck suppresses its page-swipe
    var onVector: (CGVector) -> Void
    @State private var knob: CGSize = .zero
    @State private var pump: Task<Void, Never>?

    private var reach: CGFloat { side * 0.32 }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.panel)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            // crosshair
            Rectangle().fill(Theme.line).frame(width: side * 0.5, height: 1)
            Rectangle().fill(Theme.line).frame(width: 1, height: side * 0.5)
            Rectangle().fill(Theme.text)
                .frame(width: side * 0.30, height: side * 0.30)
                .offset(knob)
            if !label.isEmpty {
                Text(label).font(.system(size: 6, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Theme.text2)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 2)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    active?.wrappedValue = true              // claim the drag — no page-swipe even if the
                    let dx = max(-reach, min(reach, g.translation.width))   // finger leaves the pad box
                    let dy = max(-reach, min(reach, g.translation.height))
                    knob = CGSize(width: dx, height: dy)
                    if pump == nil { startPump() }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { knob = .zero }
                    pump?.cancel(); pump = nil
                    // Clear NEXT runloop so the deck's swipe .onEnded (same event) still sees it true.
                    DispatchQueue.main.async { active?.wrappedValue = false }
                }
        )
    }

    private func startPump() {
        pump = Task { @MainActor in
            while !Task.isCancelled {
                let v = CGVector(dx: knob.width / reach, dy: knob.height / reach)
                if abs(v.dx) > 0.12 || abs(v.dy) > 0.12 { onVector(v) }
                try? await Task.sleep(nanoseconds: 55_000_000)
            }
        }
    }
}

// MARK: - Camera deck: CONTEXTUAL paged sliders — one page per graph node that has
// float params. A fresh (minimal) project shows only Camera / Depth /
// Size; every node you add in the editor grows the deck. No orphan sliders, ever.

/// Vertical slider bound to a live graph param (deck flavor of ParamSliderRow).
struct VParamSlider: View {
    let runtime: GraphRuntime
    let nodeID: String
    let param: ParamSpec
    @State private var value: Float = 0

    var body: some View {
        VSlider(title: param.name.uppercased(), value: $value, range: param.range ?? 0...1) {
            runtime.setParam(nodeID, param.name, $0)
        }
        .onAppear { sync() }
        .onChange(of: runtime.generation) { sync() }
    }

    private func sync() {
        value = runtime.nodeParam(nodeID, param.name, param.defaultValue.floatValue)
    }
}

struct CameraDeckBar: View {
    @Bindable var sources: SourceManager
    let runtime: GraphRuntime
    @Binding var page: Int
    var direction: Int = 1
    @State private var padActive = false      // camera joystick/jog is being dragged → block page-swipe
    var onPad: () -> Void = {}
    var onOpenNode: (String) -> Void = { _ in }
    var onSwipe: (Int) -> Void = { _ in }     // horizontal page-swipe (dir ±1) — lives here so it can
                                              // skip while the camera pad is being dragged (padActive)

    @State private var padStrobe = false
    @State private var padFreeze = false
    @State private var padReseed = false
    @State private var padInvert = false
    @State private var padBurst = false
    @State private var padHold = false
    @State private var camMove = false        // camera pad: false = ORBIT, true = MOVE
    @State private var padRecenter = false

    private var pageNodes: [(node: GraphNode, spec: NodeSpec, floats: [ParamSpec])] {
        runtime.graph.nodes.compactMap { n in
            guard n.specID != "output",
                  let spec = NodeRegistry.shared.spec(n.specID) else { return nil }
            let floats = spec.params.filter { $0.range != nil }
            guard !floats.isEmpty else { return nil }
            return (n, spec, Array(floats.prefix(4)))
        }
    }

    private var pageCount: Int { max(pageNodes.count, 1) }
    private var pageMod: Int { ((page % pageCount) + pageCount) % pageCount }

    var body: some View {
        // Content-sized (no greedy Spacer — that was leaving a gap between the picture and the deck).
        VStack(spacing: 6) {
            if pageNodes.isEmpty {
                Text("No controllable nodes — add some in the node view")
                    .font(.system(size: 10)).foregroundStyle(Theme.text2)
                    .frame(height: 130)
            } else {
                let entry = pageNodes[pageMod]
                VStack(spacing: 4) {
                    // Double-tap the tab name → jump to the node view with this node selected.
                    HStack(spacing: 6) {
                        Rectangle().fill(familyColor(entry.spec.family)).frame(width: 8, height: 8)
                        Text(entry.spec.name.uppercased())
                            .font(.system(size: 9, weight: .bold)).tracking(1.2)
                            .foregroundStyle(Theme.text)
                        Text(entry.node.id)
                            .font(.system(size: 8).monospaced()).foregroundStyle(Theme.text2)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 8)).foregroundStyle(Theme.text2.opacity(0.6))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onOpenNode(entry.node.id)
                    }
                    HStack(spacing: 0) {
                        ForEach(entry.floats, id: \.name) { p in
                            VParamSlider(runtime: runtime, nodeID: entry.node.id, param: p)
                        }
                    }
                    .frame(height: 112)
                }
                .id("\(pageMod)-\(entry.node.id)")
                .transition(.asymmetric(
                    insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity)))
                .clipped()
            }
            pageDots
            // Nodes with their own buttons take over the pad row (Camera → orbit/move + jog +
            // recenter). Every other page keeps the global VJ pads.
            if currentNodeSpecID == "camera" { cameraPadRow } else { padRow }
        }
        .padding(.bottom, 8)
        // Page-swipe — suppressed while the camera joystick/jog is being dragged, so dragging the pad
        // out of its box never flips the deck page.
        .simultaneousGesture(
            DragGesture(minimumDistance: 25).onEnded { g in
                guard !padActive,
                      abs(g.translation.width) > abs(g.translation.height) * 1.5,
                      abs(g.translation.width) > 50 else { return }
                onSwipe(g.translation.width < 0 ? 1 : -1)
            }
        )
    }

    private var currentNodeSpecID: String? {
        pageNodes.isEmpty ? nil : pageNodes[pageMod].spec.id
    }
    /// The REAL id of the camera node on the current page — NOT the literal "cam". A camera added from
    /// the palette (or a loaded project) has a generated id like "c1", so hardcoding "cam" made the
    /// deck's orbit/move/recenter silently no-op (setParam guards on node existence) while the sliders,
    /// which already use entry.node.id, kept working — "orbit/move dead, zoom fine".
    private var camNodeID: String { pageNodes.isEmpty ? "cam" : pageNodes[pageMod].node.id }

    // Camera pad set: [ORBIT/MOVE toggle] · [micro-joystick] · [recenter].
    private var cameraPadRow: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 10
            let side = min(56, (geo.size.width - spacing * 2) / 3)
            HStack(spacing: spacing) {
                Button {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
                    camMove.toggle()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: camMove ? "move.3d" : "rotate.3d")
                            .font(.system(size: 16, weight: .medium))
                        Text(camMove ? "MOVE" : "ORBIT")
                            .font(.system(size: 7, weight: .bold)).tracking(0.5)
                    }
                    .foregroundStyle(Theme.text)
                    .frame(width: side, height: side)
                    .background(Theme.panel)
                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                }
                .buttonStyle(PadPressStyle())

                MicroJoystickPad(side: side, label: camMove ? "MOVE" : "ORBIT", active: $padActive) { v in
                    let (xp, yp) = camMove ? ("centerX", "centerY") : ("orbitX", "orbitY")
                    let limit: Float = camMove ? 5.0 : 100.0     // move far / orbit unbounded (full turns)
                    nudgeCam(xp, Float(v.dx) * 0.03, limit)
                    nudgeCam(yp, Float(-v.dy) * 0.03, limit)   // up = +param (matches jog chevrons)
                }

                DeckPad(symbol: "scope", side: side, momentary: true, active: $padRecenter) {
                    runtime.pushUndo()
                    for p in ["orbitX", "orbitY", "centerX", "centerY"] { runtime.setParam(camNodeID, p, 0) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 56)
        .padding(.horizontal, 12)
    }

    private func nudgeCam(_ name: String, _ delta: Float, _ limit: Float) {
        guard abs(delta) > 0.0001 else { return }
        let id = camNodeID
        let v = runtime.nodeParam(id, name, 0) + delta
        runtime.setParam(id, name, min(max(v, -limit), limit))
    }

    private var padRow: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let side = min(44, (geo.size.width - spacing * 5) / 6)
            HStack(spacing: spacing) {
                DeckPad(symbol: "bolt.fill", side: side, active: $padStrobe) {
                    onPad(); runtime.setStrobe(padStrobe)        // 8Hz square LFO → Size
                }
                DeckPad(symbol: "snowflake", side: side, active: $padFreeze) {
                    onPad(); runtime.setFreezeHold(padFreeze)    // holds captured Z, live lane
                }
                DeckPad(symbol: "arrow.clockwise", side: side, momentary: true, active: $padReseed) {
                    onPad(); sources.renderer.resetFilter()
                }
                DeckPad(symbol: "circle.lefthalf.filled", side: side, active: $padInvert) {
                    onPad(); runtime.setInvert(padInvert)        // depth inversion
                }
                DeckPad(symbol: "burst.fill", side: side, momentary: true, active: $padBurst) {
                    onPad(); runtime.fireShockwave(center: [0, 0])   // ring from view center
                }
                DeckPad(symbol: "circle.hexagongrid.fill", side: side, active: $padHold) {
                    onPad(); runtime.setColorMode(padHold ? .palette : .none)   // thermal palette
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<pageCount, id: \.self) { i in
                Rectangle()
                    .fill(i == pageMod ? Theme.text : Theme.line)
                    .frame(width: 12, height: 2)
            }
        }
    }
}

// MARK: - Corner menu: top-left, square cubes, opens HORIZONTALLY.

struct CornerMenu: View {
    @Bindable var sources: SourceManager
    var runtime: GraphRuntime? = nil
    var onSheet: (AppSheet) -> Void = { _ in }
    var onBrowser: () -> Void = {}
    var onNDI: () -> Void = {}
    var onRecord: () -> Void = {}
    var onReset: () -> Void = {}
    @Binding var open: Bool
    @State private var pinIndex = 0
    private let pinSteps = [30_000, 77_000, 150_000, 307_200]
    // Stems are the Depth node's ARMS param (edit it in that node's settings) — no menu button.

    var body: some View {
        // Output-sink status: record = red, NDI = blue, both = purple. Colours the toggle icon
        // (so you see it at a glance while closed) and the open accordion outline.
        let recOn = runtime?.recordRenderConfig() != nil
        let ndiOn = runtime?.ndiStreaming ?? false
        let status: Color? = (recOn && ndiOn) ? Theme.bothActive
            : recOn ? Theme.recActive : ndiOn ? Theme.ndiActive : nil
        // One row now that stems + orientation are gone. Photo moved to the very end.
        HStack(spacing: 4) {
            cube("circle.grid.2x2", active: open, tint: status) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { open.toggle() }
            }
            if open {
                cube("arrow.trianglehead.2.clockwise.rotate.90.camera",
                     active: false, enabled: sources.lidarAvailable) {
                    sources.toggleFacing()
                }
                cube("circle.grid.3x3", active: false, caption: "\(pinSteps[pinIndex] / 1000)k") {
                    pinIndex = (pinIndex + 1) % pinSteps.count
                    sources.renderer.setPinCount(pinSteps[pinIndex])
                }
                cube("paintpalette", active: sources.colorEnabled) {
                    sources.toggleColor()
                    runtime?.setColorMode(sources.colorEnabled ? .video : .none)
                }
                cube("record.circle", active: false, tint: recOn ? Theme.recActive : nil) {
                    onRecord()
                }
                cube("antenna.radiowaves.left.and.right", active: false,
                     tint: ndiOn ? Theme.ndiActive : nil) { open = false; onNDI() }
                cube("gearshape", active: false) { onSheet(.settings) }
                cube("square.grid.2x2", active: false) { onBrowser() }
                cube("photo.badge.plus", active: false) { onSheet(.importMedia) }
                // Very end: recovery — restart the capture engine if the live feed ever stalls.
                cube("arrow.clockwise.circle", active: false) {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    onReset()
                }
            }
        }
        .padding(2)
        .overlay(Rectangle().stroke(open ? (status ?? .clear) : .clear, lineWidth: 1))
    }

    private func cube(_ symbol: String, active: Bool, enabled: Bool = true,
                      caption: String? = nil, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint ?? (active ? Color.black : (enabled ? Color.white.opacity(0.92) : .white.opacity(0.3))))
                    .symbolEffect(.pulse, options: .repeating, isActive: tint != nil)
                    .frame(width: 36, height: 34)
                    .background(tint == nil && active ? Theme.text : Color.black.opacity(0.5))
                    .overlay(Rectangle().stroke(tint ?? (active ? Theme.text : .white.opacity(0.2)),
                                                lineWidth: tint != nil ? 1.5 : 1))
                if let caption {
                    Text(caption)
                        .font(.system(size: 7, weight: .semibold).monospacedDigit())
                        .foregroundStyle(active ? Color.black : .white.opacity(0.75))
                        .offset(y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}
