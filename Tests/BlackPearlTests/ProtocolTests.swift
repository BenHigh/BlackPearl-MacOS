import XCTest
@testable import BlackPearl

/// Byte-level checks against the packets pyBlackPearl sends, so the port can be
/// verified without a DAC attached.
final class ProtocolTests: XCTestCase {
    func testFramesAre64BytesWithReportIDFirst() {
        for packet in [Packet.readVersion(), Packet.latch(), Packet.flash(), Packet.writeVolume(raw: 0)] {
            XCTAssertEqual(packet.count, 64)
            XCTAssertEqual(packet[0], 0x4B)
        }
    }

    func testSimpleReads() {
        XCTAssertEqual(Array(Packet.readVersion().prefix(4)), [0x4B, 0x80, 0x0C, 0x00])
        XCTAssertEqual(Array(Packet.readSetting(0x11).prefix(4)), [0x4B, 0x80, 0x11, 0x00])
        XCTAssertEqual(Array(Packet.readMicGain().prefix(4)), [0x4B, 0x80, 0x02, 0x02])
        XCTAssertEqual(Array(Packet.readBalance(left: true).prefix(7)), [0x4B, 0x80, 0x16, 0x04, 0x01, 0x00, 0x00])
        XCTAssertEqual(Array(Packet.readBand(7).prefix(7)), [0x4B, 0x80, 0x09, 0x00, 0x00, 0x07, 0x00])
    }

    func testSettingAndHousekeepingWrites() {
        XCTAssertEqual(Array(Packet.writeSetting(0x19, value: 0x01).prefix(5)), [0x4B, 0x01, 0x19, 0x01, 0x01])
        XCTAssertEqual(Array(Packet.latch().prefix(9)), [0x4B, 0x01, 0x0A, 0x04, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        XCTAssertEqual(Array(Packet.flash().prefix(5)), [0x4B, 0x01, 0x01, 0x01, 0x00])
        XCTAssertEqual(Array(Packet.writeMicGain(-3).prefix(6)), [0x4B, 0x01, 0x02, 0x02, 0x80, 0xFD])
    }

    func testVolumeIsLittleEndianSigned() {
        // -9472 == 0xDB00
        XCTAssertEqual(Array(Packet.writeVolume(raw: -9472).prefix(7)), [0x4B, 0x01, 0x03, 0x03, 0x00, 0xDB, 0x00])
        // 6440 == 0x1928
        XCTAssertEqual(Array(Packet.writeVolume(raw: 6440).prefix(7)), [0x4B, 0x01, 0x03, 0x03, 0x28, 0x19, 0x00])
    }

    func testBalancePacketsMatchPyBlackPearl() {
        let fullLeft = Packet.writeBalance(level: -15)
        XCTAssertEqual(Array(fullLeft[0].prefix(7)), [0x4B, 0x01, 0x16, 0x04, 0x01, 0x00, 0xF1])
        XCTAssertEqual(Array(fullLeft[1].prefix(7)), [0x4B, 0x01, 0x16, 0x04, 0x00, 0x00, 0x00])

        let right5 = Packet.writeBalance(level: 5)
        XCTAssertEqual(Array(right5[0].prefix(7)), [0x4B, 0x01, 0x16, 0x04, 0x01, 0x00, 0x00])
        XCTAssertEqual(Array(right5[1].prefix(7)), [0x4B, 0x01, 0x16, 0x04, 0x00, 0x00, 0xFB])

        let center = Packet.writeBalance(level: 0)
        XCTAssertEqual(center[0][6], 0x00)
        XCTAssertEqual(center[1][6], 0x00)
    }

    func testBandPacketLayout() {
        let band = Band(index: 3, type: .lowShelf, frequency: 1000, q: 0.7, gain: -3.5, enabled: true)
        let packet = Packet.writeBand(index: 3, band: band, activeSlot: 0x02)

        XCTAssertEqual(Array(packet.prefix(8)), [0x4B, 0x01, 0x09, 0x18, 0x00, 0x03, 0x00, 0x00])
        XCTAssertEqual(Array(packet[28...29]), [0xE8, 0x03])            // 1000 Hz
        XCTAssertEqual(Array(packet[30...31]), [0xB3, 0x00])            // int(0.7 * 256) == 179
        XCTAssertEqual(Array(packet[32...33]), [0x80, 0xFC])            // int(-3.5 * 256) == -896 == 0xFC80
        XCTAssertEqual(packet[34], 0x03)                                // LS
        XCTAssertEqual(packet[36], 0x02)                                // active slot echoed back

        // Coefficients are IEEE-754 floats, little-endian, normalised by a0.
        let expected = Biquad.coefficients(type: .lowShelf, frequency: 1000, q: 0.7, gainDB: -3.5)
        let floats = stride(from: 8, to: 28, by: 4).map { offset -> Float in
            let bits = UInt32(packet[offset]) | UInt32(packet[offset + 1]) << 8 | UInt32(packet[offset + 2]) << 16 | UInt32(packet[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
        XCTAssertEqual(floats, [expected.b0, expected.b1, expected.b2, expected.a1, expected.a2].map(Float.init))
    }

    func testDisabledBandIsWrittenFlat() {
        let band = Band(index: 0, type: .peak, frequency: 100, q: 2, gain: 6, enabled: false)
        let packet = Packet.writeBand(index: 0, band: band, activeSlot: 0)
        XCTAssertEqual(Array(packet[32...33]), [0x00, 0x00])
        let b0 = Float(bitPattern: UInt32(packet[8]) | UInt32(packet[9]) << 8 | UInt32(packet[10]) << 16 | UInt32(packet[11]) << 24)
        XCTAssertEqual(b0, 1, accuracy: 1e-6)
    }

    func testBandResponseRoundTrips() {
        let band = Band(index: 5, type: .highShelf, frequency: 8000, q: 1.25, gain: 4.2, enabled: true)
        var bytes = Packet.writeBand(index: 5, band: band, activeSlot: 0x01)
        bytes[1] = 0x80   // the DAC echoes the same layout back as a read

        guard case .band(let index, let parsed, let slot)? = Response.parse(bytes) else {
            return XCTFail("did not parse as a band")
        }
        XCTAssertEqual(index, 5)
        XCTAssertEqual(slot, 0x01)
        XCTAssertEqual(parsed.type, .highShelf)
        XCTAssertEqual(parsed.frequency, 8000)
        XCTAssertEqual(parsed.q, 1.25, accuracy: 0.01)
        XCTAssertEqual(parsed.gain, 4.2, accuracy: 0.05)
        XCTAssertTrue(parsed.enabled)
        XCTAssertTrue(band.matchesHardware(parsed))
    }

    func testGhostGainsSnapToZero() {
        var bytes = Packet.writeBand(index: 0, band: Band(index: 0, type: .peak, frequency: 100, q: 1, gain: 0.2, enabled: true), activeSlot: 0)
        bytes[1] = 0x80
        guard case .band(_, let parsed, _)? = Response.parse(bytes) else { return XCTFail() }
        XCTAssertEqual(parsed.gain, 0)
        XCTAssertFalse(parsed.enabled)
    }

    func testOtherResponses() {
        XCTAssertEqual(Response.parse(Packet.frame([0x80, 0x0C, 0x00, 0x30, 0x2E, 0x36, 0x00, 0x41])), .version("0.6"))
        XCTAssertEqual(Response.parse(Packet.frame([0x80, 0x03, 0x00, 0x00, 0xDB, 0xFD])), .volume(raw: -9472, preamp: -3))
        XCTAssertEqual(Response.parse(Packet.frame([0x80, 0x16, 0x04, 0x01, 0x00, 0xF1])), .balance(left: true, level: -15))
        XCTAssertEqual(Response.parse(Packet.frame([0x80, 0x16, 0x04, 0x00, 0x00, 0xFB])), .balance(left: false, level: 5))
        XCTAssertEqual(Response.parse(Packet.frame([0x80, 0x16, 0x04, 0x00, 0x00, 0x00])), .balance(left: false, level: 0))
        XCTAssertEqual(Response.parse(Packet.frame([0x80, 0x02, 0x02, 0x00, 0xF4])), .micGain(-12))
        XCTAssertEqual(Response.parse(Packet.frame([0x80, 0x11, 0x00, 0x02])), .setting(cmd: 0x11, value: 0x02))
        XCTAssertNil(Response.parse(Packet.frame([0x01, 0x11, 0x00, 0x02])))   // our own writes aren't responses
        XCTAssertNil(Response.parse([0x00, 0x80, 0x11]))
    }

    func testAutoEQRoundTrip() {
        let text = """
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 3.0 dB Q 0.70
        Filter 2: ON PK Fc 1500 Hz Gain -2.5 dB Q 1.41
        Filter 3: OFF HSC Fc 9000 Hz Gain 12 dB Q 0.5
        """
        let parsed = AutoEQ.parse(text)
        XCTAssertEqual(parsed.preamp, -6.2)
        XCTAssertEqual(parsed.bands.count, 3)
        XCTAssertEqual(parsed.bands[0].type, .lowShelf)
        XCTAssertEqual(parsed.bands[0].frequency, 105)
        XCTAssertEqual(parsed.bands[1].gain, -2.5)
        XCTAssertEqual(parsed.bands[1].q, 1.41)
        XCTAssertEqual(parsed.bands[2].type, .highShelf)
        XCTAssertFalse(parsed.bands[2].enabled)
        XCTAssertEqual(parsed.bands[2].gain, 10)   // clamped to the DAC's ±10 dB

        var preset = Preset.flat(named: "Test")
        preset.preamp = -6.2
        for b in parsed.bands { preset.bands[b.index] = b }
        let reparsed = AutoEQ.parse(AutoEQ.export(preset))
        XCTAssertEqual(reparsed.preamp, -6.2)
        XCTAssertEqual(reparsed.bands.prefix(3).map(\.frequency), [105, 1500, 9000])
        XCTAssertEqual(reparsed.bands[2].enabled, false)
    }

    @MainActor
    func testSortingRenumbersSlots() {
        var bands = (0..<Pearl.bandCount).map(Band.flat)
        bands[7].frequency = 15000
        bands[8].frequency = 8000
        bands[9].frequency = 16000
        let sorted = DeviceController.sortedByFrequency(bands)
        XCTAssertEqual(sorted.map(\.frequency), [31, 63, 125, 250, 500, 1000, 2000, 8000, 15000, 16000])
        XCTAssertEqual(sorted.map(\.index), Array(0..<Pearl.bandCount))
    }

    func testPeakGainAndHeadroom() {
        var bands = (0..<Pearl.bandCount).map(Band.flat)
        XCTAssertEqual(Biquad.peakGainDB(of: bands), 0)
        bands[4].gain = 6
        XCTAssertEqual(Biquad.peakGainDB(of: bands), 6, accuracy: 0.05)
        bands[4].enabled = false
        XCTAssertEqual(Biquad.peakGainDB(of: bands), 0)
    }
}
