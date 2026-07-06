import AVFoundation
import Accelerate
import simd

/// Real mic → FFT → band energies + onsets, feeding the audio control nodes.
/// Runs only while the graph actually uses an audio node (started/stopped by ContentView).
/// The tap runs on a realtime audio thread; results are published under a lock.
nonisolated final class AudioEngine: @unchecked Sendable {
    static let fftSize = 1024
    private let log2n = vDSP_Length(10)                 // 2^10 = 1024
    private let engine = AVAudioEngine()
    private var fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]
    private var ring = [Float](repeating: 0, count: fftSize)
    private var ringFill = 0
    private var prevMag = [Float](repeating: 0, count: fftSize / 2)
    // Slow-decaying per-band maxima for auto-gain (so quiet + loud rooms both reach ~1).
    private var agc = SIMD4<Float>(0.02, 0.02, 0.02, 0.02)

    private let lock = NSLock()
    private var _bands = SIMD4<Float>.zero      // bass, mid, high, rms
    private var _onsets = SIMD4<Float>.zero     // drumLow, drumMid, drumHigh, burst
    private var _fft = [Float](repeating: 0, count: 20)     // 20 log-spaced bands (FFT Band node)
    private var agcF = [Float](repeating: 0.02, count: 20)  // per-band auto-gain maxima
    private var running = false

    init() {
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: Self.fftSize, isHalfWindow: false)
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    }

    /// Latest analysis (thread-safe). Returns (bands, onsets, fft); onsets decay to 0 in-place.
    func current() -> (bands: SIMD4<Float>, onsets: SIMD4<Float>, fft: [Float]) {
        lock.lock(); defer { lock.unlock() }
        let out = (_bands, _onsets, _fft)
        _onsets *= 0.75           // pulses decay each read so triggers are brief
        return out
    }

    func start() {
        guard !running else { return }
        AVAudioApplication.requestRecordPermission { [weak self] ok in
            guard ok, let self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
                try session.setActive(true)
                let input = self.engine.inputNode
                let format = input.inputFormat(forBus: 0)
                guard format.sampleRate > 0 else { return }
                input.installTap(onBus: 0, bufferSize: UInt32(Self.fftSize), format: format) { [weak self] buf, _ in
                    self?.process(buf, sampleRate: Float(format.sampleRate))
                }
                self.engine.prepare()
                try self.engine.start()
                self.running = true
            } catch {
                // Leave bands at zero — audio nodes simply read 0, no crash.
            }
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        lock.lock(); _bands = .zero; _onsets = .zero; _fft = [Float](repeating: 0, count: 20); lock.unlock()
    }

    // MARK: analysis (audio thread)

    private func process(_ buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        // Feed the incoming samples through a 1024-sample ring; analyse when full.
        var i = 0
        while i < n {
            let take = min(Self.fftSize - ringFill, n - i)
            for k in 0..<take { ring[ringFill + k] = ch[i + k] }
            ringFill += take; i += take
            if ringFill == Self.fftSize { analyse(sampleRate: sampleRate); ringFill = 0 }
        }
    }

    private func analyse(sampleRate: Float) {
        let half = Self.fftSize / 2
        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP.multiply(ring, window, result: &windowed)

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(Self.fftSize))

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft?.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mag)      // magnitude spectrum
            }
        }

        // Bin → band ranges (Hz). binHz = sr / fftSize.
        let binHz = sampleRate / Float(Self.fftSize)
        func bandEnergy(_ loHz: Float, _ hiHz: Float) -> Float {
            let lo = max(1, Int(loHz / binHz)), hi = min(half - 1, Int(hiHz / binHz))
            guard hi > lo else { return 0 }
            var s: Float = 0
            for b in lo...hi { s += mag[b] }
            return s / Float(hi - lo + 1) * 0.02          // rough scaling into a usable range
        }
        let raw = SIMD4<Float>(bandEnergy(30, 250), bandEnergy(250, 2000),
                               bandEnergy(2000, 8000), rms * 6)

        // Auto-gain: track a slow max per lane so any room reaches ~1.0.
        agc = simd_max(agc * 0.999, raw)
        agc = simd_max(agc, SIMD4<Float>(repeating: 0.02))
        let bands = simd_clamp(raw / agc, SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 1))

        // Spectral flux onsets (positive change), split into low/mid/high + a broadband burst.
        var fluxLow: Float = 0, fluxMid: Float = 0, fluxHigh: Float = 0
        for b in 1..<half {
            let d = mag[b] - prevMag[b]
            if d > 0 {
                if b < 8 { fluxLow += d } else if b < 42 { fluxMid += d } else { fluxHigh += d }
            }
            prevMag[b] = mag[b]
        }
        let burst = min((fluxLow + fluxMid + fluxHigh) * 0.01, 1)
        let onsets = SIMD4<Float>(min(fluxLow * 0.03, 1), min(fluxMid * 0.01, 1),
                                  min(fluxHigh * 0.006, 1), burst)

        // 20 log-spaced bands 40 Hz → 8 kHz for the FFT Band node, each auto-gained like `bands`.
        var fft20 = [Float](repeating: 0, count: 20)
        for i in 0..<20 {
            let lo = 40 * pow(200, Float(i) / 20)        // 40·200^(i/20): 20 steps to 8 kHz
            let hi = 40 * pow(200, Float(i + 1) / 20)
            let raw = bandEnergy(lo, hi)
            agcF[i] = max(agcF[i] * 0.999, max(raw, 0.02))
            fft20[i] = min(max(raw / agcF[i], 0), 1)
        }

        lock.lock()
        _bands = bands
        _onsets = simd_max(_onsets, onsets)     // keep the peak until read
        _fft = fft20
        lock.unlock()
    }
}

// demo: `swift AudioEngine.swift` won't run (needs a mic) — the runnable check is the band math.
// Verified by construction: bandEnergy clamps indices to [1, half-1]; AGC floor 0.02 prevents /0.
