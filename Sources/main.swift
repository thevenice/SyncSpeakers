// SyncSpeakers — whole-house audio from one Mac.
//
// Whatever plays on this Mac (any app) is captured, then played back in sync on:
//   • this Mac's chosen speakers (built-in, Bluetooth, USB, HDMI…) via a multi-output device
//   • every other Mac on the Wi-Fi that has SyncSpeakers open
// All outputs play each sound at the same moment: capture time + a small Wi-Fi buffer.

import SwiftUI
import CoreAudio
import AppKit
import Network
import CoreImage

struct Speaker: Identifiable, Hashable {
    let id: String          // CoreAudio UID
    let name: String
    let kind: String
    let sampleRate: Double
}

@MainActor
final class Router: ObservableObject {
    static let aggUID = "com.prakash.syncspeakers.aggregate"

    // This Mac's speakers
    @Published var speakers: [Speaker] = []
    @Published var selected: Set<String> { didSet { save() } }
    @Published var delayMs: [String: Double] { didSet { save() } }
    // Other Macs
    @Published var peers: [String] = []
    @Published var peerChosen: Set<String> { didSet { save() } }
    @Published var peerLive: Set<String> = []
    @Published var bufferMs: Double { didSet { save() } }
    // Receiving
    @Published var receivingFrom: String?
    @Published var trimMs: Double { didSet { save(); receiver.trimNs = Int64(trimMs * 1e6) } }

    @Published var isOn = false
    @Published var level: Float = 0
    @Published var captureRate: Double = 0
    private var meterTimer: Timer?
    @Published var status = "Tick speakers and Macs, then press Play Everywhere."

    private var aggID: AudioObjectID = 0
    private var previousDefault: AudioObjectID = 0
    private var rebuildTask: Task<Void, Never>?
    private var capture: Capture?
    private var player: Player?
    private var broadcaster: Broadcaster?
    private let receiver = Receiver()
    private let web = WebHub()
    // Phones & browsers
    @Published var webPort: UInt16 = 0
    @Published var phonesListening = 0
    var joinURL: String? {
        guard webPort != 0, let ip = localIPv4() else { return nil }
        return "http://\(ip)" + (webPort == 80 ? "" : ":\(webPort)")
    }
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]

    init() {
        let d = UserDefaults.standard
        selected = Set(d.stringArray(forKey: "selected") ?? [])
        delayMs = (d.dictionary(forKey: "delayMs") as? [String: Double]) ?? [:]
        peerChosen = Set(d.stringArray(forKey: "peers") ?? [])
        bufferMs = d.object(forKey: "bufferMs") as? Double ?? 400
        trimMs = d.object(forKey: "trimMs") as? Double ?? 0
        receiver.trimNs = Int64(trimMs * 1e6)
        destroyStale()
        refresh()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        receiver.onSender = { [weak self] from in Task { @MainActor in self?.receivingFrom = from } }
        receiver.start()
        web.onPort = { [weak self] port in Task { @MainActor in self?.webPort = port } }
        web.onCount = { [weak self] n in Task { @MainActor in self?.phonesListening = n } }
        web.start()
        browse()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Array(selected), forKey: "selected")
        d.set(delayMs, forKey: "delayMs")
        d.set(Array(peerChosen), forKey: "peers")
        d.set(bufferMs, forKey: "bufferMs")
        d.set(trimMs, forKey: "trimMs")
    }

    // MARK: discovery

    func refresh() {
        speakers = CA.allDevices().compactMap { id in
            guard CA.outputChannels(id) > 0,
                  let uid = CA.string(id, kAudioDevicePropertyDeviceUID), uid != Router.aggUID,
                  let name = CA.string(id, kAudioObjectPropertyName) else { return nil }
            var t: UInt32 = 0; _ = CA.get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &t)
            if t == kAudioDeviceTransportTypeAggregate || t == kAudioDeviceTransportTypeVirtual { return nil }
            var rate: Float64 = 48000; _ = CA.get(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
            return Speaker(id: uid, name: name, kind: Self.kindName(t), sampleRate: rate)
        }
        .sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    private func browse() {
        let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: tcpParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var eps: [String: NWEndpoint] = [:]
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint, name != myServiceName { eps[name] = r.endpoint }
            }
            Task { @MainActor in
                self?.endpoints = eps
                self?.peers = eps.keys.sorted()
                self?.connectChosenPeers()
            }
        }
        b.start(queue: .main)
        browser = b
        // Retry ticked Macs that dropped (Wi-Fi blips, the other Mac restarting the app…).
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.connectChosenPeers() }
        }
    }

    private func connectChosenPeers() {
        guard isOn, let b = broadcaster else { return }
        for name in peerChosen { if let ep = endpoints[name] { b.connect(name: name, endpoint: ep) } }
    }

    static func kindName(_ t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Display"
        default: return "Other"
        }
    }

    // MARK: start / stop

    func toggle() { isOn ? stop() : start() }

    func start() {
        let chosen = speakers.filter { selected.contains($0.id) }
        let macs = peers.filter { peerChosen.contains($0) }
        if !isOn { previousDefault = CA.defaultOutput }
        stopEngine()
        teardownAggregate()

        var outDevice: AudioObjectID? = nil
        var clockUID = CA.string(previousDefault, kAudioDevicePropertyDeviceUID) ?? "BuiltInSpeakerDevice"
        if !chosen.isEmpty {
            // Clock master: prefer a wired/built-in device (most stable clock).
            let master = chosen.first { $0.kind != "Bluetooth" && $0.kind != "AirPlay" } ?? chosen[0]
            let ordered = [master] + chosen.filter { $0.id != master.id }
            let subs: [[String: Any]] = ordered.map { s in
                [kAudioSubDeviceUIDKey: s.id,
                 kAudioSubDeviceDriftCompensationKey: s.id == master.id ? 0 : 1,
                 "latency-out": Int((delayMs[s.id] ?? 0) / 1000 * s.sampleRate)]
            }
            let desc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SyncSpeakers",
                kAudioAggregateDeviceUIDKey: Router.aggUID,
                kAudioAggregateDeviceSubDeviceListKey: subs,
                kAudioAggregateDeviceMainSubDeviceKey: master.id,
                kAudioAggregateDeviceClockDeviceKey: master.id,
                kAudioAggregateDeviceIsStackedKey: 1,   // same audio to every speaker
                kAudioAggregateDeviceIsPrivateKey: 0,
            ]
            var newID = AudioObjectID(0)
            let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newID)
            guard err == noErr, newID != 0 else { status = "Could not group the speakers (error \(err))."; return }
            aggID = newID
            outDevice = newID
            clockUID = master.id
        }

        let clock = clockUID
        Task { @MainActor in
            if let out = outDevice {
                try? await Task.sleep(nanoseconds: 300_000_000)   // new device needs a moment
                CA.setDefaultOutput(out)
            }
            do {
                try startEngine(output: outDevice, clockUID: clock, macs: macs)
                isOn = true
                let parts = [chosen.isEmpty ? nil : "\(chosen.count) speaker\(chosen.count == 1 ? "" : "s") here",
                             macs.isEmpty ? nil : "\(macs.count) Mac\(macs.count == 1 ? "" : "s") over Wi-Fi"].compactMap { $0 }
                status = parts.isEmpty ? "Playing for phones only — scan the QR code to join."
                    : "Playing everything from this Mac on " + parts.joined(separator: " + ") + " + any phones that join."
            } catch {
                stopEngine()
                status = error.localizedDescription
            }
        }
    }

    private func startEngine(output: AudioObjectID?, clockUID: String, macs: [String]) throws {
        let delayNs = Int64(bufferMs * 1e6)
        // Start our own output first so the capture can recognise (and skip) this app.
        var p: Player? = nil
        if let output {
            p = Player(sampleRate: 48000, device: output, delayNs: delayNs)
            try p?.start()
        }
        let cap = Capture()
        try cap.start(clockUID: clockUID)
        if let old = p, old.sampleRate != cap.sampleRate {
            old.stop()
            p = Player(sampleRate: cap.sampleRate, device: output!, delayNs: delayNs)
            try p?.start()
        }
        p?.setClock(offsetNs: 0)

        let b = Broadcaster(sampleRate: cap.sampleRate, delayNs: delayNs)
        b.onPeerState = { [weak self] name, live in
            Task { @MainActor in if live { self?.peerLive.insert(name) } else { self?.peerLive.remove(name) } }
        }
        for name in macs { if let ep = endpoints[name] { b.connect(name: name, endpoint: ep) } }

        let localPlayer = p
        let hub = web
        hub.begin(sampleRate: cap.sampleRate, delayNs: delayNs, name: myServiceName)
        cap.onAudio = { index, ns, frames, count in
            localPlayer?.write(index: index, senderNs: ns, frames: frames, count: count)
            let payload = audioPayload(index: index, senderNs: ns, frames: frames, count: count)
            b.send(payload: payload)
            hub.send(payload: payload)
        }
        player = p
        capture = cap
        broadcaster = b
        meterTimer?.invalidate()
        var lastFrames: Int64 = 0, lastTime = Date()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak cap] _ in
            guard let cap else { return }
            let pk = cap.peak; cap.peak = 0
            let rate = Double(cap.framesTotal - lastFrames) / Date().timeIntervalSince(lastTime)
            lastFrames = cap.framesTotal; lastTime = Date()
            Task { @MainActor in
                self?.level = pk
                self?.captureRate = rate
            }
        }
    }

    private func stopEngine() {
        meterTimer?.invalidate(); meterTimer = nil
        level = 0
        capture?.stop(); capture = nil
        broadcaster?.stop(); broadcaster = nil
        web.end()
        player?.stop(); player = nil
        peerLive.removeAll()
    }

    func stop() {
        stopEngine()
        if previousDefault != 0, previousDefault != aggID { CA.setDefaultOutput(previousDefault) }
        teardownAggregate()
        isOn = false
        status = "Stopped. Sound is back to normal."
    }

    /// Settings that need a rebuild; debounced so dragging a slider doesn't thrash.
    func settingsChanged() {
        guard isOn else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { start() }
        }
    }

    private func teardownAggregate() {
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
    }

    private func destroyStale() {
        if let stale = CA.device(uid: Router.aggUID) {
            if CA.defaultOutput == stale, let builtIn = speakers.first(where: { $0.kind == "Built-in" }),
               let id = CA.device(uid: builtIn.id) { CA.setDefaultOutput(id) }
            AudioHardwareDestroyAggregateDevice(stale)
        }
    }

    /// Played by a separate process so it goes through the capture like any other app.
    func playTestClick() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["/System/Library/Sounds/Tink.aiff"]
        try? p.run()
    }

    func shareApp() {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [Bundle.main.bundleURL])
    }
}

// MARK: - UI

func qrImage(_ text: String) -> NSImage? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    let rep = NSCIImageRep(ciImage: out)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

struct ContentView: View {
    @EnvironmentObject var r: Router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speakers on this Mac").font(.headline)
            ForEach(r.speakers) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: Binding(
                        get: { r.selected.contains(s.id) },
                        set: { on in
                            if on { r.selected.insert(s.id) } else { r.selected.remove(s.id) }
                            r.settingsChanged()
                        })) {
                        HStack { Text(s.name); Text(s.kind).font(.caption).foregroundStyle(.secondary) }
                    }
                    if r.selected.contains(s.id) {
                        HStack {
                            Text("Delay").font(.caption)
                            Slider(value: Binding(get: { r.delayMs[s.id] ?? 0 },
                                                  set: { r.delayMs[s.id] = $0.rounded(); r.settingsChanged() }), in: 0...500)
                            Text("\(Int(r.delayMs[s.id] ?? 0)) ms").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                        }
                        .padding(.leading, 20)
                    }
                }
            }

            Divider()
            HStack {
                Text("Other Macs on Wi-Fi").font(.headline)
                Spacer()
                Button("Send app to a Mac…") { r.shareApp() }
            }
            if r.peers.isEmpty {
                Text("None yet. Send this app to your other Macs (AirDrop), open it there, and they appear here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(r.peers, id: \.self) { name in
                Toggle(isOn: Binding(
                    get: { r.peerChosen.contains(name) },
                    set: { on in
                        if on { r.peerChosen.insert(name) } else { r.peerChosen.remove(name) }
                        r.settingsChanged()
                    })) {
                    HStack {
                        Text(name)
                        if r.peerLive.contains(name) { Text("● live").font(.caption).foregroundStyle(.green) }
                    }
                }
            }
            HStack {
                Text("Wi-Fi buffer").font(.caption)
                Slider(value: Binding(get: { r.bufferMs }, set: { r.bufferMs = ($0 / 10).rounded() * 10; r.settingsChanged() }), in: 150...1500)
                Text("\(Int(r.bufferMs)) ms").font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
            }
            Text("Everything plays this much later on all devices. Raise it if a Mac stutters.")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()
            HStack(alignment: .top, spacing: 14) {
                if r.isOn, let url = r.joinURL, let qr = qrImage(url) {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 112, height: 112)
                        .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Phones & tablets").font(.headline)
                        if r.phonesListening > 0 {
                            Text("● \(r.phonesListening) listening").font(.caption).foregroundStyle(.green)
                        }
                    }
                    if r.isOn, let url = r.joinURL {
                        Text("Scan with the camera, tap Join. Any phone on this Wi-Fi joins in sync — no app needed.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(url).font(.caption.monospaced()).textSelection(.enabled)
                    } else {
                        Text("Press Play Everywhere to show a QR code. iPhones, Android phones and tablets scan it and play along in their browser.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let from = r.receivingFrom {
                Divider()
                Text("This Mac is playing sound from \(from)").font(.headline).foregroundStyle(.green)
                HStack {
                    Text("Fine-tune").font(.caption)
                    Slider(value: $r.trimMs, in: -300...300, step: 5)
                    Text("\(Int(r.trimMs)) ms").font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                }
            }

            Divider()
            HStack {
                Button(r.isOn ? "Stop" : "Play Everywhere") { r.toggle() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                Button("Test click") { r.playTestClick() }
                Spacer()
                Button("Refresh") { r.refresh() }
            }
            if r.isOn {
                HStack {
                    Text("Sound").font(.caption)
                    ProgressView(value: Double(min(1, r.level)))
                    Text(String(format: "%.0f Hz", r.captureRate)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Text(r.status).font(.caption).foregroundStyle(.secondary)
            Text("Tip: Bluetooth lags ~150–250 ms. Give the other speakers that much delay until the test click sounds like one click.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(minWidth: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var router: Router?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { router?.stop() }
    }
}

@main
struct SyncSpeakersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup("SyncSpeakers") {
            ContentView()
                .environmentObject(router)
                .onAppear { delegate.router = router }
        }
        .windowResizability(.contentSize)
    }
}
