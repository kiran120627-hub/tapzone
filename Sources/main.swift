import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
tapzone: tap the corners of your MacBook screen to run actions.

  tapzone calibrate [--taps N]        teach it your taps (N per corner, default 10)
  tapzone run                         start listening for taps (Ctrl+C to stop)
  tapzone list                        show what every tap does, and the settings
  tapzone set <corner> <single|double> <action>
  tapzone set sensitivity low|medium|high
  tapzone set double-speed slow|normal|fast
  tapzone set double-tap on|off

Corners: top-left, top-right, bottom-left, bottom-right
Actions: desktop-left, desktop-right, play-pause, next-track, previous-track, mute-mic, none,
         open:<App name>   e.g. open:Spotify
         keys:<shortcut>   e.g. keys:cmd+shift+4
"""

// MARK: Shared sensor setup

/// Starts the sensor and a detector wired to it; hits arrive on the main queue.
func startListening(_ settings: Settings, onHit: @escaping (Hit) -> Void) -> (MotionSensor, TapDetector) {
    let sensor = MotionSensor(), detector = TapDetector()
    detector.sensitivity = settings.trigger.multiplier
    detector.floor = settings.trigger.floor
    detector.backgroundFactor = settings.trigger.background
    detector.lidAngle = { sensor.lidAngle }
    detector.onHit = { hit in DispatchQueue.main.async { onHit(hit) } }
    var samples = 0
    sensor.onSample = { channel, t, v in
        samples += 1
        if channel == .gyro { detector.gyro(t, v) } else { detector.accel(t, v) }
    }
    sensor.start()
    Thread.sleep(forTimeInterval: 1.5)   // also lets the idle-noise estimate settle
    if samples == 0 {
        fail("""
        no data from the motion sensor. It needs an Apple Silicon MacBook (M2 or later, or M1 Pro/Max).
        If you have one, allow Input Monitoring for your terminal app in System Settings → Privacy & Security, then retry.
        """)
    }
    let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    stop.setEventHandler { sensor.pause(); print("\nStopped."); exit(0) }
    stop.resume()
    keepAlive.append(stop)
    return (sensor, detector)
}

var keepAlive: [AnyObject] = []

/// A tiny picture of the screen with a dot on one corner.
func picture(_ corner: Corner) -> String {
    let cells = Corner.allCases.map { $0 == corner ? "●" : "·" }
    return "      \(cells[0]) \(cells[1])\n      \(cells[2]) \(cells[3])"
}

func report(_ model: CornerModel) {
    let acc = model.accuracy()
    var right = 0, total = 0
    print("\nHow well each corner is recognised (each tap checked against the others):")
    for c in Corner.allCases {
        guard let a = acc[c] else { continue }
        right += a.right; total += a.total
        print("  \(c.name.padding(toLength: 13, withPad: " ", startingAt: 0)) \(a.right)/\(a.total)  \(Int((Double(a.right) / Double(a.total) * 100).rounded()))%")
    }
    if total > 0 { print("  overall       \(Int((Double(right) / Double(total) * 100).rounded()))%") }
}

// MARK: calibrate

func calibrate(tapsPerCorner: Int) {
    let settings = Store.loadSettings()
    var taps: [Sample] = []
    var plan = (0..<tapsPerCorner).flatMap { _ in Corner.allCases.shuffled() }
    var bumps = false

    print("""
    Calibration: tap each corner when asked, about 2 cm in from the edge of the screen.
    Use a quick, light flick of a fingertip — never press hard. Wait half a second between taps.
    Keep your hands off the keyboard and trackpad while tapping. Type u and Enter to undo the last tap.
    If taps get recorded when you did not tap, stop with Ctrl+C and run: tapzone set sensitivity low

    """)
    func prompt() {
        guard let next = plan.first else { return }
        let done = taps.filter { $0.corner == next }.count
        print("→ Tap \(next.name.uppercased())  (\(done + 1)/\(tapsPerCorner))\n\(picture(next))")
    }

    func startBumps() {
        bumps = true
        print("""

        Taps done. Now 15 seconds of everyday bumps that are NOT taps:
        type a little, click, rest your hands on the laptop, nudge it on the desk.
        """)
        for s in stride(from: 15, through: 1, by: -1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(15 - s)) { print("  \(s)…") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish() }
    }

    func finish() {
        Store.save(taps)
        let model = CornerModel(taps)
        report(model)
        let n = taps.filter { $0.corner == nil }.count
        print("\nSaved \(taps.count - n) taps and \(n) bumps. Start it with: tapzone run")
        exit(0)
    }

    let (_, detector) = startListening(settings) { hit in
        if bumps {
            taps.append(Sample(corner: nil, features: Features.of(hit), peak: hit.peak, lid: hit.lid))
            return
        }
        guard let corner = plan.first else { return }
        if let why = hit.ignored { print("  ignored (\(why)), tap again"); return }
        taps.append(Sample(corner: corner, features: Features.of(hit), peak: hit.peak, lid: hit.lid))
        plan.removeFirst()
        print("  ✓  strength \(String(format: "%.1f", hit.peak))\n")
        if plan.isEmpty { startBumps() } else { prompt() }
    }

    Thread.detachNewThread {
        while let line = readLine() {
            guard line.trimmingCharacters(in: .whitespaces).lowercased() == "u" else { continue }
            DispatchQueue.main.async {
                guard !bumps, let last = taps.popLast(), let c = last.corner else { return }
                plan.insert(c, at: 0)
                print("  undone\n")
                prompt()
            }
        }
    }
    DispatchQueue.main.async {
        detector.useGates = true
        prompt()
    }
    // The bump phase records everything, including typing.
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in if bumps { detector.useGates = false } }
    RunLoop.main.run()
}

// MARK: run

/// True when nobody can be tapping: lid (nearly) shut, display asleep, or screen locked.
func shouldPause(lid: Int?) -> Bool {
    if let lid, lid < 30 { return true }
    if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["CGSSessionScreenIsLocked"] as? Bool == true
}

func run() {
    var settings = Store.loadSettings()
    let model = CornerModel(Store.loadTaps())
    if model.isEmpty { fail("not calibrated yet. Run: tapzone calibrate") }

    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(prompt) {
        print("Note: desktop switching, media and shortcut actions need Accessibility for your terminal app")
        print("      (System Settings → Privacy & Security → Accessibility). Restart tapzone after allowing it.\n")
    }

    var grouper = TapGrouper()
    func apply(_ s: Settings, to detector: TapDetector) {
        detector.sensitivity = s.trigger.multiplier
        detector.floor = s.trigger.floor
        detector.backgroundFactor = s.trigger.background
        grouper.window = s.doubleWindow
        grouper.waitsForDouble = { s.waitsForDouble($0) }
    }
    func fire(_ events: [(Corner, Gesture)]) {
        for (corner, gesture) in events {
            let action = settings.action(corner, gesture)
            print("\(corner.name) \(gesture.rawValue) → \(action)")
            Actions.run(action)
        }
    }

    let (sensor, detector) = startListening(settings) { hit in
        if let why = hit.ignored { print("  · ignored: \(why)"); return }
        let p = model.predict(Features.of(hit))
        guard let corner = p.corner else { print("  ? \(p.reason ?? "unknown")"); return }
        fire(grouper.tap(corner, at: hit.time))
    }
    apply(settings, to: detector)
    print("Listening. Tap a corner. Ctrl+C to stop.\n")

    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in fire(grouper.tick(at: Clock.now())) }

    // Once a second: pause the sensor when nobody can tap, and pick up edits to settings.json.
    var paused = false
    var settingsDate = modified(Store.settingsURL)
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        let pause = shouldPause(lid: sensor.lidAngle)
        if pause != paused {
            paused = pause
            if pause { sensor.pause() } else { sensor.resume() }
            print(pause ? "Paused (lid closed, display asleep or screen locked)." : "Listening again.")
        }
        let date = modified(Store.settingsURL)
        if date != settingsDate {
            settingsDate = date
            settings = Store.loadSettings()
            apply(settings, to: detector)
            print("Settings reloaded.")
        }
    }
    RunLoop.main.run()
}

func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

// MARK: list / set

func list() {
    let s = Store.loadSettings()
    print("Taps:")
    for c in Corner.allCases {
        for g in Gesture.allCases {
            let note = g == .double && !s.doubleTap ? "  (double tap is off)" : ""
            print("  \(c.name.padding(toLength: 13, withPad: " ", startingAt: 0)) \(g.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(s.action(c, g))\(note)")
        }
    }
    print("""

    Settings:
      sensitivity   \(s.sensitivity.rawValue)
      double-speed  \(s.doubleSpeed.rawValue)
      double-tap    \(s.doubleTap ? "on" : "off")
    """)
    let taps = Store.loadTaps()
    let n = taps.filter { $0.corner != nil }.count
    print("\nCalibration: \(n == 0 ? "none yet (run: tapzone calibrate)" : "\(n) taps")")
    print("Settings file: \(Store.settingsURL.path)")
}

func set(_ args: [String]) {
    var s = Store.loadSettings()
    func choose<T: RawRepresentable & CaseIterable>(_ value: String?, _: T.Type) -> T where T.RawValue == String {
        guard let v = value, let x = T(rawValue: v) else {
            fail("choose one of: \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return x
    }
    switch args.first {
    case "sensitivity": s.sensitivity = choose(args.dropFirst().first, Settings.Level.self)
    case "double-speed": s.doubleSpeed = choose(args.dropFirst().first, Settings.Speed.self)
    case "double-tap":
        guard let v = args.dropFirst().first, ["on", "off"].contains(v) else { fail("use: tapzone set double-tap on|off") }
        s.doubleTap = v == "on"
    case let name?:
        guard let corner = Corner(name: name) else { fail("unknown corner or setting \"\(name)\"\n\n\(usage)") }
        guard args.count >= 3 else { fail("use: tapzone set \(name) single|double <action>") }
        let gesture = choose(args[1], Gesture.self)
        let action = args[2...].joined(separator: " ")
        if let problem = Actions.validate(action) { fail(problem) }
        s.setAction(corner, gesture, action)
    case nil: fail(usage)
    }
    Store.save(s)
    print("Saved.")
}

// MARK: entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "calibrate":
    var n = 10
    if let i = args.firstIndex(of: "--taps"), i + 1 < args.count {
        guard let v = Int(args[i + 1]), (3...40).contains(v) else { fail("--taps must be between 3 and 40") }
        n = v
    }
    calibrate(tapsPerCorner: n)
case "run": run()
case "list": list()
case "set": set(Array(args.dropFirst()))
default: print(usage)
}
