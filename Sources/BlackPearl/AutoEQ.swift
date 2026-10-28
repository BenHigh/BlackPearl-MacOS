import Foundation

/// Reads and writes the AutoEQ / Equalizer APO "ParametricEQ.txt" format:
///
///     Preamp: -6.2 dB
///     Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.70
enum AutoEQ {
    struct Parsed {
        var preamp: Double?
        var bands: [Band]
    }

    static func parse(_ text: String) -> Parsed {
        var preamp: Double?
        var bands: [Band] = []

        for line in text.components(separatedBy: .newlines) {
            if line.contains("Preamp"), let value = number(after: "Preamp", in: line) {
                preamp = clamp(value, to: Pearl.preampRange)
                continue
            }
            guard line.contains("Filter"), bands.count < Pearl.bandCount else { continue }

            var band = Band.flat(bands.count)
            band.enabled = !line.contains(" OFF ")
            if line.contains(" LS") { band.type = .lowShelf }
            else if line.contains(" HS") { band.type = .highShelf }
            else { band.type = .peak }
            if let fc = number(after: "Fc", in: line) { band.frequency = clamp(fc, to: Pearl.frequencyRange) }
            if let gain = number(after: "Gain", in: line) { band.gain = clamp(gain, to: Pearl.gainRange) }
            if let q = number(after: "Q", in: line) { band.q = max(Pearl.qRange.lowerBound, q) }
            bands.append(band)
        }
        return Parsed(preamp: preamp, bands: bands)
    }

    static func export(_ preset: Preset) -> String {
        var lines = [String(format: "Preamp: %.1f dB", preset.preamp)]
        for (i, b) in preset.bands.enumerated() {
            lines.append(String(format: "Filter %d: %@ %@ Fc %.1f Hz Gain %.1f dB Q %.2f",
                                i + 1, b.enabled ? "ON" : "OFF", b.type.rawValue, b.frequency, b.gain, b.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func number(after key: String, in line: String) -> Double? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: key))\\s*:?\\s*([-+]?[0-9]*\\.?[0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return Double(line[range])
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
