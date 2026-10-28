import Foundation

struct Band: Codable, Equatable, Identifiable {
    var index: Int
    var type: FilterType
    var frequency: Double
    var q: Double
    var gain: Double
    var enabled: Bool

    var id: Int { index }

    static func flat(_ index: Int) -> Band {
        Band(index: index, type: .peak, frequency: Pearl.defaultFrequencies[index], q: 1, gain: 0, enabled: true)
    }

    /// The gain actually sent to the DAC: a disabled band is written as 0 dB.
    var effectiveGain: Double { enabled ? gain : 0 }

    /// Whether the DAC's reported state is indistinguishable from this band.
    func matchesHardware(_ hw: Band) -> Bool {
        if effectiveGain == 0 && hw.effectiveGain == 0 { return true }
        return type == hw.type
            && abs(frequency.rounded(.towardZero) - hw.frequency) < 1
            && abs(q - hw.q) < 0.02
            && abs(effectiveGain - hw.effectiveGain) < 0.11
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var preamp: Double = 0
    var bands: [Band]

    static func flat(named name: String) -> Preset {
        Preset(name: name, bands: (0..<Pearl.bandCount).map(Band.flat))
    }

    func matchesHardware(_ hw: [Band]) -> Bool {
        bands.count == hw.count && zip(bands, hw).allSatisfy { $0.matchesHardware($1) }
    }
}

struct Settings: Codable {
    /// The preset that mirrors whatever the DAC currently holds when no saved preset matches.
    static let devicePresetName = "Device"

    var presets: [Preset]
    var selectedPresetID: UUID?
    var balance = 0

    static var `default`: Settings {
        Settings(presets: [.flat(named: devicePresetName)], selectedPresetID: nil)
    }

    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BlackPearl", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("settings.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              var settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        if !settings.presets.contains(where: { $0.name == devicePresetName }) {
            settings.presets.insert(.flat(named: devicePresetName), at: 0)
        }
        return settings
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
