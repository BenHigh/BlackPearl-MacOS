import Foundation
import IOKit

/// Owns the connection and mirrors the DAC's state for the UI. Writes are coalesced
/// (40 ms), latched to the output stage, and committed to the DAC's flash after 3 s
/// of inactivity — the same cadence pyBlackPearl settled on.
@MainActor
final class DeviceController: ObservableObject {
    private enum ResponseKey: Hashable {
        case version, volume, micGain, balanceLeft, balanceRight
        case band(Int)
        case setting(UInt8)
    }

    @Published private(set) var isConnected = false
    @Published private(set) var isSyncing = false
    @Published private(set) var accessError: String?
    @Published private(set) var productName = "—"
    @Published private(set) var serialNumber = "—"
    @Published private(set) var firmware = "—"
    @Published private(set) var volumeRaw = 0
    @Published private(set) var balance = 0
    @Published private(set) var micGain = 0
    @Published private(set) var digitalFilter: DigitalFilter = .fastPC
    @Published private(set) var gainMode: GainMode = .low
    @Published private(set) var ampMode: AmpMode = .classH
    @Published private(set) var settings: Settings
    @Published private(set) var selectedPresetID: UUID
    @Published var selectedBand = 0
    @Published private(set) var notice: String?

    private let transport = HIDTransport(vendorID: Pearl.vendorID, productID: Pearl.productID)
    private var responses: [ResponseKey: Response] = [:]
    private var activeSlot: UInt8 = 0
    private var dirtyBands = Set<Int>()
    private var volumeDirty = false
    private var writeTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init() {
        let loaded = Settings.load()
        settings = loaded
        selectedPresetID = loaded.presets.first { $0.id == loaded.selectedPresetID }?.id ?? loaded.presets[0].id

        transport.onReport = { [weak self] in self?.handle($0) }
        transport.onConnection = { [weak self] in self?.connectionChanged($0) }

        let result = transport.start()
        if result != kIOReturnSuccess {
            let notPermitted = IOReturn(bitPattern: 0xE000_02E1)
            accessError = result == notPermitted
                ? "macOS denied access to the DAC's HID interface. Allow Black Pearl under System Settings → Privacy & Security → Input Monitoring, then relaunch."
                : String(format: "Could not start HID manager (0x%08X).", UInt32(bitPattern: result))
        }
    }

    // MARK: - Derived state

    var currentPreset: Preset {
        settings.presets.first { $0.id == selectedPresetID } ?? settings.presets[0]
    }
    var bands: [Band] { currentPreset.bands }
    var isDevicePresetSelected: Bool { currentPreset.name == Settings.devicePresetName }

    var volumePercent: Double {
        Double(volumeRaw - Pearl.volumeMinRaw) / Double(Pearl.volumeMaxRaw - Pearl.volumeMinRaw) * 100
    }
    var volumeDB: Double { Double(volumeRaw) / Pearl.unitsPerDB }
    var headroomDB: Double { Double(Pearl.volumeMaxRaw - volumeRaw) / Pearl.unitsPerDB }
    var peakEQGainDB: Double { Biquad.peakGainDB(of: bands) }
    var safeMaxVolumeRaw: Int { Pearl.volumeMaxRaw - Int(max(0, peakEQGainDB) * Pearl.unitsPerDB) }
    var isClipping: Bool { volumeRaw > safeMaxVolumeRaw }

    // MARK: - Connection

    private func connectionChanged(_ connected: Bool) {
        isConnected = connected
        if connected {
            productName = transport.productName ?? "TE-C"
            serialNumber = transport.serialNumber ?? "—"
            Task { await sync() }
            startPolling()
        } else {
            pollTask?.cancel(); pollTask = nil
            writeTask?.cancel(); writeTask = nil
            flashTask?.cancel(); flashTask = nil
            dirtyBands.removeAll()
            volumeDirty = false
            firmware = "—"; serialNumber = "—"; productName = "—"
        }
    }

    /// The DAC's own buttons change volume without telling us, so poll while idle.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.isConnected, !self.isSyncing, self.writeTask == nil {
                    self.transport.send(Packet.readVolume())
                }
            }
        }
    }

    private func handle(_ bytes: [UInt8]) {
        guard let response = Response.parse(bytes) else { return }
        switch response {
        case .version:
            responses[.version] = response
        case .band(let index, _, let slot):
            responses[.band(index)] = response
            activeSlot = slot
        case .volume(let raw, _):
            responses[.volume] = response
            if !isSyncing, !volumeDirty, writeTask == nil, Int(raw) != volumeRaw {
                volumeRaw = Int(raw)
            }
        case .balance(let left, _):
            responses[left ? .balanceLeft : .balanceRight] = response
        case .micGain:
            responses[.micGain] = response
        case .setting(let cmd, _):
            responses[.setting(cmd)] = response
        }
    }

    // MARK: - Sync from hardware

    func sync() async {
        guard isConnected, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        responses.removeAll()

        var reads: [([UInt8], ResponseKey)] = [
            (Packet.readVersion(), .version),
            (Packet.readSetting(Pearl.Cmd.digitalFilter), .setting(Pearl.Cmd.digitalFilter)),
            (Packet.readSetting(Pearl.Cmd.gainMode), .setting(Pearl.Cmd.gainMode)),
            (Packet.readSetting(Pearl.Cmd.ampMode), .setting(Pearl.Cmd.ampMode)),
            (Packet.readVolume(), .volume),
            (Packet.readMicGain(), .micGain),
            (Packet.readBalance(left: true), .balanceLeft),
            (Packet.readBalance(left: false), .balanceRight),
        ]
        reads += (0..<Pearl.bandCount).map { (Packet.readBand($0), .band($0)) }

        for (packet, key) in reads {
            var ok = false
            for _ in 0..<2 where !ok {
                ok = await sendAndWait(packet, key)
            }
        }
        applySyncedState()
    }

    private func sendAndWait(_ packet: [UInt8], _ key: ResponseKey, timeout: Duration = .milliseconds(150)) async -> Bool {
        responses[key] = nil
        guard transport.send(packet) else { return false }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if responses[key] != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func applySyncedState() {
        if case .version(let v)? = responses[.version] { firmware = v.isEmpty ? "Unknown" : v }

        var devicePreamp = 0.0
        if case .volume(let raw, let preamp)? = responses[.volume] {
            volumeRaw = Int(raw)
            devicePreamp = Double(preamp)
        }
        if case .micGain(let v)? = responses[.micGain] { micGain = v }

        var left = 0, right = 0
        if case .balance(_, let v)? = responses[.balanceLeft] { left = v }
        if case .balance(_, let v)? = responses[.balanceRight] { right = v }
        var level = abs(left) > abs(right) ? left : right
        if abs(level) <= 1 { level = 0 }
        balance = level

        if case .setting(_, let v)? = responses[.setting(Pearl.Cmd.digitalFilter)], let f = DigitalFilter(rawValue: v) { digitalFilter = f }
        if case .setting(_, let v)? = responses[.setting(Pearl.Cmd.gainMode)], let g = GainMode(rawValue: v) { gainMode = g }
        if case .setting(_, let v)? = responses[.setting(Pearl.Cmd.ampMode)], let a = AmpMode(rawValue: v) { ampMode = a }

        var hardware = (0..<Pearl.bandCount).map(Band.flat)
        for i in 0..<Pearl.bandCount {
            if case .band(_, let band, _)? = responses[.band(i)] { hardware[i] = band }
        }

        // Prefer a user preset that matches what the DAC holds; otherwise mirror it in "Device".
        let userMatch = settings.presets.first { $0.name != Settings.devicePresetName && $0.matchesHardware(hardware) }
        if let match = userMatch {
            selectedPresetID = match.id
        } else {
            let index = devicePresetIndex
            settings.presets[index].bands = hardware
            settings.presets[index].preamp = devicePreamp
            selectedPresetID = settings.presets[index].id
        }
        persist()
    }

    // MARK: - EQ edits

    func updateBand(_ band: Band) {
        var preset = currentPreset
        guard preset.bands.indices.contains(band.index) else { return }
        preset.bands[band.index] = band
        replaceCurrentPreset(preset)
        dirtyBands.insert(band.index)
        scheduleWrite()
    }

    /// Preamp is a display offset (as in pyBlackPearl); the DAC has no separate preamp register
    /// we trust, so use the volume trim below for real headroom.
    func setPreamp(_ value: Double) {
        var preset = currentPreset
        preset.preamp = min(max(value, Pearl.preampRange.lowerBound), Pearl.preampRange.upperBound)
        replaceCurrentPreset(preset)
    }

    func resetEQ() {
        var preset = currentPreset
        preset.preamp = 0
        preset.bands = preset.bands.map { band in
            var b = band
            b.gain = 0; b.q = 1; b.type = .peak; b.enabled = true
            return b
        }
        replaceCurrentPreset(preset)
        writeAllBands()
    }

    // MARK: - Presets

    @discardableResult
    func newPreset(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !settings.presets.contains(where: { $0.name == name }) else { return false }
        var preset = Preset.flat(named: name)
        preset.bands = currentPreset.bands      // start from what's playing now
        preset.preamp = currentPreset.preamp
        settings.presets.append(preset)
        selectedPresetID = preset.id
        persist()
        show("Created preset “\(name)”.")
        return true
    }

    func selectPreset(_ id: UUID) {
        guard settings.presets.contains(where: { $0.id == id }), id != selectedPresetID else { return }
        selectedPresetID = id
        persist()
        writeAllBands()
    }

    func deleteCurrentPreset() {
        guard !isDevicePresetSelected else { return }
        let name = currentPreset.name
        settings.presets.removeAll { $0.id == selectedPresetID }
        selectedPresetID = settings.presets[devicePresetIndex].id
        persist()
        writeAllBands()
        show("Deleted preset “\(name)”.")
    }

    func importAutoEQ(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = AutoEQ.parse(text)
        guard !parsed.bands.isEmpty else { throw ImportError.noFilters }
        var preset = currentPreset
        if let preamp = parsed.preamp { preset.preamp = preamp }
        for band in parsed.bands { preset.bands[band.index] = band }
        replaceCurrentPreset(preset)
        writeAllBands()
        show("Imported \(parsed.bands.count) filters from \(url.lastPathComponent).")
    }

    func exportAutoEQ(to url: URL) throws {
        try AutoEQ.export(currentPreset).write(to: url, atomically: true, encoding: .utf8)
        show("Exported to \(url.lastPathComponent).")
    }

    enum ImportError: LocalizedError {
        case noFilters
        var errorDescription: String? { "No “Filter N:” lines were found in that file." }
    }

    // MARK: - Output & DAC settings

    func setVolumePercent(_ percent: Double) {
        let span = Double(Pearl.volumeMaxRaw - Pearl.volumeMinRaw)
        setVolumeRaw(Pearl.volumeMinRaw + Int(percent / 100 * span))
    }

    func setVolumeRaw(_ raw: Int) {
        volumeRaw = min(max(raw, Pearl.volumeMinRaw), Pearl.volumeMaxRaw)
        volumeDirty = true
        scheduleWrite()
    }

    func trimVolumeToHeadroom() {
        guard isClipping else { return }
        setVolumeRaw(safeMaxVolumeRaw)
    }

    func setBalance(_ level: Int) {
        balance = min(max(level, Pearl.balanceRange.lowerBound), Pearl.balanceRange.upperBound)
        settings.balance = balance
        persist()
        let packets = Packet.writeBalance(level: balance)
        Task {
            transport.send(packets[0])
            try? await Task.sleep(for: .milliseconds(10))   // let the two DAC channels settle
            transport.send(packets[1])
            scheduleFlash()
        }
    }

    func setMicGain(_ db: Int) {
        micGain = min(max(db, Pearl.micGainRange.lowerBound), Pearl.micGainRange.upperBound)
        transport.send(Packet.writeMicGain(micGain))
        scheduleFlash()
    }

    func setDigitalFilter(_ filter: DigitalFilter) {
        digitalFilter = filter
        transport.send(Packet.writeSetting(Pearl.Cmd.digitalFilter, value: filter.rawValue))
        scheduleFlash()
    }

    func setGainMode(_ mode: GainMode) {
        gainMode = mode
        transport.send(Packet.writeSetting(Pearl.Cmd.gainMode, value: mode.rawValue))
        scheduleFlash()
    }

    func setAmpMode(_ mode: AmpMode) {
        ampMode = mode
        transport.send(Packet.writeSetting(Pearl.Cmd.ampMode, value: mode.rawValue))
        scheduleFlash()
    }

    func factoryReset() {
        setBalance(0)
        setDigitalFilter(.fastPC)
        setGainMode(.low)
        setAmpMode(.classH)
        setMicGain(0)
        resetEQ()
        show("Factory defaults restored.")
    }

    // MARK: - Write pipeline

    private func writeAllBands() {
        dirtyBands = Set(0..<Pearl.bandCount)
        scheduleWrite()
    }

    private func scheduleWrite() {
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            self?.flushWrites()
        }
    }

    private func flushWrites() {
        writeTask = nil
        guard isConnected, !isSyncing else {
            dirtyBands.removeAll()
            volumeDirty = false
            return
        }
        let preset = currentPreset
        for index in dirtyBands.sorted() {
            transport.send(Packet.writeBand(index: index, band: preset.bands[index], activeSlot: activeSlot))
        }
        if volumeDirty {
            transport.send(Packet.writeVolume(raw: Int16(clamping: volumeRaw)))
        }
        dirtyBands.removeAll()
        volumeDirty = false
        transport.send(Packet.latch())
        scheduleFlash()
    }

    private func scheduleFlash() {
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.isConnected else { return }
            self.transport.send(Packet.flash())
            self.flashTask = nil
        }
    }

    // MARK: - Persistence & notices

    private var devicePresetIndex: Int {
        settings.presets.firstIndex { $0.name == Settings.devicePresetName } ?? 0
    }

    private func replaceCurrentPreset(_ preset: Preset) {
        guard let index = settings.presets.firstIndex(where: { $0.id == selectedPresetID }) else { return }
        settings.presets[index] = preset
        persist()
    }

    private func persist() {
        settings.selectedPresetID = selectedPresetID
        settings.save()
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.notice = nil }
        }
    }
}
