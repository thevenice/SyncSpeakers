// Wi-Fi streaming between Macs. Every copy of SyncSpeakers advertises itself on Bonjour
// (_syncspk._tcp). The Mac that is playing connects to the chosen ones and streams
// numbered, time-stamped 16-bit stereo audio. Receivers ping the sender to learn the
// offset between the two Macs' clocks, then play each frame at sender-time + buffer.
//
// Message: [type:1][length:4 LE][payload]
//   1 format  sampleRate:f64 delayNs:i64 then sender name (UTF-8)
//   2 audio   index:i64 senderNs:i64 then int16 L/R pairs
//   3 ping    t0:i64                  (receiver → sender)
//   4 pong    t0:i64 senderNow:i64    (sender → receiver)

import Foundation
import Network

let serviceType = "_syncspk._tcp"

enum Msg: UInt8 { case format = 1, audio = 2, ping = 3, pong = 4 }

extension Data {
    mutating func put<T>(_ v: T) { Swift.withUnsafeBytes(of: v) { append(contentsOf: $0) } }
    func get<T>(_ offset: Int, _: T.Type) -> T { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) } }
}

func frame(_ type: Msg, _ payload: Data) -> Data {
    var d = Data(capacity: payload.count + 5)
    d.append(type.rawValue)
    d.put(UInt32(payload.count).littleEndian)
    d.append(payload)
    return d
}

func tcpParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let p = NWParameters(tls: nil, tcp: tcp)
    p.includePeerToPeer = true
    return p
}

/// Reads framed messages until the connection closes.
func readMessages(_ c: NWConnection, _ handle: @escaping (Msg, Data) -> Void, closed: @escaping () -> Void) {
    c.receive(minimumIncompleteLength: 5, maximumLength: 5) { head, _, done, err in
        guard let head, head.count == 5, err == nil else { closed(); return }
        let h = Data(head)
        let type = Msg(rawValue: h[0])
        let len = Int(UInt32(littleEndian: h.get(1, UInt32.self)))
        let next = {
            if done { closed() } else { readMessages(c, handle, closed: closed) }
        }
        if len == 0 { if let type { handle(type, Data()) }; next(); return }
        c.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, done2, err2 in
            guard let body, body.count == len, err2 == nil else { closed(); return }
            if let type { handle(type, Data(body)) }
            if done2 { closed() } else { readMessages(c, handle, closed: closed) }
        }
    }
}

var myServiceName: String {
    ProcessInfo.processInfo.environment["SYNCSPEAKERS_NAME"] ?? Host.current().localizedName ?? "Mac"
}

/// index:i64 senderNs:i64 then int16 L/R pairs — shared by Mac and browser receivers.
func audioPayload(index: Int64, senderNs: Int64, frames: UnsafePointer<Float>, count: Int) -> Data {
    var p = Data(capacity: 16 + count * 4)
    p.put(index.littleEndian); p.put(senderNs.littleEndian)
    var pcm = [Int16](repeating: 0, count: count * 2)
    for i in 0..<(count * 2) { pcm[i] = Int16(max(-1, min(1, frames[i])) * 32767).littleEndian }
    pcm.withUnsafeBytes { p.append(contentsOf: $0) }
    return p
}

// MARK: - Sender

final class Broadcaster {
    private let q = DispatchQueue(label: "syncspeakers.send")
    private var conns: [String: NWConnection] = [:]
    private let formatMsg: Data
    var onPeerState: ((String, Bool) -> Void)?

    init(sampleRate: Double, delayNs: Int64) {
        var p = Data(); p.put(sampleRate); p.put(delayNs.littleEndian)
        p.append(Data(myServiceName.utf8))
        formatMsg = frame(.format, p)
    }

    /// Connects unless already connected/connecting to that Mac.
    func connect(name: String, endpoint: NWEndpoint) {
        q.async { [self] in
            if let old = conns[name] {
                switch old.state { case .failed, .cancelled: break; default: return }
            }
            let c = NWConnection(to: endpoint, using: tcpParameters())
            conns[name] = c
            c.stateUpdateHandler = { [weak self, weak c] state in
                guard let self, let c else { return }
                switch state {
                case .ready:
                    c.send(content: self.formatMsg, completion: .idempotent)
                    self.onPeerState?(name, true)
                    readMessages(c, { type, body in
                        guard type == .ping, body.count >= 8 else { return }
                        var p = Data(); p.put(body.get(0, Int64.self)); p.put(nowNs().littleEndian)
                        c.send(content: frame(.pong, p), completion: .idempotent)
                    }, closed: { [weak self, weak c] in c?.cancel(); self?.onPeerState?(name, false) })
                case .failed, .cancelled:
                    self.onPeerState?(name, false)
                default: break
                }
            }
            c.start(queue: q)
        }
    }

    func send(payload: Data) {
        let msg = frame(.audio, payload)
        q.async { [self] in
            for c in conns.values where c.state == .ready { c.send(content: msg, completion: .idempotent) }
        }
    }

    func stop() {
        q.sync { conns.values.forEach { $0.cancel() }; conns.removeAll() }
    }
}

// MARK: - Receiver

final class Receiver {
    var onSender: ((String?) -> Void)?
    var trimNs: Int64 = 0 { didSet { q.async { [self] in player?.setDelay(ns: delayNs + trimNs) } } }

    private let q = DispatchQueue(label: "syncspeakers.recv", qos: .userInteractive)
    private var listener: NWListener?
    private var active: NWConnection?
    private var player: Player?
    private var delayNs: Int64 = 0
    private var samples: [(rtt: Int64, offset: Int64)] = []
    private var pingTimer: DispatchSourceTimer?
    private var scratch = [Float](repeating: 0, count: 32768)

    func start() {
        do {
            let l = try NWListener(using: tcpParameters())
            l.service = NWListener.Service(name: myServiceName, type: serviceType)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: q)
            listener = l
        } catch {
            NSLog("SyncSpeakers listener failed: \(error)")
        }
    }

    private func accept(_ c: NWConnection) {
        teardown()
        active = c
        let from: String
        if case let .hostPort(host, _) = c.endpoint { from = "\(host)" } else { from = "another Mac" }
        c.start(queue: q)
        readMessages(c, { [weak self, weak c] type, body in
            guard let self, let c, c === self.active else { return }
            self.handle(type, body, from: from)
        }, closed: { [weak self, weak c] in
            guard let self, let c, c === self.active else { return }
            self.teardown()
        })
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak c] in
            var p = Data(); p.put(nowNs().littleEndian)
            c?.send(content: frame(.ping, p), completion: .idempotent)
        }
        t.resume()
        pingTimer = t
    }

    private func handle(_ type: Msg, _ body: Data, from: String) {
        switch type {
        case .format:
            guard body.count >= 16 else { return }
            let sr = body.get(0, Double.self)
            delayNs = Int64(littleEndian: body.get(8, Int64.self))
            let name = body.count > 16 ? String(decoding: body.dropFirst(16), as: UTF8.self) : from
            player?.stop()
            let p = Player(sampleRate: sr, device: CA.defaultOutput, delayNs: delayNs + trimNs)
            do { try p.start(); player = p; onSender?(name) } catch { NSLog("SyncSpeakers player: \(error)") }
        case .audio:
            guard let player, body.count > 16 else { return }
            let index = Int64(littleEndian: body.get(0, Int64.self))
            let ns = Int64(littleEndian: body.get(8, Int64.self))
            let count = (body.count - 16) / 4
            if scratch.count < count * 2 { scratch = [Float](repeating: 0, count: count * 2) }
            body.withUnsafeBytes { raw in
                for i in 0..<(count * 2) {
                    scratch[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 16 + i * 2, as: Int16.self))) / 32767
                }
            }
            scratch.withUnsafeBufferPointer { player.write(index: index, senderNs: ns, frames: $0.baseAddress!, count: count) }
        case .pong:
            guard body.count >= 16 else { return }
            let t1 = nowNs()
            let t0 = Int64(littleEndian: body.get(0, Int64.self))
            let s = Int64(littleEndian: body.get(8, Int64.self))
            samples.append((t1 - t0, s - (t0 + t1) / 2))
            if samples.count > 40 { samples.removeFirst() }
            // The round trip with the least waiting gives the truest clock offset.
            if let best = samples.min(by: { $0.rtt < $1.rtt }) { player?.setClock(offsetNs: best.offset) }
        case .ping:
            break
        }
    }

    private func teardown() {
        pingTimer?.cancel(); pingTimer = nil
        active?.cancel(); active = nil
        player?.stop(); player = nil
        samples.removeAll()
        onSender?(nil)
    }
}
