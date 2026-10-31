import CoreGraphics
import Foundation

/// One detected tap: 200 ms of high-passed gyro and accel, resampled to 800 Hz.
struct Hit {
    static let rate = 800.0
    static let length = 160          // 200 ms
    static let triggerIndex = 24     // 30 ms of lead-in before the trigger

    var time: Double
    var gyro: [SIMD3<Double>]
    var accel: [SIMD3<Double>]
    var peak: Double                 // deg/s
    var lid: Int?
    var ignored: String?             // why it should not count, if anything
}

/// Finds taps in the gyro stream.
///
/// A tap on the lid twists the laptop about its hinge, so the trigger is the size of the
/// high-passed gyro signal crossing `sensitivity × idle noise`. After a trigger it waits for the
/// rest of the window, then re-arms only once the laptop has settled again.
final class TapDetector {
    var sensitivity = 6.0            // trigger = this × idle noise
    var floor = 2.0                  // ...but never below this (deg/s)
    var backgroundFactor = 2.0       // ...nor below this × the recent background jolts
    var useGates = true              // ignore taps around typing, clicks, scrolls and lid moves
    var onHit: ((Hit) -> Void)?

    /// Current lid angle, read on every sample (wired to the sensor).
    var lidAngle: () -> Int? = { nil }
    /// Seconds since the last key, click or scroll (replaceable for tests).
    var secondsSinceInput: () -> Double = TapDetector.systemSecondsSinceInput

    private(set) var noise = 0.15
    var threshold: Double { max(floor, sensitivity * noise, backgroundFactor * background) }

    /// Typical size of the jolts the laptop gets anyway (lap, sofa, a busy desk): the median of
    /// the largest twist in each of the last 20 half-second stretches without a tap.
    private var background: Double {
        guard recentPeaks.count >= 4 else { return 0 }
        return recentPeaks.sorted()[recentPeaks.count / 2]
    }
    private var recentPeaks: [Double] = [], stretchPeak = 0.0, stretchStart: Double?
    private var firstSample: Double?

    private enum State { case armed, capturing(Double), settling(Double, quietSince: Double?) }
    private var state = State.armed
    private var gyroHP = HighPass(), accelHP = HighPass()
    private var gyroBuf = Ring(), accelBuf = Ring()
    private var lidBefore: Int?

    func gyro(_ t: Double, _ v: SIMD3<Double>) {
        let hp = gyroHP.step(t, v)
        gyroBuf.append(t, hp)
        let mag = length(hp)
        if firstSample == nil { firstSample = t }
        let warmingUp = t - firstSample! < 1.5   // the sensor and filter settle after start-up
        switch state {
        case .armed:
            trackBackground(t, mag)
            if mag > threshold && !warmingUp {
                state = .capturing(t)
            } else {
                noise += (mag - noise) * min(1, gyroHP.dt / 2)   // ~2 s running average
                lidBefore = lidAngle()
            }
        case .capturing(let t0):
            if t >= t0 + 0.17 {
                emit(t0)
                state = .settling(t0, quietSince: nil)
            }
        case .settling(let t0, let quietSince):
            if t - t0 > 0.2 && mag < threshold * 0.5 {
                let since = quietSince ?? t
                state = t - since > 0.04 ? .armed : .settling(t0, quietSince: since)
            } else {
                state = .settling(t0, quietSince: nil)
            }
        }
    }

    private func trackBackground(_ t: Double, _ mag: Double) {
        let start = stretchStart ?? t
        stretchPeak = max(stretchPeak, mag)
        stretchStart = start
        if t - start >= 0.5 {
            recentPeaks.append(stretchPeak)
            if recentPeaks.count > 20 { recentPeaks.removeFirst() }
            stretchPeak = 0
            stretchStart = t
        }
    }

    func accel(_ t: Double, _ v: SIMD3<Double>) {
        accelBuf.append(t, accelHP.step(t, v))
    }

    private func emit(_ t0: Double) {
        let start = t0 - Double(Hit.triggerIndex) / Hit.rate
        let g = gyroBuf.resample(from: start), a = accelBuf.resample(from: start)
        let lid = lidAngle()
        var hit = Hit(time: t0, gyro: g, accel: a, peak: g.map(length).max() ?? 0, lid: lid)
        if useGates {
            let before = g[0..<Hit.triggerIndex - 4].map(length).max() ?? 0
            if secondsSinceInput() < 0.3 + 0.17 {
                hit.ignored = "typing or using the trackpad"
            } else if let a = lidBefore, let b = lid, abs(a - b) >= 2 {
                hit.ignored = "lid moved"
            } else if before > 0.5 * threshold {
                hit.ignored = "laptop was already moving"
            }
        }
        stretchPeak = 0
        stretchStart = nil
        onHit?(hit)
    }

    static func systemSecondsSinceInput() -> Double {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                    .otherMouseDown, .mouseMoved, .leftMouseDragged, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}

func length(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }

/// First-order 5 Hz high-pass that copes with an uneven or changing sample rate.
struct HighPass {
    private var lastT: Double?, lastIn = SIMD3<Double>(), lastOut = SIMD3<Double>()
    private(set) var dt = 1 / 800.0

    mutating func step(_ t: Double, _ x: SIMD3<Double>) -> SIMD3<Double> {
        defer { lastT = t; lastIn = x }
        guard let lt = lastT, t > lt, t - lt < 0.5 else { lastOut = .zero; return .zero }
        dt = t - lt
        let rc = 1 / (2 * Double.pi * 5)
        let alpha = rc / (rc + dt)
        lastOut = alpha * (lastOut + x - lastIn)
        return lastOut
    }
}

/// The last ~0.6 s of samples, with linear resampling onto the 800 Hz hit grid.
struct Ring {
    private var times: [Double] = [], values: [SIMD3<Double>] = []

    mutating func append(_ t: Double, _ v: SIMD3<Double>) {
        times.append(t); values.append(v)
        if times.count > 1200, let cut = times.firstIndex(where: { $0 > t - 0.6 }) {
            times.removeFirst(cut); values.removeFirst(cut)
        }
    }

    func resample(from start: Double) -> [SIMD3<Double>] {
        guard !times.isEmpty else { return Array(repeating: .zero, count: Hit.length) }
        var out: [SIMD3<Double>] = [], j = 0
        for i in 0..<Hit.length {
            let t = start + Double(i) / Hit.rate
            while j + 1 < times.count && times[j + 1] < t { j += 1 }
            if t <= times[0] { out.append(values[0]); continue }
            if j + 1 >= times.count { out.append(values[j]); continue }
            let f = (t - times[j]) / (times[j + 1] - times[j])
            out.append(values[j] + (values[j + 1] - values[j]) * f)
        }
        return out
    }
}
