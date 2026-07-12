import CoreGraphics
import Foundation

// keysend <keycode> [modifier-keycode ...] — synthesize a real key chord the way
// Stream Deck's Hotkey action does: discrete modifier keydowns, then the key,
// then releases. System Events' `key code X using {option down}` only sets the
// event flag without posting the modifier press, which listeners that track
// physical modifier state (e.g. Wispr Flow's shortcut listener) never see.

let args = CommandLine.arguments.dropFirst().compactMap { UInt16($0) }
guard let key = args.first else {
    FileHandle.standardError.write("usage: keysend <keycode> [modifier-keycode ...]\n".data(using: .utf8)!)
    exit(1)
}
let mods = Array(args.dropFirst())

func flag(for mod: UInt16) -> CGEventFlags {
    switch mod {
    case 54, 55: return .maskCommand
    case 56, 60: return .maskShift
    case 58, 61: return .maskAlternate
    case 59, 62: return .maskControl
    case 63: return .maskSecondaryFn
    default: return []
    }
}

let src = CGEventSource(stateID: .hidSystemState)
var held = CGEventFlags()

func post(_ keyCode: UInt16, down: Bool, flags: CGEventFlags) {
    guard let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
    ev.flags = flags
    ev.post(tap: .cghidEventTap)
    usleep(25000)
}

for m in mods {
    held.insert(flag(for: m))
    post(m, down: true, flags: held)
}
post(key, down: true, flags: held)
post(key, down: false, flags: held)
for m in mods.reversed() {
    held.remove(flag(for: m))
    post(m, down: false, flags: held)
}
