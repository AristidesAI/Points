import AVFoundation
import CoreVideo
import simd

// Plain RGB capture for the LIVE depth-model nodes: phones without back LiDAR (and the MoGe-2 live
// test) run the back/front camera's colour frames through a CoreML depth model → point cloud. This
// is separate from CameraSources' TrueDepth/LiDAR depth paths. Lens-selectable (ultrawide / wide /
// tele / front). Frames are delivered BGRA on a capture queue.

nonisolated final class RGBCameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Lens: String, CaseIterable, Sendable {
        case ultraWide = "Ultra-wide", wide = "Wide", tele = "Tele", front = "Front"
        var position: AVCaptureDevice.Position { self == .front ? .front : .back }
        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .ultraWide: return .builtInUltraWideCamera
            case .tele: return .builtInTelephotoCamera
            case .wide, .front: return .builtInWideAngleCamera
            }
        }
    }

    /// The exact capture device for a lens, via DiscoverySession (more reliable than
    /// `AVCaptureDevice.default(deviceType:…)`, which can return nil for ultra-wide / tele and
    /// silently fall back to wide → "the back lenses don't switch"). Falls back to wide if absent.
    static func device(for lens: Lens) -> AVCaptureDevice? {
        let ds = AVCaptureDevice.DiscoverySession(
            deviceTypes: [lens.deviceType, .builtInWideAngleCamera],
            mediaType: .video, position: lens.position)
        return ds.devices.first { $0.deviceType == lens.deviceType } ?? ds.devices.first
    }

    /// Lenses this device actually has (so the node's camera switcher only shows real cameras).
    static func availableLenses() -> [Lens] {
        let found = Lens.allCases.filter { lens in
            AVCaptureDevice.DiscoverySession(deviceTypes: [lens.deviceType], mediaType: .video,
                                             position: lens.position).devices.isEmpty == false
        }
        return found.isEmpty ? [.wide, .front] : found
    }

    /// (bgra frame, normalized intrinsics fx/fy/cx/cy for METRIC mode). Called on the capture queue.
    var onFrame: (@Sendable (CVPixelBuffer, SIMD4<Float>) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "points.rgbcam", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var lens: Lens = .wide
    private var running = false

    func start(lens: Lens) {
        queue.async { [self] in
            // Idempotent ONLY when the session is genuinely healthy on this lens — a session that
            // came up without an input (camera still held by the departing TrueDepth/LiDAR session)
            // used to early-return here forever, so re-tapping the same lens never recovered it.
            if running && lens == self.lens && session.isRunning && !session.inputs.isEmpty { return }
            // Switching to a DIFFERENT physical camera on a running session is unreliable (the input
            // swap can silently fail to take) — stop the session, reconfigure, restart. That's what
            // actually makes the lens switcher change the feed.
            let switching = session.isRunning
            self.lens = lens
            if switching { session.stopRunning() }
            let ok = configure()
            session.startRunning()
            running = true
            if !ok {
                // Camera not free yet (handoff race) — one retry once the other session let go.
                queue.asyncAfter(deadline: .now() + 0.4) { [self] in
                    guard running, session.inputs.isEmpty else { return }
                    if session.isRunning { session.stopRunning() }
                    _ = configure()
                    session.startRunning()
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: capture configuration (on the capture queue)

    /// Returns false when the lens's device couldn't be attached (usually the physical camera is
    /// still held by the departing depth session) — the caller retries once.
    @discardableResult private func configure() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .high
        for i in session.inputs { session.removeInput(i) }
        var attached = false
        if let dev = Self.device(for: lens),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
            attached = true
        }
        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        // Upright portrait: all lenses need 90°. Do NOT mirror the front lens — a mirrored frame
        // gives mirrored depth (left/right handedness flips), which read as the front-lens "flipped"
        // artifacts. A point cloud wants the true, un-mirrored scene.
        if let c = output.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
            // Deliver the real per-frame camera intrinsics → METRIC-mode unprojection.
            if c.isCameraIntrinsicMatrixDeliverySupported { c.isCameraIntrinsicMatrixDeliveryEnabled = true }
        }
        session.commitConfiguration()
        return attached
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb, Self.intrinsics(sampleBuffer))   // connection already rotates the buffer to upright
    }

    /// Normalized intrinsics (fx/W, fy/H, cx/W, cy/H) from the frame's camera-intrinsic-matrix
    /// attachment, rotated 90° to match the portrait (upright) buffer we hand the model: the sensor
    /// axes swap. cx/cy ≈ centre. Identity fallback if the attachment is missing.
    private static func intrinsics(_ sb: CMSampleBuffer) -> SIMD4<Float> {
        guard let raw = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                        attachmentModeOut: nil) as? Data, raw.count >= MemoryLayout<matrix_float3x3>.size
        else { return SIMD4(1, 1, 0.5, 0.5) }
        let m = raw.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
        let fx = m.columns.0.x, fy = m.columns.1.y, cx = m.columns.2.x, cy = m.columns.2.y
        let fxn = fx / max(2 * cx, 1), fyn = fy / max(2 * cy, 1)   // fx/W, fy/H (2·c ≈ dimension)
        return SIMD4(fyn, fxn, 0.5, 0.5)                            // 90° rotation swaps the axes
    }
}
