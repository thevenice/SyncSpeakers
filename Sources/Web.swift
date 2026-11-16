// Phones, tablets and any browser as receivers.
//
// The playing Mac runs a tiny web server (port 7777). A phone scans the QR code in the app,
// opens the page in its browser, taps Join, and gets the same stream over a WebSocket.
// The page syncs to the Mac's clock with pings and schedules audio with Web Audio, so it
// plays each sound at the same moment as the Mac and the other receivers.
//
// WebSocket binary messages (little-endian):
//   1 format   sampleRate:f64 delayNs:i64 then source name (UTF-8)   Mac → browser
//   2 audio    index:i64 senderNs:i64 then int16 L/R pairs            Mac → browser
//   3 ping     t0:f64 (browser performance.now() ms)                  browser → Mac
//   4 pong     t0:f64 macNs:i64                                       Mac → browser
//   5 stopped                                                          Mac → browser

import Foundation
import Network
import CryptoKit
import Darwin

final class WebHub {
    var onCount: ((Int) -> Void)?
    var onPort: ((UInt16) -> Void)?

    private let q = DispatchQueue(label: "syncspeakers.web", qos: .userInteractive)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var formatMsg: Data?            // set while this Mac is playing

    private final class Client {
        let c: NWConnection
        var pending = 0
        init(_ c: NWConnection) { self.c = c }
    }

    func start(port: UInt16 = 7777) {
        let p = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        guard let l = try? NWListener(using: .tcp, on: p) else { return }
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready: if let port = l?.port?.rawValue { self?.onPort?(port) }
            case .failed:                          // 7777 taken: use any free port
                l?.cancel()
                if port != 0 { self?.start(port: 0) }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: q)
        listener = l
    }

    // MARK: stream control (any thread)

    func begin(sampleRate: Double, delayNs: Int64, name: String) {
        var p = Data([1]); p.put(sampleRate); p.put(delayNs.littleEndian); p.append(Data(name.utf8))
        q.async { [self] in formatMsg = p; broadcast(p) }
    }

    func send(payload: Data) {
        var m = Data([2]); m.append(payload)
        q.async { [self] in broadcast(m) }
    }

    func end() {
        q.async { [self] in
            guard formatMsg != nil else { return }
            formatMsg = nil
            broadcast(Data([5]))
        }
    }

    // MARK: HTTP + WebSocket

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        readRequest(c, Data())
    }

    private func readRequest(_ c: NWConnection, _ soFar: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self, err == nil else { c.cancel(); return }
            var buf = soFar
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(c, String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || buf.count > 16384 {
                c.cancel()
            } else {
                self.readRequest(c, buf)
            }
        }
    }

    private func handle(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                        "Sec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n"
            c.send(content: Data(reply.utf8), completion: .idempotent)
            let client = Client(c)
            clients[ObjectIdentifier(client)] = client
            onCount?(clients.count)
            if let f = formatMsg { sendFrame(client, f) }
            readFrame(client)
        } else {
            let (status, type, body): (String, String, Data) = path == "/" || path.hasPrefix("/?")
                ? ("200 OK", "text/html; charset=utf-8", Data(receiverPage.utf8))
                : ("404 Not Found", "text/plain", Data("Not found".utf8))
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n" +
                         "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            c.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private func drop(_ client: Client) {
        client.c.cancel()
        if clients.removeValue(forKey: ObjectIdentifier(client)) != nil { onCount?(clients.count) }
    }

    private func readExactly(_ c: NWConnection, _ n: Int, _ then: @escaping (Data?) -> Void) {
        if n == 0 { then(Data()); return }
        c.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
            guard err == nil, let data, data.count == n else { then(nil); return }
            then(Data(data))
        }
    }

    private func readFrame(_ client: Client) {
        let c = client.c
        readExactly(c, 2) { [weak self] h in
            guard let self, let h else { self?.drop(client); return }
            let opcode = h[0] & 0x0F, masked = h[1] & 0x80 != 0, len7 = Int(h[1] & 0x7F)
            let extLen = len7 == 126 ? 2 : len7 == 127 ? 8 : 0
            self.readExactly(c, extLen) { ext in
                guard let ext else { self.drop(client); return }
                var len = len7
                if extLen == 2 { len = Int(ext[0]) << 8 | Int(ext[1]) }
                if extLen == 8 { len = ext.reduce(0) { $0 << 8 | Int($1) } }
                guard len < 1 << 20 else { self.drop(client); return }
                self.readExactly(c, (masked ? 4 : 0) + len) { body in
                    guard var body else { self.drop(client); return }
                    if masked {
                        let key = Array(body.prefix(4))
                        body = Data(body.dropFirst(4).enumerated().map { $0.element ^ key[$0.offset % 4] })
                    }
                    switch opcode {
                    case 0x8: self.drop(client); return                       // close
                    case 0x9: self.sendFrame(client, body, opcode: 0xA)       // ping → pong
                    case 0x2 where body.count >= 9 && body[0] == 3:           // clock ping
                        var p = Data([4]); p.append(body[1..<9]); p.put(nowNs().littleEndian)
                        self.sendFrame(client, p)
                    default: break
                    }
                    self.readFrame(client)
                }
            }
        }
    }

    private func sendFrame(_ client: Client, _ payload: Data, opcode: UInt8 = 0x2) {
        var f = Data([0x80 | opcode])
        if payload.count < 126 { f.append(UInt8(payload.count)) }
        else if payload.count < 65536 { f.append(126); f.append(UInt8(payload.count >> 8)); f.append(UInt8(payload.count & 0xFF)) }
        else { f.append(127); for i in (0..<8).reversed() { f.append(UInt8((payload.count >> (i * 8)) & 0xFF)) } }
        f.append(payload)
        client.pending += 1
        client.c.send(content: f, completion: .contentProcessed { [weak self] err in
            client.pending -= 1
            if err != nil { self?.drop(client) }
        })
    }

    private func broadcast(_ payload: Data) {
        for client in clients.values {
            if client.pending > 400 { drop(client); continue }   // a phone that can't keep up
            sendFrame(client, payload)
        }
    }
}

/// This Mac's Wi-Fi address, for the QR code.
func localIPv4() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }
    var fallback: String?
    var p = ifaddr
    while let a = p {
        let i = a.pointee
        p = i.ifa_next
        guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              i.ifa_flags & UInt32(IFF_UP) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: host), name = String(cString: i.ifa_name)
        if name == "en0" { return ip }
        if fallback == nil, name.hasPrefix("en") { fallback = ip }
    }
    return fallback
}

// MARK: - The page phones open

let receiverPage = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#2a1270">
<title>SyncSpeakers</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100svh; padding: 32px 20px;
    display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 18px;
    font: 17px/1.4 -apple-system, system-ui, sans-serif; color: #fff; text-align: center;
    background: linear-gradient(160deg, #2a1270, #4031cc 55%, #0f80db);
  }
  .logo { width: 112px; height: 112px; border-radius: 26px; display: grid; place-items: center;
          background: linear-gradient(135deg, #6b33f2, #1a9ef2); box-shadow: 0 12px 32px #0006; }
  .logo.live { animation: pulse 1.6s ease-in-out infinite; }
  @keyframes pulse { 50% { transform: scale(1.05); box-shadow: 0 12px 44px #1a9ef2aa; } }
  h1 { margin: 0; font-size: 30px; font-weight: 800; letter-spacing: -0.5px; }
  #from { opacity: .9; max-width: 340px; }
  button { font: inherit; font-size: 20px; font-weight: 700; border: 0; border-radius: 999px;
           padding: 16px 40px; background: #fff; color: #3a2bd0; box-shadow: 0 8px 24px #0004; }
  button:active { transform: scale(.97); }
  #status { font-size: 15px; opacity: .8; min-height: 1.4em; }
  .trim { width: min(340px, 100%); font-size: 14px; opacity: .85; }
  .trim input { width: 100%; }
  .hint { font-size: 13px; opacity: .6; max-width: 320px; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
  <div class="logo" id="logo">
    <svg width="76" height="76" viewBox="0 0 100 100" fill="none" stroke="#fff" stroke-linecap="round" stroke-width="6">
      <circle cx="50" cy="50" r="9" fill="#fff" stroke="none"/>
      <path d="M33 33a24 24 0 0 0 0 34M67 33a24 24 0 0 1 0 34" opacity=".95"/>
      <path d="M23 23a38 38 0 0 0 0 54M77 23a38 38 0 0 1 0 54" opacity=".7"/>
      <path d="M13 13a52 52 0 0 0 0 74M87 13a52 52 0 0 1 0 74" opacity=".45"/>
    </svg>
  </div>
  <h1>SyncSpeakers</h1>
  <div id="from">Join the music playing on this Wi-Fi</div>
  <button id="join">Join 🔊</button>
  <div id="status"></div>
  <label class="trim" id="trimbox" hidden>
    Fine-tune <span id="tv">0</span> ms
    <input id="trim" type="range" min="-300" max="300" step="5" value="0">
  </label>
  <div class="hint">Keep this page open and the screen on — sound stops if the phone locks (iPhone: Settings › Display &amp; Brightness › Auto-Lock). Turn the volume up.</div>
<script>
const $ = id => document.getElementById(id);
let ctx, ws, sr = 48000, delayMs = 400, trimMs = +(localStorage.trim || 0);
let samples = [], offsetMs = null;            // Mac clock (ms) minus this page's clock (ms)
let anchorIdx = null, anchorNs = 0, nextIdx = -1, nextT = 0, late = 0, played = 0, playing = false;

$('trim').value = trimMs; $('tv').textContent = trimMs;
$('trim').oninput = e => { trimMs = +e.target.value; $('tv').textContent = trimMs; localStorage.trim = trimMs; nextIdx = -1; };
const status = s => $('status').textContent = s;

$('join').onclick = async () => {
  try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch (e) {}  // play with silent switch on
  ctx = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'playback' });
  await ctx.resume();
  const s = ctx.createBufferSource(); s.buffer = ctx.createBuffer(1, 1, 22050); s.connect(ctx.destination); s.start();
  try { await navigator.wakeLock?.request('screen'); } catch (e) {}
  document.addEventListener('visibilitychange', async () => {
    if (document.visibilityState === 'visible') { try { await navigator.wakeLock?.request('screen'); await ctx.resume(); } catch (e) {} }
  });
  $('join').hidden = true; $('trimbox').hidden = false;
  connect();
};

function connect() {
  ws = new WebSocket(`ws://${location.host}/ws`);
  ws.binaryType = 'arraybuffer';
  status('Connecting…');
  ws.onopen = () => { status('Waiting for music…'); samples = []; offsetMs = null; ping(); };
  ws.onclose = () => { playing = false; $('logo').classList.remove('live'); status('Reconnecting…'); setTimeout(connect, 1500); };
  ws.onmessage = e => onMessage(new DataView(e.data));
}

function ping() {
  if (!ws || ws.readyState !== 1) return;
  const d = new DataView(new ArrayBuffer(9)); d.setUint8(0, 3); d.setFloat64(1, performance.now(), true); ws.send(d.buffer);
}
setInterval(ping, 400);

setInterval(() => {
  if (!playing) return;
  status(offsetMs === null ? 'Syncing clock…' : (late > 20 ? 'Catching up… (weak Wi-Fi?)' : 'Playing in sync ✓'));
  late = 0;
}, 1000);

function onMessage(d) {
  const type = d.getUint8(0);
  if (type === 1) {
    sr = d.getFloat64(1, true);
    delayMs = Number(d.getBigInt64(9, true)) / 1e6;
    const name = new TextDecoder().decode(new Uint8Array(d.buffer, 17));
    $('from').textContent = `Playing from ${name}`;
    playing = true; anchorIdx = null; nextIdx = -1;
    $('logo').classList.add('live');
  } else if (type === 2) {
    playChunk(d);
  } else if (type === 4) {
    const t1 = performance.now(), t0 = d.getFloat64(1, true), macMs = Number(d.getBigInt64(9, true)) / 1e6;
    samples.push([t1 - t0, macMs - (t0 + t1) / 2]);
    if (samples.length > 30) samples.shift();
    offsetMs = samples.reduce((a, b) => (b[0] < a[0] ? b : a))[1];   // fastest round trip is the truest
  } else if (type === 5) {
    playing = false; $('logo').classList.remove('live');
    $('from').textContent = 'Join the music playing on this Wi-Fi'; status('Waiting for music…');
  }
}

function playChunk(d) {
  if (!ctx || offsetMs === null) return;
  const idx = Number(d.getBigInt64(1, true)), ns = Number(d.getBigInt64(9, true));
  const n = (d.byteLength - 17) / 4;
  // One steady frame-number → time anchor; only move it when it is off by more than 1 ms.
  if (anchorIdx === null || Math.abs(anchorNs + (idx - anchorIdx) / sr * 1e9 - ns) > 1e6) { anchorIdx = idx; anchorNs = ns; }
  const macMs = anchorNs / 1e6 + (idx - anchorIdx) / sr * 1000;
  const playAtPerf = macMs + delayMs + trimMs - offsetMs;
  const ts = ctx.getOutputTimestamp ? ctx.getOutputTimestamp() : null;
  let when = ts && ts.performanceTime
    ? ts.contextTime + (playAtPerf - ts.performanceTime) / 1000
    : ctx.currentTime + (playAtPerf - performance.now()) / 1000 - (ctx.outputLatency || ctx.baseLatency || 0);
  if (idx === nextIdx && Math.abs(when - nextT) < 0.012) when = nextT;   // keep chunks seamless
  if (when < ctx.currentTime + 0.01) { late++; nextIdx = -1; return; }   // too late to play in sync
  const buf = ctx.createBuffer(2, n, sr), L = buf.getChannelData(0), R = buf.getChannelData(1);
  for (let i = 0; i < n; i++) { L[i] = d.getInt16(17 + i * 4, true) / 32768; R[i] = d.getInt16(19 + i * 4, true) / 32768; }
  const src = ctx.createBufferSource(); src.buffer = buf; src.connect(ctx.destination); src.start(when);
  nextIdx = idx + n; nextT = when + n / sr; played++;
}
</script>
</body>
</html>
"""#
