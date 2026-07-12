import CoreAudio
import Foundation

// micctl — get/set mute and input volume on a named Core Audio input device.
// AppleScript's `set volume input volume` only touches the default device's
// volume scalar and is ignored by devices like MOTIV Mix Virtual; this talks
// to kAudioDevicePropertyMute / VolumeScalar on the device itself.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    var cf: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let err = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    guard err == noErr, let s = cf else { return nil }
    return s as String
}

func inputChannelCount(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: 0)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

// USB mics vary: some expose mute/volume on the main element (0), some only per-channel.
func firstElement(with selector: AudioObjectPropertySelector, on id: AudioDeviceID) -> AudioObjectPropertyElement? {
    for el: AudioObjectPropertyElement in [0, 1, 2] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: el)
        if AudioObjectHasProperty(id, &addr) { return el }
    }
    return nil
}

func getMute(_ id: AudioDeviceID) -> UInt32? {
    guard let el = firstElement(with: kAudioDevicePropertyMute, on: id) else { return nil }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput, mElement: el)
    var val: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr else { return nil }
    return val
}

func setMute(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
    guard let el = firstElement(with: kAudioDevicePropertyMute, on: id) else { return false }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput, mElement: el)
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return false }
    var val: UInt32 = muted ? 1 : 0
    return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val) == noErr
}

func getVolume(_ id: AudioDeviceID) -> Float32? {
    guard let el = firstElement(with: kAudioDevicePropertyVolumeScalar, on: id) else { return nil }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: el)
    var val: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr else { return nil }
    return val
}

func setVolume(_ id: AudioDeviceID, _ vol: Float32) -> Bool {
    guard let el = firstElement(with: kAudioDevicePropertyVolumeScalar, on: id) else { return false }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: el)
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return false }
    var val = min(max(vol, 0), 1)
    return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &val) == noErr
}

func isRunning(_ id: AudioDeviceID) -> UInt32? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    guard AudioObjectHasProperty(id, &addr) else { return nil }
    var val: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr else { return nil }
    return val
}

func findDevice(_ query: String) -> AudioDeviceID? {
    let devs = allDevices()
    if let exact = devs.first(where: { deviceName($0) == query }) { return exact }
    let q = query.lowercased()
    let matches = devs.filter { (deviceName($0) ?? "").lowercased().contains(q) }
    if matches.count > 1 {
        return matches.first(where: { inputChannelCount($0) > 0 }) ?? matches.first
    }
    return matches.first
}

let args = CommandLine.arguments
let usage = """
usage: micctl list
       micctl get-mute   <device-name>
       micctl set-mute   <device-name> on|off
       micctl get-volume <device-name>
       micctl set-volume <device-name> <0.0-1.0>
"""
guard args.count >= 2 else { fail(usage) }

switch args[1] {
case "list":
    for id in allDevices() {
        let name = deviceName(id) ?? "?"
        let inCh = inputChannelCount(id)
        let mute = getMute(id).map { $0 == 1 ? "muted" : "unmuted" } ?? "-"
        let vol = getVolume(id).map { String(format: "%.2f", $0) } ?? "-"
        print("\(name)\tinput-channels=\(inCh)\tmute=\(mute)\tvolume=\(vol)")
    }
case "get-mute":
    guard args.count == 3 else { fail(usage) }
    guard let id = findDevice(args[2]) else { fail("device not found: \(args[2])") }
    guard let m = getMute(id) else { fail("no mute control on: \(deviceName(id) ?? args[2])") }
    print(m)
case "set-mute":
    guard args.count == 4 else { fail(usage) }
    guard let id = findDevice(args[2]) else { fail("device not found: \(args[2])") }
    let on = ["on", "1", "true", "muted"].contains(args[3].lowercased())
    guard setMute(id, on) else { fail("could not set mute on: \(deviceName(id) ?? args[2])") }
case "get-running":
    guard args.count == 3 else { fail(usage) }
    guard let id = findDevice(args[2]) else { fail("device not found: \(args[2])") }
    guard let r = isRunning(id) else { fail("no running property on: \(deviceName(id) ?? args[2])") }
    print(r)
case "get-volume":
    guard args.count == 3 else { fail(usage) }
    guard let id = findDevice(args[2]) else { fail("device not found: \(args[2])") }
    guard let v = getVolume(id) else { fail("no volume control on: \(deviceName(id) ?? args[2])") }
    print(String(format: "%.4f", v))
case "set-volume":
    guard args.count == 4, let v = Float32(args[3]) else { fail(usage) }
    guard let id = findDevice(args[2]) else { fail("device not found: \(args[2])") }
    guard setVolume(id, v) else { fail("could not set volume on: \(deviceName(id) ?? args[2])") }
default:
    fail(usage)
}
