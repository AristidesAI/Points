import AVFoundation
import ARKit
import CoreVideo
import Observation

/// Front TrueDepth: AVCapture, depth-master synchronizer, Float32 depth + BGRA color.
/// @unchecked Sendable: all mutable state is confined to the serial `queue`; `onFrame` is set
/// once at init before `start()`. Lets `self` be captured in the `@Sendable` queue.async closures.
nonisolated final class TrueDepthCamera: NSObject, AVCaptureDataOutputSynchronizerDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer, CVPixelBuffer?, Bool) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "points.truedepth", qos: .userInteractive)
    private let depthOut = AVCaptureDepthDataOutput()
    private let videoOut = AVCaptureVideoDataOutput()
    private var sync: AVCaptureDataOutputSynchronizer?
    private var configured = false

    func start() {
        queue.async { [self] in
            configure()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            completion?()
        }
    }

    /// Apple depth smoothing — live-toggleable (Apple Depth Filter node).
    func setFiltering(_ on: Bool) {
        queue.async { [self] in depthOut.isFilteringEnabled = on }
    }

    /// Recovery: kick the capture session back to life (menu reset button / after an
    /// interruption). Config is kept — nodes/settings are unaffected.
    func restart() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            configure()                                  // no-op if already configured
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Auto-recover from a runtime error / a resolved interruption (a modal covering the app,
    /// a call, system pressure). Without this the front feed dies and never comes back.
    private func observeSession() {
        let nc = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification,
                     AVCaptureSession.interruptionEndedNotification] {
            nc.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async {
                    guard let self, !self.session.isRunning else { return }
                    self.session.startRunning()
                }
            }
        }
    }

    private func configure() {
        guard !configured else { return }
        guard let dev = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .inputPriority   // required or high-res depth formats are hidden
        if session.canAddInput(input) { session.addInput(input) }
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
        // OFF by default — Apple's smoothing smears silhouettes at range and fights the
        // grazing cull. The "Apple Depth Filter" FILTER node turns it on per project.
        depthOut.isFilteringEnabled = false
        depthOut.alwaysDiscardsLateDepthData = true
        if session.canAddOutput(depthOut) { session.addOutput(depthOut) }
        let f32 = kCVPixelFormatType_DepthFloat32
        // 4:3 video format matching the 4:3 depth sensor — the device default is 16:9,
        // which vertically squashes RGB (and reads as depth squash) on the 3:4 pin grid.
        let fourByThree = dev.formats
            .filter { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                guard d.width * 3 == d.height * 4 else { return false }
                return f.supportedDepthDataFormats.contains {
                    CMFormatDescriptionGetMediaSubType($0.formatDescription) == f32
                }
            }
            .sorted { dims($0) < dims($1) }
        // moderate resolution: enough for color sampling, no bandwidth waste
        if let f = fourByThree.first(where: { dims($0) >= 1280 * 960 }) ?? fourByThree.last {
            try? dev.lockForConfiguration()
            dev.activeFormat = f
            dev.unlockForConfiguration()
        }
        // Largest Float32-capable depth format
        if let f = dev.activeFormat.supportedDepthDataFormats
            .filter({ CMFormatDescriptionGetMediaSubType($0.formatDescription) == f32 })
            .max(by: { dims($0) < dims($1) }) {
            try? dev.lockForConfiguration()
            dev.activeDepthDataFormat = f
            dev.unlockForConfiguration()
        }
        // Depth FIRST = depth-master (avoids +1 frame latency)
        let s = AVCaptureDataOutputSynchronizer(dataOutputs: [depthOut, videoOut])
        s.setDelegate(self, queue: queue)
        sync = s
        session.commitConfiguration()
        observeSession()
    }

    private func dims(_ f: AVCaptureDevice.Format) -> Int {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return Int(d.width) * Int(d.height)
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        autoreleasepool {   // load-bearing under sustained capture (TDLidar OOM lesson)
            guard let dd = collection.synchronizedData(for: depthOut) as? AVCaptureSynchronizedDepthData,
                  !dd.depthDataWasDropped else { return }
            var depth = dd.depthData
            if depth.depthDataType != kCVPixelFormatType_DepthFloat32 {
                depth = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            }
            var color: CVPixelBuffer?
            if let vd = collection.synchronizedData(for: videoOut) as? AVCaptureSynchronizedSampleBufferData,
               !vd.sampleBufferWasDropped {
                color = CMSampleBufferGetImageBuffer(vd.sampleBuffer)
            }
            onFrame?(depth.depthDataMap, color, false)
        }
    }
}

/// Back LiDAR: ARKit sceneDepth (256×192 Float32) + capturedImage luma plane.
nonisolated final class LiDARCamera: NSObject, ARSessionDelegate {
    var onFrame: (@Sendable (CVPixelBuffer, CVPixelBuffer?, Bool) -> Void)?
    private let session = ARSession()

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start() {
        guard Self.isSupported else { return }
        let cfg = ARWorldTrackingConfiguration()
        cfg.frameSemantics = .sceneDepth
        session.delegate = self
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        session.pause()
        completion?()
    }

    /// Recovery: re-run the AR session from scratch.
    func restart() {
        guard Self.isSupported else { return }
        session.pause()
        let cfg = ARWorldTrackingConfiguration()
        cfg.frameSemantics = .sceneDepth
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let sd = frame.sceneDepth else { return }
        // Extract pixel buffers only — never retain the ARFrame past this call.
        onFrame?(sd.depthMap, frame.capturedImage, true)
    }
}

/// Owns which camera runs. One camera owner at a time; switches are sequenced stop → delay → start.
@Observable
final class SourceManager {
    enum Facing: String { case front = "FRONT DEPTH", back = "BACK LIDAR" }

    /// Per-camera sensor→grid orientation (bits: 1 swapUV, 2 flipU, 4 flipV). The swapUV
    /// transpose runs first, so a landscape sensor → portrait grid is a 90° turn = transpose +
    /// exactly one flip; bits 3 and 5 are the two opposite turns. Back (ARKit landscape) read
    /// upside-down at 3, so 5 is the right-way-up turn. // ponytail: calibration knob — if the
    /// back feed still reads wrong on-device, 3↔5 flips top/bottom, +4 mirrors left/right.
    static let frontOrient: UInt32 = 1
    static let backOrient: UInt32 = 5

    private(set) var facing: Facing = .front
    private(set) var permissionDenied = false
    private(set) var colorEnabled = false
    var lidarAvailable: Bool { LiDARCamera.isSupported }

    let renderer: PinRenderer
    let vision = VisionEngine()               // fed the colour frames for body/hand tracking
    private let front = TrueDepthCamera()
    private let back = LiDARCamera()
    private var started = false

    init(renderer: PinRenderer) {
        self.renderer = renderer
        let r = renderer, v = vision
        front.onFrame = { depth, color, luma in
            r.ingest(depth: depth, color: color, lumaOnly: luma)
            if let c = color { v.process(c, front: true) }
        }
        back.onFrame = { depth, color, luma in
            r.ingest(depth: depth, color: color, lumaOnly: luma)
            if let c = color { v.process(c, front: false) }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run(facing)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.run(self.facing) } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func toggleColor() {
        colorEnabled.toggle()
        renderer.setColorEnabled(colorEnabled)
    }

    /// Apple Depth Filter node → capture layer (front TrueDepth only; LiDAR has no toggle).
    func setAppleDepthFiltering(_ on: Bool) {
        front.setFiltering(on)
    }

    /// Imported-media playback owns the depth feed → pause the live cameras (else they fight the
    /// DepthPlayer's ingest). Turning it off resumes the current facing.
    private(set) var mediaMode = false
    func setMediaMode(_ on: Bool) {
        guard mediaMode != on else { return }
        mediaMode = on
        if on { front.stop(); back.stop() }
        else if started {
            renderer.setOrient(facing == .front ? Self.frontOrient : Self.backOrient)   // player left orient 0
            renderer.resetFilter()
            run(facing)
        }
    }

    func toggleFacing() {
        guard lidarAvailable || facing == .back else { return }
        let target: Facing = facing == .front ? .back : .front
        facing = target
        renderer.resetFilter()
        renderer.setOrient(target == .front ? Self.frontOrient : Self.backOrient)
        switch target {
        case .back:
            front.stop { [back] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { back.start() }
            }
        case .front:
            back.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [front] in front.start() }
        }
    }

    private func run(_ f: Facing) {
        switch f {
        case .front: front.start()
        case .back: back.start()
        }
    }

    /// Menu recovery button: restart the live capture engine + clear the depth/EMA scratch so a
    /// stalled or frozen feed comes back fresh. The graph, nodes and settings are untouched.
    func restart() {
        started = true
        renderer.resetFilter()
        switch facing {
        case .front: front.restart()
        case .back: back.restart()
        }
    }
}
