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

// MARK: - Camera deck: CONTEXTUAL paged sliders — one page per graph node that has
// float params. A fresh (minimal) project shows only Camera / Depth / Point Display /
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
    var onPad: () -> Void = {}

    @State private var padStrobe = false
    @State private var padFreeze = false
    @State private var padReseed = false
    @State private var padInvert = false
    @State private var padBurst = false
    @State private var padHold = false

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
                    HStack(spacing: 6) {
                        Rectangle().fill(familyColor(entry.spec.family)).frame(width: 8, height: 8)
                        Text(entry.spec.name.uppercased())
                            .font(.system(size: 9, weight: .bold)).tracking(1.2)
                            .foregroundStyle(Theme.text)
                        Text(entry.node.id)
                            .font(.system(size: 8).monospaced()).foregroundStyle(Theme.text2)
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
            padRow
        }
        .padding(.bottom, 8)
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
    @Binding var open: Bool
    @State private var pinIndex = 0
    @State private var stemsOn = false   // arms live on the Point Display node; default freestanding
    private let pinSteps = [30_000, 77_000, 150_000, 307_200]

    var body: some View {
        // Two rows when open so all functions stay reachable on a phone width.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                cube("circle.grid.2x2", active: open) {
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
                    cube("chart.bar.fill", active: stemsOn) {
                        stemsOn.toggle()
                        runtime?.setBool("pd", "arms", stemsOn)   // arms = Point Display param
                    }
                    cube("paintpalette", active: sources.colorEnabled) {
                        sources.toggleColor()
                        runtime?.setColorMode(sources.colorEnabled ? .video : .none)
                    }
                    cube("rotate.right", active: false, caption: "\(sources.renderer.orient)") {
                        sources.renderer.setOrient((sources.renderer.orient + 1) % 8)
                    }
                }
            }
            if open {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 34, height: 1)   // aligns under the toggle
                    cube("record.circle", active: false) { onSheet(.record) }
                    cube("antenna.radiowaves.left.and.right", active: false) { onSheet(.ndi) }
                    cube("photo.badge.plus", active: false) { onSheet(.importMedia) }
                    cube("gearshape", active: false) { onSheet(.settings) }
                    cube("square.grid.2x2", active: false) { onBrowser() }
                }
            }
        }
    }

    private func cube(_ symbol: String, active: Bool, enabled: Bool = true,
                      caption: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? Color.black : (enabled ? Color.white.opacity(0.92) : .white.opacity(0.3)))
                    .frame(width: 36, height: 34)
                    .background(active ? Theme.text : Color.black.opacity(0.5))
                    .overlay(Rectangle().stroke(active ? Theme.text : .white.opacity(0.2), lineWidth: 1))
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
