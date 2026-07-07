import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// The media-processing screen (reached from the Vision Model node's image/video button). The
// gallery opens immediately; picking a photo/video starts the MoGe-2 bake at once behind the
// clockwise screen-edge loop, and finishing returns straight to the app (no setup or result
// pages). The Dynamic Island shows progress if the app is minimised.

struct VideoImportView: View {
    var onBaked: ((Bool) -> Void)? = nil        // (isVideo) — mark the node's media flag
    @Environment(\.dismiss) private var dismiss
    @State private var bake = DepthBakeManager()
    @State private var picked: (url: URL, isVideo: Bool)?
    @State private var showPicker = true        // straight into the gallery — no setup screen

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if bake.isRunning { bakeScreen.padding(24) }
            if bake.isRunning { ScreenEdgeProgress(progress: bake.progress) }   // the clockwise edge loop
        }
        .foregroundStyle(Theme.text)
        // While baking, go full-bleed: hide the status bar + home indicator so the clockwise loop
        // traces the whole display edge (incl. above the clock/Island), then restore on completion.
        .statusBarHidden(bake.isRunning)
        .persistentSystemOverlays(bake.isRunning ? .hidden : .automatic)
        // Pick → processing starts IMMEDIATELY (MoGe-2); cancelling the picker returns to the app.
        .sheet(isPresented: $showPicker,
               onDismiss: { if picked == nil { dismiss() } }) {
            MediaPicker { url, isVideo in
                picked = (url, isVideo)
                bake.start(url: url, isVideo: isVideo, options: BakeOptions(), model: LiveModel.all[0])
            }.ignoresSafeArea()
        }
        // Done/cancelled/failed → straight back to the app, no result page. The media is loaded;
        // wire the Vision Model node's outputs to see it.
        .onChange(of: bake.stage) { _, st in
            switch st {
            case .done:
                if let p = picked { onBaked?(p.isVideo) }
                dismiss()
            case .cancelled, .failed: dismiss()
            default: break
            }
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
