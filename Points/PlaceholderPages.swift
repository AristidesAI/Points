import SwiftUI

// Placeholder pages for every planned app function — flat SIGNAL theme, sharp rectangles.
// Real logic lands per Plans/08 phases; these prove navigation + layout on-device.

// MARK: - Shared flat chrome

struct FlatHeader: View {
    let title: String
    var subtitle: String? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.text2)
                }
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 30)
                        .background(Theme.panel)
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

struct ComingBadge: View {
    var body: some View {
        Text("PLACEHOLDER — LOGIC LANDS IN A LATER PHASE")
            .font(.system(size: 8, weight: .semibold)).tracking(1)
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }
}

// MARK: - Project browser (launch screen)

struct BrowserView: View {
    var onOpen: (String?) -> Void          // template name (nil = blank / project)

    private let projects = [("Live Session", "front depth · just now"),
                            ("Face Study 3", "front depth · 2h ago"),
                            ("Imported: skate.mov", "media · placeholder")]
    private let templates = ["Pure Pins", "Comet Trails", "Arm Fire", "Beat Strobe", "Kick Shatter"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("POINTS").font(.system(size: 18, weight: .bold)).tracking(2).foregroundStyle(Theme.text)
                Spacer()
                ComingBadge()
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("TEMPLATES").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(Theme.text2).padding(.horizontal, 18)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(templates, id: \.self) { t in
                                Button { onOpen(t) } label: { templateCard(t) }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                    }

                    Text("PROJECTS").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(Theme.text2).padding(.horizontal, 18).padding(.top, 8)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                              spacing: 12) {
                        Button { onOpen(nil) } label: { newCard }.buttonStyle(.plain)
                        Button { onOpen("Max Complexity") } label: { maxComplexityCard }.buttonStyle(.plain)
                        Button { onOpen("Trigger Test") } label: { triggerTestCard }.buttonStyle(.plain)
                        ForEach(projects, id: \.0) { p in
                            Button { onOpen(nil) } label: { projectCard(p.0, p.1) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.bottom, 30)
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func templateCard(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.black)
                .overlay(Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 26)).foregroundStyle(Theme.text2.opacity(0.5)))
            Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(8)
        }
        .frame(width: 116, height: 116)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    private var triggerTestCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.black)
                .overlay(Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 30)).foregroundStyle(Color(hex: 0xFFC24D).opacity(0.7)))
            VStack(alignment: .leading, spacing: 2) {
                Text("TRIGGER TEST").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                Text("nested triggers · Size pops on beat").font(.system(size: 8)).foregroundStyle(Theme.text2)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    private var maxComplexityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.black)
                .overlay(Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 30)).foregroundStyle(Theme.text2.opacity(0.55)))
            VStack(alignment: .leading, spacing: 2) {
                Text("MAX COMPLEXITY").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                Text("demo · every lane wired").font(.system(size: 8)).foregroundStyle(Theme.text2)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    private var newCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.text)
            Text("NEW PROJECT").font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).aspectRatio(1, contentMode: .fit)   // greedy → fills the W×W square (was short/wide)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    private func projectCard(_ name: String, _ meta: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.black)
                .overlay(Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 30)).foregroundStyle(Theme.text2.opacity(0.4)))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                Text(meta).font(.system(size: 8)).foregroundStyle(Theme.text2)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }
}

// MARK: - Import (contextual — opens from the source)

struct ImportPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var domain = 0
    @State private var quality = 0

    var body: some View {
        VStack(spacing: 14) {
            FlatHeader(title: "Import Media",
                       subtitle: "Video/photo → one-time on-device depth bake",
                       onClose: { dismiss() })
            Rectangle().fill(Color.black).frame(height: 170)
                .overlay(VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 28)).foregroundStyle(Theme.text2)
                    Text("PICK FROM LIBRARY").font(.system(size: 9, weight: .semibold)).tracking(1)
                        .foregroundStyle(Theme.text2)
                })
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                .padding(.horizontal, 16)
            segRow("SCENE", ["INDOOR ≤20m", "OUTDOOR ≤80m"], $domain)
            segRow("QUALITY", ["BEST · video-native", "FAST · per-frame"], $quality)
            Text("Depth is computed once on this device, then replays forever.\nML bake pipeline lands next (Plans/04).")
                .font(.system(size: 10)).foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
            ComingBadge()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func segRow(_ label: String, _ options: [String], _ sel: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.text2)
            HStack(spacing: 1) {
                ForEach(options.indices, id: \.self) { i in
                    Button { sel.wrappedValue = i } label: {
                        Text(options[i]).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(sel.wrappedValue == i ? Color.black : Theme.text2)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(sel.wrappedValue == i ? Theme.text : Theme.panel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Settings

struct SettingsPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tutorialDone") private var tutorialDone = false
    @AppStorage("wireStyle") private var wireStyle = 0   // 0 curved · 1 straight · 2 right-angle
    @AppStorage("newNodeFromOutput") private var newNodeFromOutput = true
    @AppStorage("newNodeFromInput") private var newNodeFromInput = true
    private let wireNames = ["CURVED", "STRAIGHT", "RIGHT ANGLE"]

    var body: some View {
        VStack(spacing: 0) {
            FlatHeader(title: "Settings", onClose: { dismiss() })
            ScrollView {
                VStack(spacing: 10) {
                    Button {
                        wireStyle = (wireStyle + 1) % 3
                    } label: {
                        HStack {
                            Text("Node wires").font(.system(size: 12)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(wireNames[wireStyle])
                                .font(.system(size: 10, weight: .semibold)).tracking(1)
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.text)
                        }
                        .padding(12)
                        .background(Theme.panel)
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    FlatToggleRow(title: "New node from OUTPUT drop",
                                  subtitle: "drop a wire off an output on empty → pick a node",
                                  isOn: $newNodeFromOutput)
                    FlatToggleRow(title: "New node from INPUT drop",
                                  subtitle: "drop a wire off an input on empty → pick a source",
                                  isOn: $newNodeFromInput)
                    row("Render frame rate", "30 · 60 · 120")
                    row("Marathon mode", "cap 100k / 30fps")
                    row("Thermal ladder", "auto")
                    row("Share code", "graph → QR")
                    Button {
                        tutorialDone = false
                        dismiss()
                    } label: {
                        HStack {
                            Text("Replay tutorial").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.black)
                            Spacer()
                            Image(systemName: "arrow.counterclockwise").foregroundStyle(Color.black)
                        }
                        .padding(12)
                        .background(Theme.text)
                    }
                    .buttonStyle(.plain)
                    ComingBadge().padding(.top, 8)
                }
                .padding(16)
            }
        }
        .background(Theme.bg)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
            Spacer()
            Text(value).font(.system(size: 10)).foregroundStyle(Theme.text2)
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }
}

/// Flat on/off switch in the app's own style — no Apple `Toggle`. Tap flips it.
/// ON = white fill / black text · OFF = black fill / white text.
struct FlatToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 9)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                }
                Spacer()
                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                    .foregroundStyle(isOn ? Color.black : Theme.text)
                    .frame(width: 52, height: 26)
                    .background(isOn ? Theme.text : Color.black)
                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .padding(12)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Record / NDI stubs

struct RecordPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            FlatHeader(title: "Record", subtitle: "GPU-direct HEVC → Photos", onClose: { dismiss() })
            infoSquare("record.circle", "Up to 2880×3840 (4:3 4K) @60.\nOne tap → auto-saves to Photos.\nLive node editing keeps working while recording.")
            ComingBadge()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

struct NDIPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            FlatHeader(title: "NDI Output", subtitle: "Clean 3:4 feed to the network", onClose: { dismiss() })
            infoSquare("antenna.radiowaves.left.and.right",
                       "810×1080 / 1080×1440 / 1620×2160 @30 or 60.\nOptional alpha-keyed background for compositing.")
            ComingBadge()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

private func infoSquare(_ symbol: String, _ text: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Theme.text2)
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.text2)
            .multilineTextAlignment(.center).lineSpacing(3)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 26)
    .background(Theme.panel)
    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    .padding(.horizontal, 16)
}

// MARK: - Node palette (REAL — driven by the registry)

struct NodePaletteView: View {
    var acceptsType: PortType? = nil          // set when adding onto a dropped output wire
    var producesType: PortType? = nil         // set when adding onto a dropped input wire (needs a matching output)
    var onAdd: ((NodeSpec) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("paletteGrid") private var gridMode = false   // list ↔ TouchDesigner OP-grid
    @AppStorage("recentNodeIDs") private var recentCSV = ""   // last-added spec ids (most-recent first, ≤6)
    @AppStorage("favNodeIDs") private var favCSV = ""         // starred spec ids (set in the detail card)
    @State private var search = ""
    @State private var detail: NodeSpec?
    @State private var holdingID: String?
    @State private var gridFamily: NodeFamily = .source

    private var recentIDs: [String] { recentCSV.split(separator: ",").map(String.init) }
    private var favIDs: [String] { favCSV.split(separator: ",").map(String.init) }
    private func recordRecent(_ spec: NodeSpec) {
        var ids = recentIDs.filter { $0 != spec.id }
        ids.insert(spec.id, at: 0)
        recentCSV = ids.prefix(6).joined(separator: ",")
    }
    /// Every add routes through here so it lands in the Recent strip.
    private func add(_ spec: NodeSpec) { recordRecent(spec); onAdd?(spec) }

    /// Horizontal strip of quick-add chips (Recent / Favourites) — tap a chip to add it.
    @ViewBuilder private func quickStrip(_ title: String, _ ids: [String]) -> some View {
        let specs = ids.compactMap { NodeRegistry.shared.spec($0) }.filter(matches)
        if !specs.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 9, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.text2).padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(specs, id: \.id) { spec in
                            HStack(spacing: 5) {
                                Rectangle().fill(familyColor(spec.family)).frame(width: 5, height: 16)
                                Text(spec.name).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.text).lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Theme.panel)
                            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                            .contentShape(Rectangle())
                            .onTapGesture { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); add(spec) }
                        }
                    }.padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func matches(_ s: NodeSpec) -> Bool {
        !NodeRegistry.triggerOnlyIDs.contains(s.id)   // flat model: Drive Param is obsolete → hidden
            && (search.isEmpty || s.name.localizedCaseInsensitiveContains(search))
            && (acceptsType == nil || s.inputs.contains { $0.type.accepts(acceptsType!) })
            && (producesType == nil || s.outputs.contains { producesType!.accepts($0.type) })
    }

    private var families: [(NodeFamily, [NodeSpec])] {
        let all = NodeRegistry.shared.allSpecs
        return NodeFamily.allCases.compactMap { fam in
            let members = all.filter { $0.family == fam && matches($0) }.sorted { $0.name < $1.name }
            return members.isEmpty ? nil : (fam, members)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TextField("search", text: $search)
                .font(.system(size: 12))
                .padding(10)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            if gridMode { gridBody } else { listBody }
        }
        .background(Theme.bg)
        // Details = a full-bleed bottom panel (not a system sheet) so it reaches the screen edges.
        .overlay(alignment: .bottom) {
            if let spec = detail {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.55).ignoresSafeArea()
                        .onTapGesture { detail = nil }
                    NodeSpecCard(spec: spec, onAdd: onAdd == nil ? nil : { s in detail = nil; add(s) })
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: detail?.id)
        .onAppear {
            // Land the grid on the first family that actually has matches.
            if let first = families.first?.0 { gridFamily = first }
        }
    }

    // Custom header: title · [list/grid toggle] · close (toggle sits just left of close).
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(acceptsType == nil ? "Nodes" : "Connect wire →")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(acceptsType == nil
                     ? "\(NodeRegistry.shared.allSpecs.count) nodes · tap = details · hold = add"
                     : "showing only nodes that accept this wire")
                    .font(.system(size: 10)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer()
            headerButton(gridMode ? "list.bullet" : "square.grid.2x2") { gridMode.toggle() }
            headerButton("xmark") { dismiss() }
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
    }

    private func headerButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 34, height: 30).background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: list mode

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4, pinnedViews: .sectionHeaders) {
                quickStrip("RECENT", recentIDs)
                quickStrip("FAVOURITES", favIDs)
                ForEach(families, id: \.0) { fam, specs in
                    Section {
                        ForEach(specs, id: \.id) { spec in
                            specRow(spec, holding: holdingID == spec.id)
                                .contentShape(Rectangle())
                                .onTapGesture { detail = spec }
                                .onLongPressGesture(minimumDuration: 0.55) {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    add(spec)
                                } onPressingChanged: { holdingID = $0 ? spec.id : nil }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Rectangle().fill(familyColor(fam)).frame(width: 10, height: 10)
                            Text(fam.rawValue).font(.system(size: 10, weight: .bold)).tracking(1.4)
                                .foregroundStyle(Theme.text)
                            Text("\(specs.count)").font(.system(size: 9)).foregroundStyle(Theme.text2)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Theme.bg)
                    }
                }
            }
            .padding(.bottom, 30)
        }
    }

    // MARK: grid mode — TouchDesigner OP-menu: family bar on top (swipe), nodes as cubes below.

    private var gridSpecs: [NodeSpec] {
        NodeRegistry.shared.allSpecs.filter { $0.family == gridFamily && matches($0) }.sorted { $0.name < $1.name }
    }

    private var gridBody: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(NodeFamily.allCases, id: \.self) { fam in
                        let count = NodeRegistry.shared.allSpecs.filter { $0.family == fam && matches($0) }.count
                        Button { gridFamily = fam } label: {
                            HStack(spacing: 5) {
                                Rectangle().fill(familyColor(fam)).frame(width: 8, height: 8)
                                Text(fam.rawValue).font(.system(size: 10, weight: .bold)).tracking(1)
                                Text("\(count)").font(.system(size: 8).monospacedDigit())
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .foregroundStyle(gridFamily == fam ? Color.black : Theme.text)
                            .background(gridFamily == fam ? Theme.text : Theme.panel)
                            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                            .opacity(count == 0 ? 0.35 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(count == 0)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            // 3 across, fitted to the screen width, scrolling DOWN in rows of 3 (fills the screen).
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(gridSpecs, id: \.id) { spec in nodeCube(spec) }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func nodeCube(_ spec: NodeSpec) -> some View {
        let holding = holdingID == spec.id
        return VStack(spacing: 4) {
            Text(spec.name).font(.system(size: 9.5, weight: .semibold))
                .multilineTextAlignment(.center).lineLimit(2)
                .foregroundStyle(holding ? Color.black : Theme.text)
            Text(portSummary(spec)).font(.system(size: 7)).lineLimit(1)
                .foregroundStyle(holding ? Color.black.opacity(0.7) : Theme.text2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 66)
        .padding(4)
        .background(holding ? Theme.text : Theme.panel)
        .overlay(Rectangle().stroke(holding ? Color.white : familyColor(spec.family),
                                    lineWidth: holding ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { detail = spec }
        .onLongPressGesture(minimumDuration: 0.55) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            add(spec)
        } onPressingChanged: { holdingID = $0 ? spec.id : nil }
        .animation(.easeOut(duration: 0.5), value: holding)
    }

    private func specRow(_ spec: NodeSpec, holding: Bool) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(familyColor(spec.family)).frame(width: 6, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(spec.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(holding ? Color.black : Theme.text)
                Text(holding ? "keep holding to add…" : portSummary(spec))
                    .font(.system(size: 8))
                    .foregroundStyle(holding ? Color.black.opacity(0.7) : Theme.text2)
            }
            Spacer()
            if spec.statePerPin > 0 {
                Text("\(spec.statePerPin)f/pin").font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(holding ? Color.black.opacity(0.7) : Theme.text2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .background(holding ? Theme.text : Theme.panel.opacity(0.5))
        .overlay(Rectangle().stroke(holding ? Theme.text : Theme.line.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.5), value: holding)
    }

    private func portSummary(_ spec: NodeSpec) -> String {
        let ins = spec.inputs.map(\.name).joined(separator: " · ")
        let outs = spec.outputs.map(\.name).joined(separator: " · ")
        switch (ins.isEmpty, outs.isEmpty) {
        case (true, true): return "no ports"
        case (true, false): return "→ \(outs)"
        case (false, true): return "\(ins) →"
        default: return "\(ins) → \(outs)"
        }
    }
}

extension NodeSpec: Identifiable {}

struct NodeSpecCard: View {
    let spec: NodeSpec
    var onAdd: ((NodeSpec) -> Void)? = nil
    @AppStorage("favNodeIDs") private var favCSV = ""

    private var isFav: Bool { favCSV.split(separator: ",").map(String.init).contains(spec.id) }
    private func toggleFav() {
        var ids = favCSV.split(separator: ",").map(String.init)
        if let i = ids.firstIndex(of: spec.id) { ids.remove(at: i) } else { ids.append(spec.id) }
        favCSV = ids.joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Rectangle().fill(familyColor(spec.family)).frame(width: 12, height: 12)
                Text(spec.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text(spec.family.rawValue).font(.system(size: 9, weight: .semibold)).tracking(1)
                    .foregroundStyle(Theme.text2)
                if onAdd != nil {
                    // Favourite toggle — sits just left of ADD; adds/removes this node from the
                    // Favourites strip at the top of the palette.
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        toggleFav()
                    } label: {
                        Image(systemName: isFav ? "star.fill" : "star")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isFav ? Color(hex: 0xFFC24D) : Theme.text2)
                            .frame(width: 34, height: 30)
                            .background(Theme.panel)
                            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(PadPressStyle())
                    // Tap adds the node and closes the palette (hold-a-row on the list also works).
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onAdd?(spec)
                    } label: {
                        Text("ADD +")
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .foregroundStyle(Theme.text)
                            .frame(width: 64, height: 30)
                            .background(Theme.panel)
                            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(PadPressStyle())
                }
            }
            Text(spec.description).font(.system(size: 12)).foregroundStyle(Theme.text2).lineSpacing(3)
            if !spec.inputs.isEmpty {
                portList("INPUTS", spec.inputs)
            }
            if !spec.outputs.isEmpty {
                portList("OUTPUTS", spec.outputs)
            }
            if !spec.params.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PARAMS").font(.system(size: 8, weight: .bold)).tracking(1.4).foregroundStyle(Theme.text2)
                    ForEach(spec.params, id: \.name) { p in
                        HStack {
                            Text(p.name).font(.system(size: 10)).foregroundStyle(Theme.text)
                            Spacer()
                            if let r = p.range {
                                Text("\(String(format: "%g", r.lowerBound)) … \(String(format: "%g", r.upperBound))")
                                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.text2)
                            } else if let o = p.options {
                                Text(o.joined(separator: " · ")).font(.system(size: 8)).foregroundStyle(Theme.text2)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Flat black, square, edge-to-edge — the background reaches the very bottom of the screen.
        .background(Theme.bg.ignoresSafeArea(edges: .bottom))
    }

    private func portList(_ label: String, _ ports: [PortSpec]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 8, weight: .bold)).tracking(1.4).foregroundStyle(Theme.text2)
            ForEach(ports, id: \.name) { p in
                HStack(spacing: 6) {
                    Circle().fill(portColor(p.type)).frame(width: 7, height: 7)
                    Text(p.name).font(.system(size: 10)).foregroundStyle(Theme.text)
                    Text(p.type.rawValue).font(.system(size: 8)).foregroundStyle(Theme.text2)
                }
            }
        }
    }
}

// MARK: - shared color maps

func familyColor(_ f: NodeFamily) -> Color {
    switch f {
    case .source: return Theme.famSource
    case .grid: return Theme.famGrid
    case .filter: return Theme.famFilter
    case .shape: return Theme.famShape
    case .move: return Theme.famMove
    case .color: return Theme.famColor
    case .signal: return Theme.famSignal
    case .body: return Theme.famBody
    case .time: return Theme.famTime
    case .stage: return Theme.famStage
    case .output: return Theme.famOutput
    case .tools: return Theme.famTools
    }
}

func portColor(_ t: PortType) -> Color {
    switch t {
    case .signal: return .white
    case .vec2, .vec3: return Color(hex: 0x8FA0B8)
    case .color: return Theme.famColor
    case .trigger: return Color(hex: 0xFFC24D)
    case .fieldFloat: return Color(hex: 0x4FD8C6)
    case .fieldVec3: return Color(hex: 0x6F9FDD)
    case .fieldColor: return Color(hex: 0xE06FC8)
    case .domain: return Theme.famGrid
    case .source: return Theme.famSource
    }
}
