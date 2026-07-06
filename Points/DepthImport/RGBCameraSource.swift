import AVFoundation
import CoreVideo

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

    /// Lenses this device actually has (so the node's camera switcher only shows real cameras).
    static func availableLenses() -> [Lens] {
        let want: [(Lens, AVCaptureDevice.DeviceType, AVCaptureDevice.Position)] = [
            (.ultraWide, .builtInUltraWideCamera, .back), (.wide, .builtInWideAngleCamera, .back),
            (.tele, .builtInTelephotoCamera, .back), (.front, .builtInWideAngleCamera, .front)]
        let found = want.filter { AVCaptureDevice.default($0.1, for: .video, position: $0.2) != nil }.map(\.0)
        return found.isEmpty ? [.wide, .front] : found
    }

    /// (bgra frame, rotation degrees to upright). Called on the capture queue.
    var onFrame: (@Sendable (CVPixelBuffer, Int) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "points.rgbcam", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var lens: Lens = .wide
    private var running = false

    func start(lens: Lens) {
        queue.async { [self] in
            if running && lens == self.lens { return }   // idempotent — no restart on the same lens
            self.lens = lens
            configure()
            if !session.isRunning { session.startRunning() }
            running = true
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            if session.isRunning { session.stopRunning() }
        }
    }

    func setLens(_ lens: Lens) {
        queue.async { [self] in
            guard running, lens != self.lens else { return }
            self.lens = lens
            configure()
        }
    }

    // MARK: capture configuration (on the capture queue)

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        for i in session.inputs { session.removeInput(i) }
        if let dev = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens.position),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        // Upright portrait: back cameras need 90°, front 90° mirrored — handled by the connection.
        if let c = output.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            c.isVideoMirrored = (lens.position == .front && c.isVideoMirroringSupported)
        }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb, 0)   // connection already rotates to upright
    }
}
