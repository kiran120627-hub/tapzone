import Foundation

enum Corner: Int, CaseIterable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight

    var name: String { ["top-left", "top-right", "bottom-left", "bottom-right"][rawValue] }
    init?(name: String) { self.init(rawValue: Corner.allCases.firstIndex { $0.name == name } ?? -1) }
}

enum Gesture: String, Codable, CaseIterable { case single, double }

/// Turns recognised taps into single and double taps.
///
/// A tap waits up to `window` seconds for a second tap on the same corner, but only when that
/// corner has a double-tap action; otherwise it fires at once. Driven by explicit timestamps so
/// it can be tested without a clock.
struct TapGrouper {
    var window = 0.55
    var waitsForDouble: (Corner) -> Bool = { _ in true }
    private var pending: (corner: Corner, time: Double)?

    mutating func tap(_ corner: Corner, at t: Double) -> [(Corner, Gesture)] {
        var out = tick(at: t)
        if let p = pending, p.corner == corner {
            pending = nil
            return out + [(corner, .double)]
        }
        if let p = pending {            // a different corner: the first one was a single tap
            out.append((p.corner, .single))
            pending = nil
        }
        if waitsForDouble(corner) {
            pending = (corner, t)
        } else {
            out.append((corner, .single))
        }
        return out
    }

    mutating func tick(at t: Double) -> [(Corner, Gesture)] {
        guard let p = pending, t - p.time > window else { return [] }
        pending = nil
        return [(p.corner, .single)]
    }
}
