import AppKit

// A Korean/English key another process posts, such as Synergy's client typing a remote keyboard here. Posted events never
// pass the HID mapping, so the right modifier comes as itself instead of the F-key; the tap switches on it as it does on
// a Space combination.

// Right Command, Option and Control as macOS posts them: the key code, and the device bits telling the side.
private struct SideKey {
    let code: Int64
    let mask: CGEventFlags
    let right: CGEventFlags
    let left: CGEventFlags
}
private let sideKeys = [
    (sources[0], SideKey(code: 54, mask: .maskCommand, right: CGEventFlags(rawValue: 0x10), left: CGEventFlags(rawValue: 0x08))),
    (sources[1], SideKey(code: 61, mask: .maskAlternate, right: CGEventFlags(rawValue: 0x40), left: CGEventFlags(rawValue: 0x20))),
    (sources[3], SideKey(code: 62, mask: .maskControl, right: CGEventFlags(rawValue: 0x2000), left: CGEventFlags(rawValue: 0x01))),
]

struct SoftwareKeyGate {
    enum Decision: Equatable {
        case pass
        // The chosen key went down, switching, or up.
        case press, release
        // The chosen key's own event, already acted on.
        case consume
        // While it is held, posted events still carry its modifier; without it they are not shortcuts.
        case strip(CGEventFlags)
        // Its release never came; this event goes on.
        case lost
    }
    // The held key and the process that posted it.
    private(set) var held: (code: Int64, pid: Int64)?

    // Caps Lock is left out: a posting process only shares its lock, never a press.
    static func keyCode(_ source: UInt64) -> Int64? { sideKeys.first { $0.0 == source }?.1.code }
    private static func side(_ code: Int64) -> SideKey? { sideKeys.first { $0.1.code == code }?.1 }

    // `pid` is the posting process; a keyboard's own events have none and are the HID mapping's.
    mutating func handle(type: CGEventType, code: Int64, flags: CGEventFlags, pid: Int64, chosen: Set<Int64>) -> Decision {
        guard pid != 0 else { return .pass }
        // The held key's release ends what its press began, even if it is no longer chosen. Any poster's: Option input
        // replays a press it queued as this app's own.
        if let current = held, type == .flagsChanged, code == current.code, let key = Self.side(code), !flags.contains(key.right) {
            held = nil
            return .release
        }
        if type == .flagsChanged, chosen.contains(code), let key = Self.side(code) {
            // A release whose press came before is the app's, which saw that press.
            guard flags.contains(key.right) else { return .pass }
            guard held == nil else { return .consume }
            held = (code, pid)
            return .press
        }
        guard let current = held, let key = Self.side(current.code) else { return .pass }
        if flags.contains(key.right) {
            var stripped = flags.subtracting(key.right)
            if !flags.contains(key.left) { stripped.remove(key.mask) }
            return .strip(stripped)
        }
        // The poster's own event without its flag: the release was lost on the way.
        guard pid == current.pid else { return .pass }
        held = nil
        return .lost
    }
    mutating func reset() { held = nil }
}

extension Engine {
    // The chosen right modifiers a posted event can switch with, while the tap acts at all.
    var softwareKeyCodes: Set<Int64> {
        guard active, !paused else { return [] }
        return Set(defaultSources.compactMap(SoftwareKeyGate.keyCode))
    }
}

extension AppDelegate {
    // For every key and modifier event not this app's own. True takes the event; a key typed while the posted key is held
    // goes on without that key's modifier.
    func takeSoftwareKey(_ event: CGEvent, type: CGEventType) -> Bool {
        // A keyboard's own events, nearly all of them, skip reading the settings.
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard pid != 0 else { return false }
        let decision = softwareGate.handle(type: type, code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
            pid: pid, chosen: engine.softwareKeyCodes)
        switch decision {
        case .pass, .lost:
            return false
        case .consume, .release:
            // The release too: the app never saw the press.
            return true
        case .strip(let flags):
            event.flags = flags
            return false
        case .press:
            // As a Space combination does: a switch on press, with no long press. The poster types with its own
            // Caps Lock, so a lock set here would not show in what it types.
            guard let pulse = nativeSwitchPulse(keyCode: engine.target.keyCode, marker: nativePulseMarker) else {
                // Without the F-key the press goes on as the modifier it is.
                softwareGate.reset()
                return false
            }
            rememberCapsBeforeSwitch(event)
            switchHangul(pulse)
            return true
        }
    }
}
