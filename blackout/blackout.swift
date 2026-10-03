import CoreGraphics
import Foundation

// blackout — turns the built-in display fully black while leaving every
// external display alone, for using a laptop with display glasses in public.
//
// It works through the built-in panel's gamma table rather than a window: a
// window is part of the framebuffer, and in mirror mode the built-in and the
// glasses scan out the *same* framebuffer, so a black window would black out
// both. Gamma is applied per output, after the framebuffer, so it reaches only
// the panel it is set on. On a mini-LED panel an all-black signal also turns
// the local dimming zones off, so the panel goes properly dark, not just dim.
//
// The process has to stay alive: macOS restores ColorSync's gamma when the
// process that set it exits. That is the failsafe — kill it, crash it, or
// unplug the glasses (it exits on its own once no external display is left)
// and the built-in comes straight back.

func builtinAndExternalCount() -> (builtin: CGDirectDisplayID?, externals: Int) {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    let builtin = ids.first { CGDisplayIsBuiltin($0) != 0 }
    return (builtin, ids.filter { CGDisplayIsBuiltin($0) == 0 }.count)
}

func log(_ message: String) {
    FileHandle.standardError.write("blackout: \(message)\n".data(using: .utf8)!)
}

func restoreAndExit(_ code: Int32) -> Never {
    CGDisplayRestoreColorSyncSettings()
    exit(code)
}

// Re-applied rather than set once: macOS rewrites the gamma table on display
// reconfiguration, wake, and Night Shift / True Tone transitions, and none of
// those announce themselves reliably enough to depend on.
func apply() {
    let (builtin, externals) = builtinAndExternalCount()
    if externals == 0 {
        log("no external display left, restoring the built-in")
        restoreAndExit(0)
    }
    guard let id = builtin else { return } // lid closed: nothing to darken
    CGSetDisplayTransferByFormula(id, 0, 0, 1, 0, 0, 1, 0, 0, 1)
}

if builtinAndExternalCount().externals == 0 {
    log("refusing to black out the only display")
    exit(1)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { restoreAndExit(0) }
    source.resume()
    signalSources.append(source)
}

CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
    if !flags.contains(.beginConfigurationFlag) { DispatchQueue.main.async { apply() } }
}, nil)

apply()
_ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in apply() }
RunLoop.main.run()
