import Network
import QuartzCore

/// OSC over UDP → the OSC control nodes. Same shape as `AudioEngine`/`MIDIEngine`:
/// the Network framework delivers datagrams on its own queue, we publish 8 float slots
/// under a lock, read once per render frame. Fixed port contract: listens on :9000 for
/// /points/mod/1-8, broadcasts /points/out/1-8 to :9001 (TouchDesigner/Max default-friendly).
nonisolated final class OSCEngine: @unchecked Sendable {
    static let slotCount = 8
    static let inPort: NWEndpoint.Port = 9000
    static let outPort: NWEndpoint.Port = 9001

    private let lock = NSLock()
    private var slots = [Float](repeating: 0, count: slotCount)     // guarded by `lock`
    private var lastSent = [Float](repeating: .nan, count: slotCount)
    private var lastSentAt = [Double](repeating: -1e9, count: slotCount)

    private let queue = DispatchQueue(label: "points.osc")
    private var listener: NWListener?
    private var connections: [NWConnection] = []    // guarded by `lock`
    private var outConn: NWConnection?              // guarded by `lock`
    private var running = false

    /// Latest input slots /points/mod/1-8 (thread-safe).
    func current() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return slots
    }

    func start() {
        guard !running else { return }
        running = true
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: Self.inPort)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                self.lock.lock(); self.connections.append(conn); self.lock.unlock()
                conn.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { conn.cancel() }
                    if case .cancelled = state {
                        guard let self else { return }
                        self.lock.lock(); self.connections.removeAll { $0 === conn }; self.lock.unlock()
                    }
                }
                conn.start(queue: self.queue)
                self.receiveLoop(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            running = false      // port taken — OSC nodes simply read 0, no crash
        }
    }

    func stop() {
        guard running else { return }
        running = false
        listener?.cancel(); listener = nil
        lock.lock()
        for c in connections { c.cancel() }
        connections.removeAll()
        outConn?.cancel(); outConn = nil
        slots = [Float](repeating: 0, count: Self.slotCount)
        lastSent = [Float](repeating: .nan, count: Self.slotCount)
        lastSentAt = [Double](repeating: -1e9, count: Self.slotCount)
        lock.unlock()
    }

    // MARK: receive (network queue)

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let b = [UInt8](data)
                self.parse(b, 0, b.count)
            }
            if error == nil { self.receiveLoop(conn) } else { conn.cancel() }
        }
    }

    private static let bundleHeader = [UInt8]("#bundle".utf8) + [0]

    /// Parse one OSC packet (message or bundle) in b[lo..<hi]. Bounds-checked throughout.
    private func parse(_ b: [UInt8], _ lo: Int, _ hi: Int) {
        guard lo >= 0, hi <= b.count, lo < hi else { return }
        if hi - lo >= 16, Array(b[lo..<lo + 8]) == Self.bundleHeader {
            var i = lo + 16                          // skip "#bundle\0" + 8-byte timetag
            while i + 4 <= hi {
                guard let size = Self.readUInt32(b, &i, limit: hi) else { return }
                let s = Int(size)
                guard s > 0, i + s <= hi else { return }
                parse(b, i, i + s)                   // element may itself be a bundle
                i += s
            }
        } else {
            parseMessage(b, lo, hi)
        }
    }

    private func parseMessage(_ b: [UInt8], _ lo: Int, _ hi: Int) {
        var i = lo
        guard let address = Self.readString(b, &i, limit: hi, base: lo) else { return }
        guard address.hasPrefix("/points/mod/"),
              let n = Int(address.dropFirst("/points/mod/".count)),
              (1...Self.slotCount).contains(n) else { return }
        guard let tags = Self.readString(b, &i, limit: hi, base: lo), tags.first == "," else { return }

        var value: Float?
        switch tags.dropFirst().first {              // first argument's typetag
        case "f": if let u = Self.readUInt32(b, &i, limit: hi) { value = Float(bitPattern: u) }
        case "i": if let u = Self.readUInt32(b, &i, limit: hi) { value = Float(Int32(bitPattern: u)) }
        case "d": if let u = Self.readUInt64(b, &i, limit: hi) { value = Float(Double(bitPattern: u)) }
        case "T": value = 1
        case "F": value = 0
        default: break
        }
        guard let value, value.isFinite else { return }
        lock.lock(); slots[n - 1] = value; lock.unlock()
    }

    // MARK: wire helpers (big-endian, 4-byte aligned per the OSC 1.0 spec)

    /// Null-terminated string; advances `i` past padding (aligned relative to `base`).
    private static func readString(_ b: [UInt8], _ i: inout Int, limit: Int, base: Int) -> String? {
        guard i >= base, i < limit, limit <= b.count else { return nil }
        guard let end = b[i..<limit].firstIndex(of: 0) else { return nil }
        let s = String(decoding: b[i..<end], as: UTF8.self)
        i = base + ((end + 1 - base + 3) & ~3)
        return s
    }

    private static func readUInt32(_ b: [UInt8], _ i: inout Int, limit: Int) -> UInt32? {
        guard i >= 0, i + 4 <= limit, limit <= b.count else { return nil }
        defer { i += 4 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func readUInt64(_ b: [UInt8], _ i: inout Int, limit: Int) -> UInt64? {
        guard let hiWord = readUInt32(b, &i, limit: limit),
              let loWord = readUInt32(b, &i, limit: limit) else { return nil }
        return UInt64(hiWord) << 32 | UInt64(loWord)
    }

    // MARK: send

    /// Broadcast /points/out/<slot> (1-8). Rate-limited: only when the value moved >0.001
    /// or >100 ms passed since that slot's last send, so render-loop callers stay cheap.
    func send(slot: Int, value: Float) {
        guard (1...Self.slotCount).contains(slot), value.isFinite else { return }
        let now = CACurrentMediaTime()
        let idx = slot - 1
        lock.lock()
        let changed = lastSent[idx].isNaN || abs(value - lastSent[idx]) > 0.001
        let stale = now - lastSentAt[idx] > 0.1
        guard running, changed || stale else { lock.unlock(); return }
        lastSent[idx] = value
        lastSentAt[idx] = now
        lock.unlock()

        let packet = Self.encode(address: "/points/out/\(slot)", value: value)
        let conn = outboundConnection()
        conn.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard error != nil, let self else { return }
            conn.cancel()                            // recreated lazily on the next send
            self.lock.lock(); if self.outConn === conn { self.outConn = nil }; self.lock.unlock()
        })
    }

    private func outboundConnection() -> NWConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = outConn { return c }
        let c = NWConnection(host: "255.255.255.255", port: Self.outPort, using: .udp)
        c.stateUpdateHandler = { [weak self] state in
            guard case .failed = state, let self else { return }
            c.cancel()
            self.lock.lock(); if self.outConn === c { self.outConn = nil }; self.lock.unlock()
        }
        c.start(queue: queue)
        outConn = c
        return c
    }

    private static func encode(address: String, value: Float) -> Data {
        var d = Data(address.utf8)
        d.append(0)
        while d.count % 4 != 0 { d.append(0) }
        d.append(contentsOf: [UInt8(ascii: ","), UInt8(ascii: "f"), 0, 0])
        withUnsafeBytes(of: value.bitPattern.bigEndian) { d.append(contentsOf: $0) }
        return d
    }
}
