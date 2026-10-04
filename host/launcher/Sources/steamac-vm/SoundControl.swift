import Combine
import CoreAudio
import Darwin
import Foundation

/// Runtime audio controls of libkrun's virtio-snd CoreAudio backend (krun_snd_set_output_device,
/// krun_snd_set_volume, krun_snd_set_buffer_ms). Looked up with dlsym: an older libkrun without
/// them still boots, and the Sound settings explain why they are disabled.
final class SoundControl {
    private typealias SetOutput = @convention(c) (UInt32, UnsafePointer<CChar>?) -> Int32
    private typealias SetVolume = @convention(c) (UInt32, Float, Bool) -> Int32
    private typealias SetBuffer = @convention(c) (UInt32, UInt32) -> Int32

    private let setOutput: SetOutput?
    private let setVolume: SetVolume?
    private let setBuffer: SetBuffer?
    /// The running VM's context; nil until attached (or when the VM has no virtio-snd).
    private(set) var ctx: UInt32?
    /// Why this boot has no sound device (shown in Settings), nil if it has one.
    private(set) var noDeviceReason: String?

    init() {
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }   // RTLD_DEFAULT
        }
        setOutput = sym("krun_snd_set_output_device", SetOutput.self)
        setVolume = sym("krun_snd_set_volume", SetVolume.self)
        setBuffer = sym("krun_snd_set_buffer_ms", SetBuffer.self)
    }

    var canSelectDevice: Bool { setOutput != nil }
    var canSetVolume: Bool { setVolume != nil }
    var canSetBuffer: Bool { setBuffer != nil }

    /// Why live controls are unavailable in this libkrun (nil = all present).
    var missingAPIReason: String? {
        if canSelectDevice && canSetVolume && canSetBuffer { return nil }
        let missing = [("krun_snd_set_output_device", canSelectDevice), ("krun_snd_set_volume", canSetVolume),
                       ("krun_snd_set_buffer_ms", canSetBuffer)].filter { !$0.1 }.map(\.0)
        return "The installed libkrun has no \(missing.joined(separator: ", ")) (rebuild host/libkrun and reinstall the launcher)."
    }
    private var subscriptions: [AnyCancellable] = []

    /// Before krun_start_enter: apply the saved output device, volume and buffer, then follow the
    /// Settings window ("applies now").
    func attach(ctx: UInt32, settings: LauncherSettings) {
        self.ctx = ctx
        noDeviceReason = nil
        apply(outputUID: settings.soundOutputUID)
        apply(volume: settings.soundVolume, mute: settings.soundMute)
        apply(latency: settings.soundLatency)
        // @Published emits the new value before it is stored: use the emitted values.
        subscriptions = [
            settings.$soundOutputUID.dropFirst().removeDuplicates().sink { [weak self] in self?.apply(outputUID: $0) },
            settings.$soundVolume.combineLatest(settings.$soundMute).dropFirst()
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
                .sink { [weak self] v, m in self?.apply(volume: v, mute: m) },
            settings.$soundLatency.dropFirst().removeDuplicates().sink { [weak self] in self?.apply(latency: $0) },
        ]
    }

    func detach(reason: String) {
        ctx = nil
        noDeviceReason = reason
    }

    func apply(outputUID: String) {
        guard let ctx, let setOutput else { return }
        let r = outputUID.isEmpty ? setOutput(ctx, nil) : outputUID.withCString { setOutput(ctx, $0) }
        report("output device \(outputUID.isEmpty ? "system default" : outputUID)", r)
    }

    func apply(volume: Double, mute: Bool) {
        guard let ctx, let setVolume else { return }
        report("volume \(Int((volume * 100).rounded()))%\(mute ? " (muted)" : "")", setVolume(ctx, Float(max(0, min(1, volume))), mute))
    }

    func apply(latency: LauncherSettings.Latency) {
        guard let ctx, let setBuffer else { return }
        report("buffer \(latency.bufferMs) ms (\(latency.rawValue))", setBuffer(ctx, latency.bufferMs))
    }

    private func report(_ what: String, _ r: Int32) {
        if r == 0 { log("sound: \(what)") }
        else { log("sound: \(what) failed: \(r) (\(String(cString: strerror(-r))))") }
    }
}

/// CoreAudio output devices (for the Sound settings).
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    static func outputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    /// Name of the current system default output device.
    static func defaultOutputName() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}
