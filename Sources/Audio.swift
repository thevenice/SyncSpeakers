// Audio plumbing: CoreAudio helpers, the system-audio capture (process tap) and a
// time-aligned player that plays sample N at an exact moment on the sender's clock.

import CoreAudio
import AudioToolbox
import Foundation
import os

func nowNs() -> Int64 { Int64(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())) }
func hostToNs(_ t: UInt64) -> Int64 { Int64(AudioConvertHostTimeToNanos(t)) }

struct AudioError: LocalizedError {
    let errorDescription: String?
    init(_ what: String, _ status: OSStatus = 0) { errorDescription = status == 0 ? what : "\(what) (error \(status))" }
}

// MARK: - CoreAudio helpers

enum CA {
    static func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var s: Unmanaged<CFString>?
        guard get(id, sel, kAudioObjectPropertyScopeGlobal, &s), let v = s else { return nil }
        return v.takeRetainedValue() as String
    }

    static func ids(_ owner: AudioObjectID, _ sel: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(owner, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(owner, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func allDevices() -> [AudioObjectID] { ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) }

    static func outputChannels(_ id: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static var defaultOutput: AudioObjectID {
        var id = AudioObjectID(0)
        _ = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &id)
        return id
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        var dev = id
        var ok = true
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            ok = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                            UInt32(MemoryLayout<AudioObjectID>.size), &dev) == noErr && ok
        }
        return ok
    }

    static func device(uid: String) -> AudioObjectID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Time from "render callback for this buffer" to "sound leaves the speaker".
    static func outputLatencyNs(_ dev: AudioObjectID) -> Int64 {
        let out = kAudioObjectPropertyScopeOutput
        var lat: UInt32 = 0, safety: UInt32 = 0, buf: UInt32 = 0, streamLat: UInt32 = 0
        var rate: Float64 = 48000
        _ = get(dev, kAudioDevicePropertyLatency, out, &lat)
        _ = get(dev, kAudioDevicePropertySafetyOffset, out, &safety)
        _ = get(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &buf)
        _ = get(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
        if let s = ids(dev, kAudioDevicePropertyStreams, out).first { _ = get(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &streamLat) }
        return Int64(Double(lat + safety + buf + streamLat) / max(rate, 1) * 1e9)
    }
}

// MARK: - Player

/// Plays a stream of numbered stereo frames so that the frame captured at sender time T
/// comes out of this Mac's speaker at sender time T + delay. Every Mac uses the same rule,
/// so they all line up.
final class Player {
    let sampleRate: Double
    let device: AudioObjectID

    private let cap: Int
    private let ring: UnsafeMutablePointer<Float>   // interleaved L R
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var end: Int64 = 0                       // one past the newest frame written
    private var anchorIdx: Int64 = 0, anchorNs: Int64 = 0, hasAnchor = false
    private var readPos: Int64 = -1
    private var offsetNs: Int64 = 0                  // sender clock − this Mac's clock
    private var clockReady = false
    private var delayNs: Int64
    private var latencyNs: Int64 = 0
    private var unit: AudioUnit?

    init(sampleRate: Double, device: AudioObjectID, delayNs: Int64) {
        self.sampleRate = sampleRate
        self.device = device
        self.delayNs = delayNs
        cap = Int(sampleRate * 10)
        ring = .allocate(capacity: cap * 2)
        ring.initialize(repeating: 0, count: cap * 2)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        stop()
        ring.deallocate()
        lock.deallocate()
    }

    func setClock(offsetNs: Int64) {
        os_unfair_lock_lock(lock); self.offsetNs = offsetNs; clockReady = true; os_unfair_lock_unlock(lock)
    }

    func setDelay(ns: Int64) {
        os_unfair_lock_lock(lock); delayNs = ns; os_unfair_lock_unlock(lock)
    }

    func write(index: Int64, senderNs: Int64, frames src: UnsafePointer<Float>, count: Int) {
        let capL = Int64(cap)
        os_unfair_lock_lock(lock)
        if index > end {                                  // dropped data: silence the gap
            var i = max(end, index - capL)
            while i < index { let p = Int(i % capL) * 2; ring[p] = 0; ring[p + 1] = 0; i += 1 }
        }
        for f in 0..<count {
            let p = Int((index + Int64(f)) % capL) * 2
            ring[p] = src[f * 2]; ring[p + 1] = src[f * 2 + 1]
        }
        end = max(end, index + Int64(count))
        // Keep one steady index↔time anchor; only move it when it drifts more than 1 ms,
        // so timestamp jitter doesn't make playback wobble.
        let predicted = anchorIdx + Int64(Double(senderNs - anchorNs) * sampleRate / 1e9)
        if !hasAnchor || abs(predicted - index) > Int64(sampleRate / 1000) {
            anchorIdx = index; anchorNs = senderNs; hasAnchor = true
        }
        os_unfair_lock_unlock(lock)
    }

    fileprivate func render(_ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        guard bufs.count > 0, let l = bufs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let r = bufs.count > 1 ? bufs[1].mData!.assumingMemoryBound(to: Float.self) : l
        let n = Int(frames)
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard hasAnchor, clockReady, ts.pointee.mFlags.contains(.hostTimeValid) else {
            for f in 0..<n { l[f] = 0; r[f] = 0 }
            return
        }
        let outNs = hostToNs(ts.pointee.mHostTime) + latencyNs
        let senderT = outNs + offsetNs - delayNs
        let target = anchorIdx + Int64((Double(senderT - anchorNs) * sampleRate / 1e9).rounded())
        let diff = target - readPos
        if readPos < 0 || abs(diff) > Int64(sampleRate * 0.03) { readPos = target }   // big jump: resync
        else if diff > 12 { readPos += 1 }                                           // drift: nudge 1 sample
        else if diff < -12 { readPos -= 1 }
        let capL = Int64(cap)
        for f in 0..<n {
            let i = readPos + Int64(f)
            if i < 0 || i >= end || i < end - capL { l[f] = 0; r[f] = 0 }
            else { let p = Int(i % capL) * 2; l[f] = ring[p]; r[f] = ring[p + 1] }
        }
        readPos += Int64(n)
    }

    func start() throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw AudioError("No audio output unit") }
        var u: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &u)
        guard st == noErr, let u else { throw AudioError("Output unit", st) }
        var dev = device
        st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        guard st == noErr else { throw AudioError("Choose output device", st) }
        var fmt = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        st = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard st == noErr else { throw AudioError("Output format", st) }
        var cb = AURenderCallbackStruct(inputProc: playerRender, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        st = AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard st == noErr else { throw AudioError("Render callback", st) }
        latencyNs = CA.outputLatencyNs(device)
        st = AudioUnitInitialize(u)
        guard st == noErr else { throw AudioError("Start output", st) }
        st = AudioOutputUnitStart(u)
        guard st == noErr else { throw AudioError("Start output", st) }
        unit = u
    }

    func stop() {
        guard let u = unit else { return }
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        unit = nil
    }
}

private let playerRender: AURenderCallback = { refCon, _, ts, _, frames, abl in
    guard let abl else { return noErr }
    Unmanaged<Player>.fromOpaque(refCon).takeUnretainedValue().render(ts, frames, abl)
    return noErr
}

// MARK: - Capture (everything any app plays on this Mac)

final class Capture {
    private(set) var sampleRate: Double = 48000
    var peak: Float = 0                 // loudest sample since the meter last read it
    private(set) var framesTotal: Int64 = 0
    var onAudio: ((_ index: Int64, _ senderNs: Int64, _ frames: UnsafePointer<Float>, _ count: Int) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var index: Int64 = 0
    private let maxFrames = 16384
    private let scratch: UnsafeMutablePointer<Float>
    private let queue = DispatchQueue(label: "syncspeakers.capture", qos: .userInteractive)

    init() { scratch = .allocate(capacity: 16384 * 2) }
    deinit { stop(); scratch.deallocate() }

    /// Our own process (and any other SyncSpeakers copy) must not be captured, or we'd loop.
    static func ownProcessObjects() -> [AudioObjectID] {
        let me = Bundle.main.bundleIdentifier ?? "com.prakash.syncspeakers"
        let pid = ProcessInfo.processInfo.processIdentifier
        return CA.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).filter { obj in
            var p: pid_t = 0
            _ = CA.get(obj, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &p)
            return p == pid || CA.string(obj, kAudioProcessPropertyBundleID) == me
        }
    }

    /// - Parameter clockUID: a real output device that paces the capture.
    func start(clockUID: String) throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: Capture.ownProcessObjects())
        tap.uuid = UUID()
        tap.name = "SyncSpeakers"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped     // apps go quiet here; we replay them in sync
        var st = AudioHardwareCreateProcessTap(tap, &tapID)
        guard st == noErr else { throw AudioError("Could not capture system audio — allow SyncSpeakers under Privacy & Security › Screen & System Audio Recording", st) }

        var asbd = AudioStreamBasicDescription()
        _ = CA.get(tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, &asbd)
        if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        NSLog("SyncSpeakers tap format: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, flags \(asbd.mFormatFlags), interleaved \(interleaved)")

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SyncSpeakers Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard st == noErr else { stop(); throw AudioError("Capture device", st) }

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, inData, inTime, _, _ in
            self?.handle(inData, inTime, interleaved)
        }
        guard st == noErr else { stop(); throw AudioError("Capture callback", st) }
        st = AudioDeviceStart(aggID, procID)
        guard st == noErr else { stop(); throw AudioError("Start capture", st) }
    }

    private func handle(_ inData: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>, _ interleaved: Bool) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count > 0, let d0 = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        var frames: Int
        if interleaved {
            let ch = max(Int(abl[0].mNumberChannels), 1)
            frames = min(Int(abl[0].mDataByteSize) / 4 / ch, maxFrames)
            for f in 0..<frames {
                scratch[f * 2] = d0[f * ch]
                scratch[f * 2 + 1] = ch > 1 ? d0[f * ch + 1] : d0[f * ch]
            }
        } else {
            let d1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : d0
            frames = min(Int(abl[0].mDataByteSize) / 4, maxFrames)
            for f in 0..<frames { scratch[f * 2] = d0[f]; scratch[f * 2 + 1] = d1[f] }
        }
        guard frames > 0 else { return }
        var pk: Float = 0
        for i in 0..<(frames * 2) { pk = max(pk, abs(scratch[i])) }
        peak = max(peak, pk)
        framesTotal += Int64(frames)
        let ns = inTime.pointee.mFlags.contains(.hostTimeValid) ? hostToNs(inTime.pointee.mHostTime) : nowNs()
        onAudio?(index, ns, scratch, frames)
        index += Int64(frames)
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }
}
