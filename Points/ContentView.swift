import SwiftUI
import AVFoundation

/// ONE page. 3:4 viewport edge-to-edge below the Dynamic Island; the rest of the screen
/// is the control bar. Camera view: contextual deck (bottom-anchored, pads above the home
/// bar). Node view: tool strip (tool/+/undo/redo + always-on minimap) then the selected
/// node's settings — the bar grows with the node's parameter count.
/// Swipe left/right on the viewport fades the node editor in/out.
enum AppSheet: String, Identifiable {
    case importMedia, settings, record, ndi
    var id: String { rawValue }
}

/// Palette presentation payload — carries the wire-filter type so the full-screen cover renders
/// with the right filter on the FIRST open (an `isPresented` bool captured a stale nil type).
struct PaletteContext: Identifiable {
    let id = UUID()
    var acceptsType: PortType? = nil    // dropped from an OUTPUT wire → nodes with a matching input
    var producesType: PortType? = nil   // dropped from an INPUT wire → nodes with a matching output
}

struct ContentView: View {
    var template: String? = nil
    var signals: TutorialSignals? = nil
    var onBrowser: () -> Void = {}
    @State private var renderer = PinRenderer()
    @State private var runtime = GraphRuntime()
    @State private var audio = AudioEngine()
    @State private var midi = MIDIEngine()
    @State private var recorder = RecordingManager()
    @State private var askedPhotos = false
    @State private var ndi = NDIManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var sources: SourceManager?
    @State private var nodesOn = false
    @State private var selection: Set<String> = ["pd"]   // node ids in the live graph
    @State private var selectedWire: Wire?
    @State private var editorCamera = EditorCamera()
    @State private var menuOpen = false
    @State private var deckPage = 0
    @State private var deckDir = 1
    @State private var vpH: CGFloat = 0      // live viewer height (grid centres inside it)
    @State private var sheet: AppSheet?
    @State private var palette: PaletteContext?
    // A NEW wire pulled from an output and dropped on empty → open the palette filtered to
    // compatible inputs; the chosen node auto-connects to this source.
    @State private var pendingConnect: (from: String, port: String, type: PortType, world: SIMD2<Float>)?
    // Same, but pulled from an INPUT → palette filtered to nodes whose OUTPUT feeds this input.
    @State private var pendingConnectInput: (from: String, port: String, type: PortType, world: SIMD2<Float>)?
    // "New node from a dropped wire" — user aids, toggled in Settings (default on).
    @AppStorage("newNodeFromOutput") private var newNodeFromOutput = true
    @AppStorage("newNodeFromInput") private var newNodeFromInput = true

    /// Enter/exit the node view. Entering always recenters the graph (clears `fitted`).
    private func setNodes(_ on: Bool) {
        if on { editorCamera.fitted = false; signals?.enteredNodes.toggle() }
        withAnimation(.easeInOut(duration: 0.25)) { nodesOn = on }
    }

    /// Fixed bottom-bar height (both modes) so the render viewport never changes size — the
    /// camera-view and node-view backdrops are pixel-identical. Tall node settings scroll.
    /// Sized to the minimal bars (least-param node / camera deck) so there's no dead space above
    /// the home indicator; taller bars grow up over the backdrop bottom. Same value for both modes,
    /// so the fixed-backdrop invariant (no view-switch height jump) is preserved.
    private let barH: CGFloat = 180

    /// Top-left touch-safe rect around the corner menu — taps here never fire a shockwave.
    /// Expands while the menu is open so tapping a menu option is safe too.
    private func inMenuSafe(_ p: CGPoint) -> Bool {
        // Menu is one horizontal row when open — wide + short (was two rows).
        let sw: CGFloat = menuOpen ? 392 : 66
        let sh: CGFloat = menuOpen ? 64 : 60
        return p.x < sw && p.y < sh
    }

    /// The right-edge mode-switch bar — taps here switch views, never fire a shockwave (mirrors
    /// inMenuSafe). Camera view only; the bar sits on the right, vertically centred.
    private func inEdgeSafe(_ p: CGPoint, _ w: CGFloat, _ h: CGFloat) -> Bool {
        p.x > w - 26 && abs(p.y - h / 2) < 60
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let gridH = w * 4 / 3                     // exact 3:4 pin grid — no black inside it
            let renderH = geo.size.height - barH      // FIXED backdrop; the bar overlays its bottom
            ZStack(alignment: .bottom) {
                // The viewer FILLS the space between the Dynamic Island and the bar (both modes).
                // The 3:4 render just centres inside it (the camera isn't bound to the viewer size).
                ZStack(alignment: .topLeading) {
                    MetalViewport(renderer: renderer, paused: palette != nil)
                    NodeEditorView(runtime: runtime, camera: editorCamera,
                                   selection: $selection, selectedWire: $selectedWire,
                                   onDropOutput: { node, port, world in
                                       guard newNodeFromOutput,
                                             let t = NodeRegistry.shared.spec(runtime.activeGraph.node(node)?.specID ?? "")?
                                           .outputs.first(where: { $0.name == port })?.type else { return }
                                       pendingConnect = (node, port, t, world)
                                       palette = PaletteContext(acceptsType: t)
                                   },
                                   onDropInput: { node, port, world in
                                       guard newNodeFromInput,
                                             let t = NodeRegistry.shared.spec(runtime.activeGraph.node(node)?.specID ?? "")?
                                           .inputs.first(where: { $0.name == port })?.type else { return }
                                       pendingConnectInput = (node, port, t, world)
                                       palette = PaletteContext(producesType: t)
                                   })
                        .opacity(nodesOn ? 1 : 0)
                        .allowsHitTesting(nodesOn)
                    if let sources {
                        if menuOpen {          // tap anywhere else closes the 4-circle menu
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { menuOpen = false }
                        }
                        CornerMenu(sources: sources, runtime: runtime,
                                   onSheet: { sheet = $0 }, onBrowser: onBrowser,
                                   onNDI: { let id = runtime.ensureNDIOut(); selection = [id] },
                                   onRecord: { let id = runtime.ensureRecord(); selection = [id] },
                                   onReset: { sources.restart() },
                                   open: $menuOpen)
                            .padding(.top, 10)
                            .padding(.leading, 10)
                        if sources.permissionDenied {
                            Text("Camera access needed — enable in Settings")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.7))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(height: renderH)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { vpH = $0 }
                .clipped()
                .background(Color.black)
                .contentShape(Rectangle())
                // Swipe handle: right edge (camera view) / left edge (node view). Tap switches too.
                .overlay(alignment: nodesOn ? .leading : .trailing) { edgeHandle }
                .overlay(alignment: .bottomLeading) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text("\(renderer.fps) FPS")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55))
                            .padding(6)
                    }
                    .allowsHitTesting(false)
                }
                // Mode switching is TAP-the-edge-bar only (edge swipe removed — it fought
                // node/wire drags near the screen edge). See `edgeHandle`.
                .simultaneousGesture(
                    // Viewport touch = node input (Touch node) + tap fires a shockwave.
                    // The top-left menu area is touch-safe (no accidental shockwave).
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard !nodesOn, !inMenuSafe(g.location),
                                  !inEdgeSafe(g.location, w, vpH) else { return }
                            let gridTop = max((vpH - gridH) / 2, 0)   // grid centred in the viewer
                            runtime.setTouch(x: Float(g.location.x / w),
                                             y: Float((g.location.y - gridTop) / gridH), pressed: true)
                        }
                        .onEnded { g in
                            defer { runtime.setTouch(x: 0, y: 0, pressed: false) }
                            guard !nodesOn, !inMenuSafe(g.startLocation),
                                  !inEdgeSafe(g.startLocation, w, vpH),
                                  abs(g.translation.width) < 12, abs(g.translation.height) < 12
                            else { return }
                            let gridTop = max((vpH - gridH) / 2, 0)
                            let u = Float(g.location.x / w)
                            let v = Float((g.location.y - gridTop) / gridH)
                            // view units: x ∈ [-1.5, 1.5], y ∈ [2, -2] top→bottom
                            runtime.fireShockwave(center: [(u - 0.5) * 3, (0.5 - v) * 4])
                        }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // ---- BOTTOM BAR — content-sized, at least `barH`, bottom-anchored ----
                // It grows UP over the backdrop when the selected node needs more room; the
                // backdrop never resizes and never reflows. No scrolling.
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    Group {
                        if nodesOn {
                            VStack(spacing: 0) {
                                EditorToolStrip(runtime: runtime, camera: editorCamera,
                                                selection: $selection, onAdd: { palette = PaletteContext() })
                                if let wire = selectedWire {
                                    wireBar(wire)
                                } else {
                                    NodeSettingsBar(runtime: runtime, selection: $selection)
                                }
                            }
                            .padding(.bottom, 8)
                        } else if let sources {
                            CameraDeckBar(sources: sources, runtime: runtime, page: $deckPage,
                                          direction: deckDir, onPad: { signals?.tappedPad.toggle() },
                                          onOpenNode: { id in selection = [id]; setNodes(true) })
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 25).onEnded { g in
                                        guard abs(g.translation.width) > abs(g.translation.height) * 1.5,
                                              abs(g.translation.width) > 50 else { return }
                                        deckDir = g.translation.width < 0 ? 1 : -1
                                        signals?.swipedDeck.toggle()
                                        withAnimation(.easeInOut(duration: 0.22)) { deckPage += deckDir }
                                    }
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: barH, alignment: .top)
                .background(Theme.bg)
            }
        }
        .background(Theme.bg)   // paints the home-indicator gap — bar keeps the normal bottom space
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { which in
            switch which {
            case .importMedia: ImportPlaceholderView()
            case .settings: SettingsPlaceholderView()
            case .record: RecordPlaceholderView()
            case .ndi: NDIPlaceholderView()
            }
        }
        // Full screen, square corners — the palette IS a screen, not a card.
        .fullScreenCover(item: $palette,
                         onDismiss: { pendingConnect = nil; pendingConnectInput = nil }) { ctx in
            NodePaletteView(acceptsType: ctx.acceptsType,
                            producesType: ctx.producesType,
                            onAdd: { spec in addNode(spec) })
        }
        .onChange(of: runtime.generation) {
            // Apple Depth Filter node ↔ capture layer (presence = on)
            sources?.setAppleDepthFiltering(runtime.appleDepthFilterOn)
            // Mic runs only while an audio node is in the graph (asks permission on first use).
            if runtime.usesAudioNodes { audio.start() } else { audio.stop() }
            // MIDI in runs only while a MIDI node is in the graph.
            if runtime.usesMidiNodes { midi.start() } else { midi.stop() }
            // Ask for Photos access as soon as a Record node exists — before any recording,
            // so STOP never has to prompt from inside a GPU completion handler (crash-safe).
            if runtime.hasRecordNode, !askedPhotos { askedPhotos = true; recorder.requestAuthorization() }
            // Vision runs only while a body/hand node is in the graph.
            sources?.vision.setRunning(runtime.usesBodyNodes)
            // NDI streams only while the NDI node's START is active (asks Local Network on first send).
            if runtime.ndiStreaming {
                ndi.start(name: runtime.ndiRenderConfig()?.name ?? "Points")   // restarts if name changed
            } else { ndi.stop() }
            // Record node deleted or stopped → finalize + save the take immediately (the renderer
            // also finalizes on the next nil-config frame; this makes delete-while-recording prompt).
            if runtime.recordRenderConfig() == nil { recorder.finishIfRecording() }
        }
        // Auto-stop NDI on background / lock / app-switch / call (never streams unattended,
        // never auto-resumes — flips the node back to STOP).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { runtime.stopNDIStreaming(); ndi.stop() }
        }
        // Call / alarm / timer interruptions (AVAudioSession) also stop the stream.
        .onReceive(NotificationCenter.default.publisher(
            for: AVAudioSession.interruptionNotification)) { _ in
            runtime.stopNDIStreaming(); ndi.stop()
        }
        .onAppear {
            if sources == nil {
                if let template { runtime.loadTemplate(template) }   // real per-template network
                let s = SourceManager(renderer: renderer)
                sources = s
                s.start()
                let rt = runtime
                renderer.programProvider = { rt.frameProgram() }
                let ae = audio
                runtime.audioSource = { ae.current() }
                if runtime.usesAudioNodes { audio.start() }
                let vis = s.vision
                runtime.bodySource = { vis.current() }
                s.vision.setRunning(runtime.usesBodyNodes)
                let m = midi
                runtime.midiSource = { m.current() }          // was never assigned → MIDI nodes read 0
                if runtime.usesMidiNodes { midi.start() }
                // NDI output tap — renderer pulls the live config each frame.
                let n = ndi
                renderer.ndi = n
                renderer.ndiConfigProvider = { rt.ndiRenderConfig() }
                // Record tap — renderer pulls the live config each frame, captures to Photos.
                let rc = recorder
                renderer.recorder = rc
                renderer.recordConfigProvider = { rt.recordRenderConfig() }
            }
        }
    }

    // MARK: contextual wire bar (delete a selected wire)

    private func wireBar(_ w: Wire) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.text2).frame(width: 10, height: 10)
            Text("WIRE").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Text("\(w.fromNode).\(w.fromPort) → \(w.toNode).\(w.toPort)")
                .font(.system(size: 9).monospaced()).foregroundStyle(Theme.text2).lineLimit(1)
            Spacer()
            Button {
                runtime.removeWire(w)
                selectedWire = nil
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                    Text("DELETE").font(.system(size: 6, weight: .semibold)).tracking(0.5)
                }
                .foregroundStyle(Theme.text)
                .frame(width: 46, height: 34)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: edge swipe-indicator handle

    private var edgeHandle: some View {
        // Two views now: LEFT edge (node view) → camera, camera's right edge → node.
        EdgeSwitchHandle(toNodes: !nodesOn) { setNodes(!nodesOn) }
    }

    // MARK: add node (with TouchDesigner-style insert on the selected wire)

    private func addNode(_ spec: NodeSpec) {
        defer { selectedWire = nil; pendingConnect = nil; pendingConnectInput = nil; palette = nil }
        let reg = NodeRegistry.shared

        // Dropped a NEW wire from an output → place the node at the drop point and auto-connect
        // this source into its first compatible input.
        if let pc = pendingConnect, let ns = reg.spec(spec.id),
           let inPort = ns.inputs.first(where: { $0.type.accepts(pc.type) }) {
            if let id = runtime.addNode(spec.id, at: pc.world + [0, -Float(NodeMetrics.height(ns)) / 2]) {
                _ = runtime.connect(from: pc.from, fromPort: pc.port, to: id, toPort: inPort.name)
                selection = [id]
            }
            return
        }

        // Dropped a NEW wire from an INPUT → place the node to the LEFT and feed its
        // compatible output into this input.
        if let pc = pendingConnectInput, let ns = reg.spec(spec.id),
           let outPort = ns.outputs.first(where: { pc.type.accepts($0.type) }) {
            if let id = runtime.addNode(spec.id, at: pc.world + [-Float(NodeMetrics.width) - 30,
                                                                 -Float(NodeMetrics.height(ns)) / 2]) {
                _ = runtime.connect(from: id, fromPort: outPort.name, to: pc.from, toPort: pc.port)
                selection = [id]
            }
            return
        }

        // If a wire is selected and the new node has a compatible in + out, splice it in-line.
        if let w = selectedWire, let ns = reg.spec(spec.id),
           let outType = reg.spec(runtime.activeGraph.node(w.fromNode)?.specID ?? "")?
               .outputs.first(where: { $0.name == w.fromPort })?.type,
           let inType = reg.spec(runtime.activeGraph.node(w.toNode)?.specID ?? "")?
               .inputs.first(where: { $0.name == w.toPort })?.type,
           let inPort = ns.inputs.first(where: { $0.type.accepts(outType) }),
           let outPort = ns.outputs.first(where: { inType.accepts($0.type) }) {
            let from = runtime.activeGraph.node(w.fromNode)?.position ?? .zero
            let to = runtime.activeGraph.node(w.toNode)?.position ?? .zero
            let at = (from + to) / 2 + [0, -30]
            if let id = runtime.addNode(spec.id, at: at) {
                runtime.removeWire(w)
                _ = runtime.connect(from: w.fromNode, fromPort: w.fromPort, to: id, toPort: inPort.name)
                _ = runtime.connect(from: id, fromPort: outPort.name, to: w.toNode, toPort: w.toPort)
                selection = [id]
            }
            return
        }

        // Otherwise drop into the middle of the current canvas, stepped so repeats fan out.
        let mid = editorCamera.toWorld(CGPoint(x: editorCamera.viewSize.width / 2,
                                               y: editorCamera.viewSize.height / 2))
        let n = Float(runtime.activeGraph.nodes.count % 5)
        if let id = runtime.addNode(spec.id, at: mid + [-80 + n * 30, -60 + n * 34]) {
            selection = [id]
        }
    }
}

/// The camera ↔ node view switch bar on the screen edge. On tap it flashes fully opaque white
/// (so the tap reads) and a stemless arrow (a chevron — the SF arrow minus its shaft) drifts in
/// the direction you're moving, then fades.
private struct EdgeSwitchHandle: View {
    let toNodes: Bool          // true → camera→node (arrow right); false → node→camera (arrow left)
    let onTap: () -> Void
    @State private var anim = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(anim ? Color.white : Theme.text2.opacity(0.66))
                .frame(width: 6, height: 54)
            Image(systemName: toNodes ? "chevron.right" : "chevron.left")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .opacity(anim ? 1 : 0)
                .offset(x: anim ? 0 : (toNodes ? 20 : -20))
        }
        .frame(width: 24, height: 100)          // invisible tap target
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            anim = true                          // snap: opaque-white bar + arrow at centre
            onTap()
            DispatchQueue.main.async {            // then flash back + arrow drifts out & fades
                withAnimation(.easeOut(duration: 0.4)) { anim = false }
            }
        }
    }
}

#Preview {
    ContentView()
}
