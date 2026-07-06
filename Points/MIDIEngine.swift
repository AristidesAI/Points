import CoreMIDI

/// Real MIDI in → the MIDI CC / MIDI Note control nodes. Same shape as `AudioEngine`:
/// CoreMIDI delivers events on its own thread, we publish a SIMD4 snapshot under a lock,
/// read once per render frame. Connects to every MIDI source plus the RTP network session,
/// so both a USB-MIDI interface and a host over the network (TouchDesigner MIDI-out routed
/// through Audio MIDI Setup → Network) reach the app with no extra setup.
nonisolated final class MIDIEngine: @unchecked Sendable {
    private let lock = NSLock()
    // x: last CC value 0-1 · y: note gate 0/1 · z: last velocity 0-1 · w: pitch bend -1…1
    private var _midi = SIMD4<Float>.zero
    private var activeNotes = Set<UInt8>()      // guarded by `lock`

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var running = false

    /// Latest MIDI snapshot (thread-safe).
    func current() -> SIMD4<Float> {
        lock.lock(); defer { lock.unlock() }
        return _midi
    }

    func start() {
        guard !running else { return }
        running = true

        // RTP-MIDI network session — lets a host reach the phone without a USB interface.
        let session = MIDINetworkSession.default()
        session.isEnabled = true
        session.connectionPolicy = .anyone

        MIDIClientCreateWithBlock("Points" as CFString, &client) { [weak self] _ in
            self?.connectAllSources()          // a source appeared/left → (re)connect
        }
        MIDIInputPortCreateWithProtocol(client, "Points In" as CFString, ._1_0, &inPort) { [weak self] list, _ in
            self?.receive(list)
        }
        connectAllSources()
    }

    func stop() {
        guard running else { return }
        running = false
        if inPort != 0 { MIDIPortDispose(inPort); inPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        lock.lock(); _midi = .zero; activeNotes.removeAll(); lock.unlock()
    }

    private func connectAllSources() {
        guard inPort != 0 else { return }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if src != 0 { MIDIPortConnectSource(inPort, src, nil) }
        }
    }

    /// UMP words per message by message-type nibble (w >> 28).
    private static func umpWords(_ mt: UInt32) -> Int {
        switch mt {
        case 0x0, 0x1, 0x2: return 1        // utility / system / MIDI-1.0 channel voice
        case 0x3, 0x4: return 2             // 64-bit data / MIDI-2.0 channel voice
        case 0x5: return 4                  // 128-bit data
        default: return 1
        }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        lock.lock(); defer { lock.unlock() }
        var packet = list.pointee.packet
        for _ in 0..<list.pointee.numPackets {
            let n = Int(packet.wordCount)
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < n {
                    let w = words[i]
                    let mt = (w >> 28) & 0xF
                    if mt == 2 { parseChannelVoice(w) }   // MIDI 1.0, one word
                    i += Self.umpWords(mt)
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    /// Parse a single MIDI-1.0 channel-voice UMP word (lock already held).
    private func parseChannelVoice(_ w: UInt32) {
        let msg = (w >> 16) & 0xF0                 // status high nibble
        let d1 = UInt8((w >> 8) & 0x7F)
        let d2 = UInt8(w & 0x7F)
        switch msg {
        case 0xB0:                                 // Control Change
            _midi.x = Float(d2) / 127
        case 0x90 where d2 > 0:                     // Note On
            activeNotes.insert(d1)
            _midi.y = 1
            _midi.z = Float(d2) / 127
        case 0x80, 0x90:                           // Note Off (0x90 vel 0)
            activeNotes.remove(d1)
            _midi.y = activeNotes.isEmpty ? 0 : 1
        case 0xE0:                                  // Pitch Bend (14-bit, centre 8192)
            _midi.w = Float((Int(d1) | (Int(d2) << 7)) - 8192) / 8192
        default: break
        }
    }
}
