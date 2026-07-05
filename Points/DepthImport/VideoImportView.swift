import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// The video-processing screen (reached from the corner-menu import button). Pick a clip → choose
// Indoor/Outdoor + quality → bake. While baking, the clockwise screen-edge loop fills and the
// system shows the same progress in the Dynamic Island (BGContinuedProcessingTask) so it keeps
// going when the app is minimised. GROUNDWORK: the bake is simulated (StubDepthModel) — see
// DepthBakeManager / Plans/04-Depth-Import-Pipeline.md.

struct VideoImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bake = DepthBakeManager()
    @State private var pickedURL: URL?
    @State private var options = BakeOptions()
    @State private var showPicker = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Group {
                switch bake.stage {
                case .baking, .preparing: bakeScreen
                case .done, .cancelled, .failed: resultScreen
                default: setupScreen
                }
            }
            .padding(24)
            if bake.isRunning { ScreenEdgeProgress(progress: bake.progress) }   // the clockwise edge loop
        }
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showPicker) {
            VideoPicker { url in pickedURL = url }.ignoresSafeArea()
        }
    }

    // MARK: setup

    private var setupScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Import depth video", "One-time on-device metric-depth bake → looped point cloud.")
            Button { showPicker = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "film.stack")
                    Text(pickedURL == nil ? "Choose a video…" : (pickedURL?.lastPathComponent ?? "")).lineLimit(1)
                    Spacer()
                    if pickedURL != nil { Image(systemName: "checkmark").foregroundStyle(Color(hex: 0x4DD0FF)) }
                }
                .font(.system(size: 13, weight: .medium))
                .padding(14).background(Theme.panel).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if pickedURL != nil {
                picker("SCENE", BakeOptions.SceneKind.allCases, options.scene) { options.scene = $0 }
                picker("QUALITY", BakeOptions.Quality.allCases, options.quality) { options.quality = $0 }
                Text(options.quality == .best
                     ? "Best: video-consistent model (Depth Anything Video) — slower, no flicker."
                     : "Fast: per-frame model (Depth Anything V2-S) — quicker, polished on top.")
                    .font(.system(size: 10)).foregroundStyle(Theme.text2)
            }
            Spacer()
            Button {
                if let url = pickedURL { bake.start(url: url, options: options) }
            } label: {
                Text("Start processing").font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(14)
                    .background(pickedURL == nil ? Theme.panel : Color(hex: 0x2E7BFF))
                    .foregroundStyle(pickedURL == nil ? Theme.text2 : .white)
                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(pickedURL == nil)
            closeButton
        }
    }

    // MARK: baking

    private var bakeScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Processing", bake.sourceName)
            Spacer()
            Text(String(format: "%.0f%%", bake.progress * 100))
                .font(.system(size: 64, weight: .heavy).monospacedDigit())
                .foregroundStyle(Color(hex: 0x4DD0FF))
            VStack(alignment: .leading, spacing: 6) {
                stat("FRAME", bake.totalFrames > 0 ? "\(bake.currentFrame) / \(bake.totalFrames)" : "…")
                stat("SPEED", bake.fps > 0 ? String(format: "%.0f fps", bake.fps) : "…")
                stat("ETA", bake.etaSeconds > 0 ? etaText(bake.etaSeconds) : "…")
            }
            Text("Keeps processing if you leave the app — watch the Dynamic Island.")
                .font(.system(size: 10)).foregroundStyle(Theme.text2)
            Spacer()
            Button { bake.cancel() } label: {
                Text("Cancel").font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(14)
                    .background(Theme.panel).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var resultScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: bake.stage == .done ? "checkmark.circle" : "xmark.circle")
                .font(.system(size: 54)).foregroundStyle(bake.stage == .done ? Color(hex: 0x4DD0FF) : Theme.text2)
            Text(resultText).font(.system(size: 15, weight: .semibold))
            Text("Playback + the Source-node transport land with the real model bake.")
                .font(.system(size: 10)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            Spacer()
            Button { dismiss() } label: {
                Text("Done").font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(14)
                    .background(Theme.panel).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var resultText: String {
        switch bake.stage {
        case .done: return "Baked \(bake.totalFrames) frames"
        case .cancelled: return "Cancelled"
        case .failed(let m): return "Failed — \(m)"
        default: return ""
        }
    }

    // MARK: bits

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .bold))
            Text(sub).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Theme.text2)
            Spacer()
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: 260)
    }

    private func etaText(_ s: Double) -> String {
        s >= 60 ? String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) : String(format: "%.0fs", s)
    }

    /// Two-box tap-select row in the app's flat style.
    private func picker<T: RawRepresentable & Hashable>(_ title: String, _ all: [T], _ sel: T,
                                                         _ set: @escaping (T) -> Void) -> some View
    where T.RawValue == String {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Theme.text2)
            HStack(spacing: 6) {
                ForEach(all, id: \.self) { opt in
                    Text(opt.rawValue).font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(sel == opt ? Theme.text : Theme.panel)
                        .foregroundStyle(sel == opt ? Color.black : Theme.text)
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                        .onTapGesture { set(opt) }
                }
            }
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Text("Close").font(.system(size: 12)).foregroundStyle(Theme.text2)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PHPicker (video only, copies the pick to a stable temp URL)

struct VideoPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            // The provided URL is deleted when the closure returns → copy it somewhere stable.
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url else { return }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                try? FileManager.default.copyItem(at: url, to: dst)
                Task { @MainActor in self.onPick(dst) }
            }
        }
    }
}
