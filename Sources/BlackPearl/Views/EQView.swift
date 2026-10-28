import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EQView: View {
    @EnvironmentObject private var device: DeviceController
    @State private var showingNewPreset = false
    @State private var newPresetName = ""
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            presetBar

            EQGraphView(
                bands: device.bands,
                preamp: device.currentPreset.preamp,
                headroomDB: device.isConnected ? device.headroomDB : nil,
                selected: $device.selectedBand,
                onChange: { device.updateBand($0) }
            )
            .frame(minHeight: 230)

            HStack(spacing: 16) {
                Text("Preamp")
                Slider(
                    value: Binding(get: { device.currentPreset.preamp }, set: { device.setPreamp($0) }),
                    in: Pearl.preampRange, step: 0.5
                )
                .frame(maxWidth: 260)
                Text(String(format: "%+.1f dB", device.currentPreset.preamp))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)
                Spacer()
                Text(String(format: "Peak EQ boost %+.1f dB", device.peakEQGainDB))
                    .foregroundStyle(.secondary)
                if device.isConnected {
                    Text(String(format: "Headroom %.1f dB", device.headroomDB))
                        .foregroundStyle(device.isClipping ? Color.orange : Color.secondary)
                }
            }
            .font(.callout)

            bandTable
        }
        .padding(16)
        .disabled(!device.isConnected)
        .alert("New preset", isPresented: $showingNewPreset) {
            TextField("Name", text: $newPresetName)
            Button("Create") {
                if !device.newPreset(named: newPresetName) {
                    errorMessage = "A preset with that name already exists."
                }
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Starts from the current EQ settings.")
        }
        .confirmationDialog("Delete “\(device.currentPreset.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { device.deleteCurrentPreset() }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var presetBar: some View {
        HStack(spacing: 10) {
            Picker("Preset", selection: Binding(get: { device.selectedPresetID }, set: { device.selectPreset($0) })) {
                ForEach(device.settings.presets) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 280)

            Button {
                showingNewPreset = true
            } label: {
                Label("New", systemImage: "plus")
            }
            Button {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(device.isDevicePresetSelected)
            Button {
                device.resetEQ()
            } label: {
                Label("Flatten", systemImage: "waveform.path")
            }

            Spacer()

            Button {
                importAutoEQ()
            } label: {
                Label("Import AutoEQ…", systemImage: "square.and.arrow.down")
            }
            Button {
                exportAutoEQ()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var bandTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("#").frame(width: 24)
                Text("On").frame(width: 36)
                Text("Type").frame(width: 112, alignment: .leading)
                Text("Frequency").frame(width: 104, alignment: .leading)
                Text("Gain").frame(maxWidth: .infinity, alignment: .leading)
                Text("Q").frame(width: 64, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(device.bands) { band in
                        BandRow(
                            band: band,
                            isSelected: band.index == device.selectedBand,
                            onSelect: { device.selectedBand = band.index },
                            onChange: { device.updateBand($0) }
                        )
                    }
                }
            }
        }
    }

    private func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.title = "Import AutoEQ / Equalizer APO file"
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try device.importAutoEQ(from: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportAutoEQ() {
        let panel = NSSavePanel()
        panel.title = "Export AutoEQ file"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(device.currentPreset.name) ParametricEQ.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try device.exportAutoEQ(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BandRow: View {
    let band: Band
    let isSelected: Bool
    let onSelect: () -> Void
    let onChange: (Band) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(band.index + 1)")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Toggle("", isOn: binding(\.enabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 36)

            Picker("", selection: binding(\.type)) {
                ForEach(FilterType.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 112)

            HStack(spacing: 4) {
                TextField("Hz", value: clamped(\.frequency, Pearl.frequencyRange), format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 68)
                Text("Hz").foregroundStyle(.secondary)
            }
            .frame(width: 104, alignment: .leading)

            HStack(spacing: 8) {
                Slider(value: clamped(\.gain, Pearl.gainRange), in: Pearl.gainRange, step: 0.1)
                Text(String(format: "%+.1f dB", band.gain))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)

            TextField("Q", value: clamped(\.q, Pearl.qRange), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .opacity(band.enabled ? 1 : 0.6)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Band, T>) -> Binding<T> {
        Binding(
            get: { band[keyPath: keyPath] },
            set: { value in
                var updated = band
                updated[keyPath: keyPath] = value
                onSelect()
                onChange(updated)
            }
        )
    }

    private func clamped(_ keyPath: WritableKeyPath<Band, Double>, _ range: ClosedRange<Double>) -> Binding<Double> {
        let raw = binding(keyPath)
        return Binding(
            get: { raw.wrappedValue },
            set: { raw.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}
