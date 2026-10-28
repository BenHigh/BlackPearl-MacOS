import Foundation

/// Wire protocol for the TRN Black Pearl (USB name "TE-C", vendor TTGK Technology),
/// ported from pyBlackPearl. Every exchange is one 64-byte HID report whose first
/// byte is the report ID 0x4B; byte 1 is the direction and byte 2 the command.
enum Pearl {
    static let vendorID = 0x3302
    static let productID = 0x43E8
    static let reportID: UInt8 = 0x4B
    static let reportSize = 64

    static let write: UInt8 = 0x01
    static let read: UInt8 = 0x80

    enum Cmd {
        static let flash: UInt8 = 0x01          // commit the EQ/volume buffer to persistent memory
        static let micGain: UInt8 = 0x02
        static let volume: UInt8 = 0x03
        static let peq: UInt8 = 0x09
        static let latch: UInt8 = 0x0A          // push buffered changes to the output stage
        static let version: UInt8 = 0x0C
        static let digitalFilter: UInt8 = 0x11
        static let balance: UInt8 = 0x16
        static let gainMode: UInt8 = 0x19
        static let ampMode: UInt8 = 0x1D
    }

    /// Hardware volume is a signed 16-bit value in 1/256 dB steps.
    static let volumeMinRaw = -9472
    static let volumeMaxRaw = 6440
    static let unitsPerDB = 256.0

    static let bandCount = 10
    static let defaultFrequencies: [Double] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 20000]
    static let gainRange: ClosedRange<Double> = -10...10
    static let frequencyRange: ClosedRange<Double> = 20...20000
    static let qRange: ClosedRange<Double> = 0.1...10
    static let preampRange: ClosedRange<Double> = -16...6
    static let balanceRange: ClosedRange<Int> = -15...15
    static let micGainRange: ClosedRange<Int> = -15...15
}

enum FilterType: String, Codable, CaseIterable, Identifiable {
    case peak = "PK"
    case lowShelf = "LS"
    case highShelf = "HS"

    var id: String { rawValue }

    var code: UInt8 {
        switch self {
        case .peak: return 0x02
        case .lowShelf: return 0x03
        case .highShelf: return 0x04
        }
    }

    var label: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        }
    }

    init(code: UInt8) {
        self = Self.allCases.first { $0.code == code } ?? .peak
    }
}

enum DigitalFilter: UInt8, CaseIterable, Identifiable {
    case fastLL = 0x01, fastPC = 0x02, slowLL = 0x03, slowPC = 0x04, nos = 0x05

    var id: UInt8 { rawValue }

    var name: String {
        switch self {
        case .fastLL: return "Fast roll-off, low latency"
        case .fastPC: return "Fast roll-off, phase compensated"
        case .slowLL: return "Slow roll-off, low latency"
        case .slowPC: return "Slow roll-off, phase compensated"
        case .nos: return "Non-oversampling"
        }
    }

    var detail: String {
        switch self {
        case .fastLL: return "Best for gaming."
        case .fastPC: return "Recommended for general listening."
        case .slowLL: return "Smoother treble transients."
        case .slowPC: return "Natural transient response."
        case .nos: return "Purest signal path, with high-frequency roll-off."
        }
    }
}

enum GainMode: UInt8, CaseIterable, Identifiable {
    case low = 0x00, high = 0x01
    var id: UInt8 { rawValue }
    var name: String { self == .low ? "Low" : "High" }
}

enum AmpMode: UInt8, CaseIterable, Identifiable {
    case classH = 0x00, classAB = 0x01
    var id: UInt8 { rawValue }
    var name: String { self == .classH ? "Class H" : "Class AB" }
}

/// Builders for outgoing reports. Each returns the full 64-byte buffer, report ID first.
enum Packet {
    static func frame(_ body: [UInt8]) -> [UInt8] {
        precondition(body.count < Pearl.reportSize)
        return [Pearl.reportID] + body + [UInt8](repeating: 0, count: Pearl.reportSize - 1 - body.count)
    }

    static func readVersion() -> [UInt8] { frame([Pearl.read, Pearl.Cmd.version, 0x00]) }
    static func readSetting(_ cmd: UInt8) -> [UInt8] { frame([Pearl.read, cmd, 0x00]) }
    static func readVolume() -> [UInt8] { frame([Pearl.read, Pearl.Cmd.volume, 0x00]) }
    static func readMicGain() -> [UInt8] { frame([Pearl.read, Pearl.Cmd.micGain, 0x02]) }
    static func readBalance(left: Bool) -> [UInt8] {
        frame([Pearl.read, Pearl.Cmd.balance, 0x04, left ? 0x01 : 0x00, 0x00, 0x00])
    }
    static func readBand(_ index: Int) -> [UInt8] {
        frame([Pearl.read, Pearl.Cmd.peq, 0x00, 0x00, UInt8(index), 0x00])
    }

    static func writeSetting(_ cmd: UInt8, value: UInt8) -> [UInt8] {
        frame([Pearl.write, cmd, 0x01, value])
    }

    static func writeVolume(raw: Int16) -> [UInt8] {
        let u = UInt16(bitPattern: raw)
        return frame([Pearl.write, Pearl.Cmd.volume, 0x03, UInt8(u & 0xFF), UInt8(u >> 8), 0x00])
    }

    static func latch() -> [UInt8] {
        frame([Pearl.write, Pearl.Cmd.latch, 0x04, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    }

    static func flash() -> [UInt8] { frame([Pearl.write, Pearl.Cmd.flash, 0x01, 0x00]) }

    static func writeMicGain(_ db: Int) -> [UInt8] {
        frame([Pearl.write, Pearl.Cmd.micGain, 0x02, 0x80, UInt8(bitPattern: Int8(clamping: db))])
    }

    /// Balance is two writes, left channel then right. `level` runs -15 (full left) to +15 (full right).
    static func writeBalance(level: Int) -> [[UInt8]] {
        let magL: UInt8 = level < 0 ? UInt8(256 + level) : 0
        let magR: UInt8 = level > 0 ? UInt8(256 - level) : 0
        return [
            frame([Pearl.write, Pearl.Cmd.balance, 0x04, 0x01, 0x00, magL]),
            frame([Pearl.write, Pearl.Cmd.balance, 0x04, 0x00, 0x00, magR]),
        ]
    }

    /// One PEQ slot: five normalised biquad coefficients as little-endian floats,
    /// then the human-readable parameters the DAC echoes back on read.
    static func writeBand(index: Int, band: Band, activeSlot: UInt8) -> [UInt8] {
        let gain = band.effectiveGain
        let freq = max(1, Int(band.frequency))
        let q = max(0.01, band.q)
        let c = Biquad.coefficients(type: band.type, frequency: Double(freq), q: q, gainDB: gain)
        var body: [UInt8] = [Pearl.write, Pearl.Cmd.peq, 0x18, 0x00, UInt8(index), 0x00, 0x00]
        for value in [c.b0, c.b1, c.b2, c.a1, c.a2] {
            body += le32(Float(value).bitPattern)
        }
        body += le16(UInt16(clamping: freq))
        body += le16(UInt16(clamping: Int(q * 256)))
        body += le16(UInt16(bitPattern: Int16(clamping: Int(gain * 256))))
        body += [band.type.code, 0x00, activeSlot, 0x00]
        return frame(body)
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
}

/// Decoded incoming reports.
enum Response: Equatable {
    case version(String)
    case band(index: Int, band: Band, activeSlot: UInt8)
    case volume(raw: Int16, preamp: Int8)
    case balance(left: Bool, level: Int)
    case micGain(Int)
    case setting(cmd: UInt8, value: UInt8)

    static func parse(_ d: [UInt8]) -> Response? {
        guard d.count >= 7, d[0] == Pearl.reportID, d[1] == Pearl.read else { return nil }
        switch d[2] {
        case Pearl.Cmd.version:
            let text = String(decoding: d[4...].prefix { $0 != 0 }, as: UTF8.self)
            return .version(text.trimmingCharacters(in: .whitespacesAndNewlines))

        case Pearl.Cmd.peq where d.count >= 37:
            let index = Int(d[5])
            let frequency = Double(u16(d[28], d[29]))
            let q = (Double(u16(d[30], d[31])) / 256).rounded(toPlaces: 2)
            var gain = (Double(Int16(bitPattern: u16(d[32], d[33]))) / 256).rounded(toPlaces: 1)
            if abs(gain) < 0.25 { gain = 0 }   // ghost gains the DAC reports for flat bands
            let band = Band(index: index, type: FilterType(code: d[34]), frequency: frequency, q: q, gain: gain, enabled: gain != 0)
            return .band(index: index, band: band, activeSlot: d[36])

        case Pearl.Cmd.volume:
            return .volume(raw: Int16(bitPattern: u16(d[4], d[5])), preamp: Int8(bitPattern: d[6]))

        case Pearl.Cmd.balance:
            let magnitude = Int(d[6])
            if d[4] == 0x01 {
                return .balance(left: true, level: magnitude > 0 ? magnitude - 256 : 0)
            }
            return .balance(left: false, level: magnitude > 0 ? 256 - magnitude : 0)

        case Pearl.Cmd.micGain where d[3] == 0x02:
            return .micGain(Int(Int8(bitPattern: d[5])))

        default:
            return .setting(cmd: d[2], value: d[4])
        }
    }

    private static func u16(_ lo: UInt8, _ hi: UInt8) -> UInt16 { UInt16(lo) | UInt16(hi) << 8 }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
