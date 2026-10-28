import Foundation

struct BiquadCoefficients: Equatable {
    var b0, b1, b2, a1, a2: Double
}

/// Audio EQ Cookbook biquads at the DAC's 48 kHz, normalised by a0 as the hardware expects.
enum Biquad {
    static let sampleRate = 48_000.0

    static func coefficients(type: FilterType, frequency: Double, q: Double, gainDB: Double) -> BiquadCoefficients {
        let f = frequency > 0 ? frequency : 1
        let q = q > 0 ? q : 0.01
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let sn = sin(w0), cs = cos(w0)
        let alpha = sn / (2 * q)
        let b0, b1, b2, a0, a1, a2: Double

        switch type {
        case .peak:
            b0 = 1 + alpha * A
            b1 = -2 * cs
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cs
            a2 = 1 - alpha / A
        case .lowShelf, .highShelf:
            let sqA = sqrt(A)
            let s: Double = type == .highShelf ? 1 : -1
            b0 = A * ((A + 1) + s * (A - 1) * cs + 2 * sqA * alpha)
            b1 = -s * 2 * A * ((A - 1) + s * (A + 1) * cs)
            b2 = A * ((A + 1) + s * (A - 1) * cs - 2 * sqA * alpha)
            a0 = (A + 1) - s * (A - 1) * cs + 2 * sqA * alpha
            a1 = s * 2 * ((A - 1) - s * (A + 1) * cs)
            a2 = (A + 1) - s * (A - 1) * cs - 2 * sqA * alpha
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func coefficients(for band: Band) -> BiquadCoefficients {
        coefficients(type: band.type, frequency: band.frequency, q: band.q, gainDB: band.effectiveGain)
    }

    static func responseDB(_ c: BiquadCoefficients, at hz: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let numRe = c.b0 + c.b1 * cos(w) + c.b2 * cos(2 * w)
        let numIm = -c.b1 * sin(w) - c.b2 * sin(2 * w)
        let denRe = 1 + c.a1 * cos(w) + c.a2 * cos(2 * w)
        let denIm = -c.a1 * sin(w) - c.a2 * sin(2 * w)
        let den = denRe * denRe + denIm * denIm
        guard den != 0 else { return 0 }
        let mag2 = (numRe * numRe + numIm * numIm) / den
        return mag2 > 0 ? 10 * log10(mag2) : 0
    }

    /// Combined response of every band that contributes, in dB.
    static func responseDB(_ coefficients: [BiquadCoefficients], at hz: Double) -> Double {
        coefficients.reduce(0) { $0 + responseDB($1, at: hz) }
    }

    /// Highest boost the current bands produce anywhere in the audible range,
    /// probed at the octave centres plus every band's own centre frequency.
    static func peakGainDB(of bands: [Band]) -> Double {
        let active = bands.filter { $0.effectiveGain != 0 }
        guard !active.isEmpty else { return 0 }
        let coeffs = active.map(coefficients(for:))
        let probes = [31.0, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] + active.map(\.frequency)
        return probes.map { responseDB(coeffs, at: $0) }.max() ?? 0
    }
}
