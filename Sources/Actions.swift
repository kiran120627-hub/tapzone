import AppKit
import ApplicationServices

/// Runs the action strings stored in settings.json.
enum Actions {
    static let builtIn = ["desktop-left", "desktop-right", "play-pause", "next-track", "previous-track", "mute-mic", "none"]

    /// Returns an error message if `action` is not something `run` understands.
    static func validate(_ action: String) -> String? {
        if builtIn.contains(action) { return nil }
        if action.hasPrefix("open:") { return action.count > 5 ? nil : "open: needs an app name, like open:Spotify" }
        if action.hasPrefix("keys:") { return parseKeys(String(action.dropFirst(5))) == nil ? "unknown keys in \(action)" : nil }
        return "unknown action \"\(action)\". Use one of: \(builtIn.joined(separator: ", ")), open:<App>, keys:<shortcut>"
    }

    static func run(_ action: String) {
        switch action {
        case "none": break
        case "desktop-left": press(123, [.maskControl])
        case "desktop-right": press(124, [.maskControl])
        case "play-pause": media(16)
        case "next-track": media(17)
        case "previous-track": media(18)
        case "mute-mic": toggleMic()
        default:
            if action.hasPrefix("open:") {
                shell("/usr/bin/open", ["-a", String(action.dropFirst(5))])
            } else if action.hasPrefix("keys:"), let (key, flags) = parseKeys(String(action.dropFirst(5))) {
                press(key, flags)
            }
        }
    }

    // MARK: Keys

    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        for (i, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { m["f\(i + 1)"] = CGKeyCode(code) }
        return m
    }()

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "alt": .maskAlternate,
        "option": .maskAlternate, "ctrl": .maskControl, "control": .maskControl,
    ]

    /// "cmd+shift+4" → key code and modifier flags.
    static func parseKeys(_ text: String) -> (CGKeyCode, CGEventFlags)? {
        var flags = CGEventFlags()
        var key: CGKeyCode?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            if let m = modifiers[part] { flags.insert(m) } else if key == nil, let k = keyCodes[part] { key = k } else { return nil }
        }
        return key.map { ($0, flags) }
    }

    private static func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
        var flags = flags
        if (123...126).contains(key) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }  // arrows carry these
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Media keys are "system defined" events: key type in the high half of data1, down/up below it.
    private static func media(_ keyType: Int) {
        for state in [0xA, 0xB] {
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: keyType << 16 | state << 8, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Microphone

    private static var mutedFrom: Int?

    /// Sets the input volume to 0, or back to what it was before.
    private static func toggleMic() {
        let current = Int(osascript("input volume of (get volume settings)")) ?? 0
        if current > 0 {
            mutedFrom = current
            _ = osascript("set volume input volume 0")
            print("  microphone muted")
        } else {
            _ = osascript("set volume input volume \(mutedFrom ?? 75)")
            print("  microphone on")
        }
    }

    @discardableResult
    private static func osascript(_ script: String) -> String {
        shell("/usr/bin/osascript", ["-e", script])
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = out
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
