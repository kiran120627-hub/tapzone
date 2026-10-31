import Foundation

/// Everything the user can change, saved as settings.json.
struct Settings: Codable {
    enum Level: String, Codable, CaseIterable { case low, medium, high }
    enum Speed: String, Codable, CaseIterable { case slow, normal, fast }

    var sensitivity = Level.medium
    var doubleSpeed = Speed.normal
    var doubleTap = true
    var actions: [String: [String: String]] = [
        "top-left": ["single": "desktop-left", "double": "none"],
        "top-right": ["single": "desktop-right", "double": "none"],
        "bottom-left": ["single": "play-pause", "double": "next-track"],
        "bottom-right": ["single": "mute-mic", "double": "none"],
    ]

    func action(_ corner: Corner, _ gesture: Gesture) -> String {
        actions[corner.name]?[gesture.rawValue] ?? "none"
    }

    mutating func setAction(_ corner: Corner, _ gesture: Gesture, _ action: String) {
        actions[corner.name, default: [:]][gesture.rawValue] = action
    }

    /// Trigger levels: higher sensitivity lets lighter taps count, lower ignores more jolts.
    var trigger: (multiplier: Double, floor: Double, background: Double) {
        switch sensitivity {
        case .low: (9, 3.0, 2.5)
        case .medium: (6, 2.0, 2.0)
        case .high: (4, 1.4, 1.6)
        }
    }

    /// The most time a second tap may take to count as a double tap.
    var doubleWindow: Double {
        switch doubleSpeed {
        case .slow: 0.8
        case .normal: 0.6
        case .fast: 0.45
        }
    }

    func waitsForDouble(_ corner: Corner) -> Bool { doubleTap && action(corner, .double) != "none" }
}

/// Where settings and calibration taps live: ~/Library/Application Support/Tapzone (or $TAPZONE_DIR).
enum Store {
    static let dir: URL = {
        if let custom = ProcessInfo.processInfo.environment["TAPZONE_DIR"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tapzone")
    }()
    static let settingsURL = dir.appendingPathComponent("settings.json")
    static let tapsURL = dir.appendingPathComponent("taps.json")

    static func loadSettings() -> Settings { load(settingsURL) ?? Settings() }
    static func save(_ s: Settings) { save(s, to: settingsURL) }
    static func loadTaps() -> [Sample] { load(tapsURL) ?? [] }
    static func save(_ taps: [Sample]) { save(taps, to: tapsURL) }

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            fail("\(url.lastPathComponent) could not be read (\(error.localizedDescription)). Fix or delete it.")
        }
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try enc.encode(value).write(to: url, options: .atomic)
        } catch {
            fail("could not save \(url.path): \(error.localizedDescription)")
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("tapzone: \(message)\n".utf8))
    exit(1)
}
