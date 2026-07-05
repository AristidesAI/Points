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
    @State private var picked: (url: URL, isVideo: Bool)?
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
            MediaPicker { url, isVideo in picked = (url, isVideo) }.ignoresSafeArea()
        }
    }

    // MARK: setup

    private var setupScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Import depth", "One-time on-device MoGe-2 bake → depth. Photo or video.")
            Button { showPicker = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "photo.badge.plus")
                    Text(picked == nil ? "Choose a photo or video…" : picked!.url.lastPathComponent).lineLimit(1)
                    Spacer()
                    if picked != nil { Image(systemName: "checkmark").foregroundStyle(Color(hex: 0x4DD0FF)) }
                }
                .font(.system(size: 13, weight: .medium))
                .padding(14).background(Theme.panel).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if let p = picked {
                Text(p.isVideo ? "Video → MoGe-2 per frame (sampled ~6 fps for this test)."
                               : "Photo → a single MoGe-2 bake.")
                    .font(.system(size: 10)).foregroundStyle(Theme.text2)
                picker("SCENE", BakeOptions.SceneKind.allCases, options.scene) { options.scene = $0 }
                picker("QUALITY", BakeOptions.Quality.allCases, options.quality) { options.quality = $0 }
            }
            Spacer()
            Button {
                if let p = picked { bake.start(url: p.url, isVideo: p.isVideo, options: options) }
            } label: {
                Text("Start processing").font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(14)
                    .background(picked == nil ? Theme.panel : Color(hex: 0x2E7BFF))
                    .foregroundStyle(picked == nil ? Theme.text2 : .white)
                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(picked == nil)
            closeButton
        }
    }

    // MARK: baking

    private var bakeScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Processing", bake.sourceName)
            depthPreview
            Spacer()
            Text(String(format: "%.0f%%", bake.progress * 100))
                .font(.system(size: 56, weight: .heavy).monospacedDigit())
                .foregroundStyle(Color(hex: 0x4DD0FF))
            VStack(alignment: .leading, spacing: 6) {
                stat("FRAME", bake.totalFrames > 0 ? "\(bake.currentFrame) / \(bake.totalFrames)" : "…")
                stat("SPEED", bake.fps > 0 ? String(format: "%.0f fps", bake.fps) : "…")
                stat("ETA", bake.etaSeconds > 0 ? etaText(bake.etaSeconds) : "…")
            }
            Text("Keeps processing if you leave the app — watch the Dynamic Island.")
                .font(.system(size: 10)).foregroundStyle(Theme.text2)
            if !bake.bgStatus.isEmpty {
                Text(bake.bgStatus).font(.system(size: 9).monospaced()).foregroundStyle(Theme.text2.opacity(0.7))
            }
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

    /// Live depth map coming out of the model — the proof it's working.
    private var depthPreview: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let img = bake.previewImage {
                Image(decorative: img, scale: 1, orientation: .up)
                    .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
            } else {
                Text("Preparing engine…").font(.system(size: 11)).foregroundStyle(Theme.text2)
            }
        }
        .frame(height: 240).frame(maxWidth: .infinity).clipped()
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Text("DEPTH").font(.system(size: 8, weight: .bold)).tracking(1.2).foregroundStyle(.white)
                .padding(4).background(Color.black.opacity(0.6)).padding(6)
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

// MARK: - PHPicker (photo or video → a stable temp URL + which kind)

struct MediaPicker: UIViewControllerRepresentable {
    var onPick: (URL, Bool) -> Void          // (url, isVideo)
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.videos, .images])
        config.selectionLimit = 1
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL, Bool) -> Void
        init(onPick: @escaping (URL, Bool) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let type = isVideo ? UTType.movie.identifier : UTType.image.identifier
            // The provided URL is deleted when the closure returns → copy it somewhere stable.
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return }
                let ext = isVideo ? "mov" : (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try? FileManager.default.copyItem(at: url, to: dst)
                Task { @MainActor in self.onPick(dst, isVideo) }
            }
        }
    }
}
