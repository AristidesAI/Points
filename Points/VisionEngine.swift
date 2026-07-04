import Vision
import CoreVideo
import QuartzCore
import simd

/// Real body + hand tracking → the body/hand control nodes. Same shape as AudioEngine: the
/// camera pushes colour frames in, Vision runs (throttled) on a background queue, results are
/// published under a lock and read once per render frame. Uses the already-granted camera
/// permission — no extra prompt. On-device tuning may be needed for the coordinate mapping.
nonisolated final class VisionEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "points.vision", qos: .userInitiated)
    private let bodyReq = VNDetectHumanBodyPoseRequest()
    private let handReq: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 1; return r
    }()

    private let lock = NSLock()
    private var _bodyA = SIMD4<Float>.zero      // headX, headY, handLX, handLY
    private var _bodyB = SIMD4<Float>.zero      // handRX, handRY, pinch, openness
    private var _gestures = SIMD4<Float>.zero   // palm, fist, peace, point
    private var _present = SIMD4<Float>.zero    // present, entered
    private var wasPresent = false
    private var busy = false
    private var lastRun: CFTimeInterval = 0
    private var running = false

    func setRunning(_ on: Bool) {
        running = on
        if !on { lock.lock(); _bodyA = .zero; _bodyB = .zero; _gestures = .zero; _present = .zero; lock.unlock() }
    }

    /// Latest tracking (thread-safe). Gesture triggers + entered-pulse decay on read.
    func current() -> (bodyA: SIMD4<Float>, bodyB: SIMD4<Float>, gestures: SIMD4<Float>, present: SIMD4<Float>) {
        lock.lock(); defer { lock.unlock() }
        let out = (_bodyA, _bodyB, _gestures, _present)
        _gestures *= 0.5
        _present.y = 0
        return out
    }

    /// Called from the capture thread with each colour frame; self-throttles to ~13 fps.
    func process(_ pixelBuffer: CVPixelBuffer, front: Bool) {
        let now = CACurrentMediaTime()
        guard running, !busy, now - lastRun > 0.075 else { return }
        busy = true; lastRun = now
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            let orient: CGImagePropertyOrientation = front ? .leftMirrored : .right
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orient, options: [:])
            try? handler.perform([self.bodyReq, self.handReq])
            self.consume(front: front)
        }
    }

    // MARK: analysis

    private func consume(front: Bool) {
        var bodyA = SIMD4<Float>.zero, bodyB = SIMD4<Float>.zero, gestures = SIMD4<Float>.zero
        var present: Float = 0

        if let obs = bodyReq.results?.first {
            present = 1
            func jp(_ j: VNHumanBodyPoseObservation.JointName) -> SIMD2<Float>? {
                guard let p = try? obs.recognizedPoint(j), p.confidence > 0.1 else { return nil }
                return map(SIMD2(Float(p.location.x), Float(p.location.y)), front)
            }
            if let h = jp(.nose) ?? jp(.neck) { bodyA.x = h.x; bodyA.y = h.y }
            if let l = jp(.leftWrist) { bodyA.z = l.x; bodyA.w = l.y }
            if let r = jp(.rightWrist) { bodyB.x = r.x; bodyB.y = r.y }
        }
        if let hand = handReq.results?.first {
            let h = analyseHand(hand)
            bodyB.z = h.pinch; bodyB.w = h.openness; gestures = h.gestures
        }

        lock.lock()
        _bodyA = bodyA; _bodyB = bodyB
        _gestures = simd_max(_gestures, gestures)
        _present.x = present
        if present > 0.5 && !wasPresent { _present.y = 1 }
        wasPresent = present > 0.5
        lock.unlock()
    }

    /// Vision origin is bottom-left; our controls are top-left. Front camera is mirrored.
    private func map(_ p: SIMD2<Float>, _ front: Bool) -> SIMD2<Float> {
        SIMD2(front ? 1 - p.x : p.x, 1 - p.y)
    }

    private func analyseHand(_ obs: VNHumanHandPoseObservation)
        -> (pinch: Float, openness: Float, gestures: SIMD4<Float>) {
        func p(_ j: VNHumanHandPoseObservation.JointName) -> SIMD2<Float>? {
            guard let r = try? obs.recognizedPoint(j), r.confidence > 0.2 else { return nil }
            return SIMD2(Float(r.location.x), Float(r.location.y))
        }
        var pinch: Float = 0.5, openness: Float = 0.5
        if let tt = p(.thumbTip), let it = p(.indexTip) {
            pinch = min(simd_distance(tt, it) * 4, 1)      // 0 touching → 1 wide
        }
        // A finger is "up" when its tip is meaningfully farther from the wrist than its PIP joint.
        func up(_ tip: VNHumanHandPoseObservation.JointName, _ pip: VNHumanHandPoseObservation.JointName,
                _ wrist: SIMD2<Float>) -> Bool {
            guard let t = p(tip), let j = p(pip) else { return false }
            return simd_distance(t, wrist) > simd_distance(j, wrist) * 1.12
        }
        var gestures = SIMD4<Float>.zero
        if let wrist = p(.wrist) {
            let idx = up(.indexTip, .indexPIP, wrist), mid = up(.middleTip, .middlePIP, wrist)
            let rng = up(.ringTip, .ringPIP, wrist), lil = up(.littleTip, .littlePIP, wrist)
            let n = (idx ? 1 : 0) + (mid ? 1 : 0) + (rng ? 1 : 0) + (lil ? 1 : 0)
            openness = Float(n) / 4
            if idx && mid && rng && lil { gestures.x = 1 }             // palm
            else if !idx && !mid && !rng && !lil { gestures.y = 1 }    // fist
            else if idx && mid && !rng && !lil { gestures.z = 1 }      // peace
            else if idx && !mid && !rng && !lil { gestures.w = 1 }     // point
        }
        return (pinch, openness, gestures)
    }
}
