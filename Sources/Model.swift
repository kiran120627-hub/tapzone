import Foundation

/// A labelled training tap. `corner` is nil for a bump (something that is not a tap).
struct Sample: Codable {
    var corner: Corner?
    var features: [Double]
    var peak: Double
    var lid: Int?
}

/// Describes a tap by the direction and shape of the twist, independent of how hard it was.
enum Features {
    static func of(_ hit: Hit) -> [Double] {
        let g = hit.gyro, a = hit.accel, t0 = Hit.triggerIndex
        let s = max(hit.peak, 1e-6)
        let p = g.indices.max { length(g[$0]) < length(g[$1]) } ?? t0

        var f: [Double] = []
        // Which way the laptop twisted at the peak, and in the first 20 / 60 ms.
        f += array(g[p] / s)
        for n in [16, 48] {
            let sum = g[t0..<min(t0 + n, g.count)].reduce(SIMD3<Double>(), +)
            f += array(sum / (s * Double(n)))
        }
        // How the twist and the shake are shared between the three axes.
        let ge = energy(g), ae = energy(a)
        f += array(ge / max(ge.sum(), 1e-12))
        f += array(ae / max(ae.sum(), 1e-12))
        f.append(log((ge.sum() + 1e-9) / (ae.sum() * 1e4 + 1e-9)) / 4)
        // The first 100 ms of the twist as a coarse waveform, weighted down.
        for i in stride(from: t0 - 8, to: t0 + 72, by: 5) {
            f += array(g[i] / s).map { $0 * 0.4 }
        }
        return f
    }

    private static func array(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
    private static func energy(_ x: [SIMD3<Double>]) -> SIMD3<Double> { x.reduce(SIMD3<Double>()) { $0 + $1 * $1 } }
}

/// k-nearest-neighbours over standardised features, with bumps as their own class.
struct CornerModel {
    struct Prediction { var corner: Corner?; var confidence: Double; var reason: String? }

    private var samples: [Sample] = []
    private var mean: [Double] = [], scale: [Double] = []
    private var typicalDistance: [Corner: Double] = [:]
    let k = 5

    init(_ data: [Sample]) {
        samples = data
        guard let n = data.first?.features.count else { return }
        let taps = data.filter { $0.corner != nil }
        let rows = taps.isEmpty ? data : taps
        mean = (0..<n).map { j in rows.map { $0.features[j] }.reduce(0, +) / Double(rows.count) }
        scale = (0..<n).map { j in
            let v = rows.map { pow($0.features[j] - mean[j], 2) }.reduce(0, +) / Double(rows.count)
            return 1 / max(v.squareRoot(), 0.05)
        }
        // How far a tap usually is from its nearest neighbour in the same corner.
        for c in Corner.allCases {
            let own = data.indices.filter { data[$0].corner == c }
            let d = own.compactMap { i in own.filter { $0 != i }.map { distance(data[i].features, data[$0].features) }.min() }
            typicalDistance[c] = d.isEmpty ? nil : d.sorted()[d.count / 2]
        }
    }

    var isEmpty: Bool { !samples.contains { $0.corner != nil } }

    func distance(_ a: [Double], _ b: [Double]) -> Double {
        var d = 0.0
        for j in a.indices { let x = (a[j] - b[j]) * scale[j]; d += x * x }
        return d.squareRoot()
    }

    func predict(_ features: [Double], excluding skip: Int? = nil) -> Prediction {
        let near = samples.indices.filter { $0 != skip }
            .map { (samples[$0].corner, distance(features, samples[$0].features)) }
            .sorted { $0.1 < $1.1 }.prefix(k)
        guard !near.isEmpty else { return Prediction(corner: nil, confidence: 0, reason: "not calibrated") }

        var votes: [Corner?: Double] = [:]
        for (c, d) in near { votes[c, default: 0] += 1 / (d + 1e-3) }
        let total = votes.values.reduce(0, +)
        let (winner, weight) = votes.max { $0.value < $1.value }!
        let confidence = weight / total
        guard let corner = winner else { return Prediction(corner: nil, confidence: confidence, reason: "looked like a bump") }
        if confidence < 0.6 { return Prediction(corner: nil, confidence: confidence, reason: "not sure which corner") }
        let nearest = near.first { $0.0 == corner }!.1
        if let typical = typicalDistance[corner], nearest > typical * 3 {
            return Prediction(corner: nil, confidence: confidence, reason: "unlike any calibrated tap")
        }
        return Prediction(corner: corner, confidence: confidence, reason: nil)
    }

    /// Leave-one-out accuracy per corner: each tap judged by a model that never saw it.
    func accuracy() -> [Corner: (right: Int, total: Int)] {
        var out: [Corner: (right: Int, total: Int)] = [:]
        for (i, s) in samples.enumerated() {
            guard let c = s.corner else { continue }
            let p = predict(s.features, excluding: i)
            out[c, default: (0, 0)].total += 1
            if p.corner == c { out[c]!.right += 1 }
        }
        return out
    }
}
