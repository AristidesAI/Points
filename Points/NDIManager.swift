//
//  NDIManager.swift
//  Points
//
//  Streams the finished BGRA render as an NDI® source on the local network. Same
//  proven shape as ZPTH's manager: CoreVideo pixel buffer in → NDIlib_send out on a
//  serial queue, coalesce-to-latest so the render thread never blocks.
//
//  Device-only: the bundled libndi_ios.a has no arm64-simulator slice, so the whole
//  implementation is compiled out on the simulator (see the #else shim) and the lib
//  is linked only for sdk=iphoneos* (OTHER_LDFLAGS[sdk=iphoneos*]).
//

import Foundation
import CoreVideo

/// What the NDI node wants sent — read from its params each frame by the renderer.
/// Lives outside the platform guard so the graph/renderer compile on the simulator too.
struct NDIRenderConfig: Equatable {
    var width: Int = 1080
    var height: Int = 1440        // 3:4 portrait by default
    var alpha: Bool = false       // transparent background (keyable)
    var fpsN: Int32 = 30_000
    var fpsD: Int32 = 1_000
    var name: String = "Points"
    var wired: Bool = false        // USB-tether hint only — the send path is identical
}

#if !targetEnvironment(simulator)

final class NDIManager: @unchecked Sendable {

    private var sourceName = "Points"
    private var sender: NDIlib_send_instance_t?
    private var nameBuffer: UnsafeMutablePointer<CChar>?

    private let queue = DispatchQueue(label: "com.points.ndi.send", qos: .userInitiated)
    private let lock = NSLock()

    // Coalesce-to-latest: keep only the newest pending frame; drop older ones under load.
    private var pending: CVPixelBuffer?
    private var lastSent: CVPixelBuffer?          // retained until the NEXT send (NDI async-read contract)
    private var pendingN: Int32 = 30_000, pendingD: Int32 = 1_000
    private var scheduled = false
    private var started = false
    private var _connectionCount = 0

    var isStreaming: Bool { lock.withLock { started } }
    var connectionCount: Int { lock.withLock { _connectionCount } }

    func start(name: String) {
        let want = name.isEmpty ? "Points" : name
        lock.lock()
        let alreadyRight = started && sourceName == want
        let needRestart = started && sourceName != want
        lock.unlock()
        if alreadyRight { return }
        if needRestart { stop() }        // name changed while live → recreate (lock is released here)

        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        guard NDIlib_initialize() else { print("[NDI] initialize failed"); return }

        sourceName = want
        let bytes = sourceName.utf8.count + 1
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bytes)
        sourceName.withCString { buf.initialize(from: $0, count: bytes) }
        nameBuffer = buf

        var settings = NDIlib_send_create_t()
        settings.p_ndi_name = UnsafePointer(buf)
        settings.p_groups = nil
        settings.clock_video = false          // low latency — pass frames straight through
        settings.clock_audio = false
        sender = NDIlib_send_create(&settings)

        guard sender != nil else {
            print("[NDI] send_create failed")
            buf.deallocate(); nameBuffer = nil
            NDIlib_destroy()
            return
        }
        started = true
        print("[NDI] started as '\(sourceName)'")
    }

    func stop() {
        queue.sync {
            lock.lock()
            guard started || sender != nil else { lock.unlock(); return }  // already stopped → no-op, no log spam
            let s = sender, nb = nameBuffer
            sender = nil; nameBuffer = nil
            started = false; scheduled = false
            pending = nil; lastSent = nil
            _connectionCount = 0
            lock.unlock()
            if let s { NDIlib_send_destroy(s); NDIlib_destroy() }
            nb?.deallocate()
        }
    }

    /// Render thread, once per frame. Cheap + non-blocking: stash latest, kick a drain.
    func send(_ buffer: CVPixelBuffer, fpsN: Int32, fpsD: Int32) {
        lock.lock()
        guard started else { lock.unlock(); return }
        pending = buffer
        pendingN = fpsN; pendingD = fpsD
        let kick = !scheduled
        if kick { scheduled = true }
        lock.unlock()
        if kick { queue.async { [weak self] in self?.drainOnce() } }
    }

    private func drainOnce() {
        lock.lock()
        guard started, let s = sender, let frame = pending else { scheduled = false; lock.unlock(); return }
        let n = pendingN, d = pendingD
        pending = nil
        lock.unlock()

        CVPixelBufferLockBaseAddress(frame, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(frame) {
            var v = NDIlib_video_frame_v2_t()
            v.xres = Int32(CVPixelBufferGetWidth(frame))
            v.yres = Int32(CVPixelBufferGetHeight(frame))
            v.FourCC = NDIlib_FourCC_video_type_BGRA
            v.frame_rate_N = n
            v.frame_rate_D = d
            v.picture_aspect_ratio = 0
            v.frame_format_type = NDIlib_frame_format_type_progressive
            v.timecode = NDIlib_send_timecode_synthesize
            v.p_data = base.assumingMemoryBound(to: UInt8.self)
            v.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(frame))
            v.p_metadata = nil
            v.timestamp = 0
            NDIlib_send_send_video_v2(s, &v)
            let c = Int(NDIlib_send_get_no_connections(s, 0))
            lock.withLock { _connectionCount = c; lastSent = frame }   // prev frame stayed valid to here
        }
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)

        lock.lock()
        if started, pending != nil {
            lock.unlock()
            queue.async { [weak self] in self?.drainOnce() }
        } else {
            scheduled = false
            lock.unlock()
        }
    }

    deinit { if isStreaming { stop() } }
}

#else

// Simulator no-op shim: identical API, references no NDI symbols, so the app builds &
// runs in the simulator. Real streaming is device-only.
final class NDIManager {
    var isStreaming: Bool { false }
    var connectionCount: Int { 0 }
    func start(name: String) {}
    func stop() {}
    func send(_ buffer: CVPixelBuffer, fpsN: Int32, fpsD: Int32) {}
}

#endif
