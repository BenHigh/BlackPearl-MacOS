import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var device: DeviceController
    @State private var confirmFactoryReset = false

    var body: some View {
        Form {
            Section("Hardware") {
                LabeledContent("Product", value: device.isConnected ? "TRN Black Pearl (\(device.productName))" : "—")
                LabeledContent("Serial number", value: device.serialNumber)
                LabeledContent("Firmware", value: device.firmware)
            }

            Section("Output") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Volume") {
                        Text(String(format: "%.0f%%  ·  %+.1f dB", device.volumePercent, device.volumeDB))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { device.volumePercent }, set: { device.setVolumePercent($0) }),
                        in: 0...100, step: 1
                    )
                    if device.isClipping {
                        HStack {
                            Label(String(format: "EQ boost exceeds digital headroom by %.1f dB", device.peakEQGainDB - device.headroomDB),
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Trim volume") { device.trimVolumeToHeadroom() }
                        }
                        .font(.callout)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Balance") {
                        Text(balanceLabel).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { Double(device.balance) }, set: { device.setBalance(Int($0.rounded())) }),
                        in: -15...15, step: 1
                    ) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("L")
                    } maximumValueLabel: {
                        Text("R")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Microphone gain") {
                        Text(String(format: "%+d dB", device.micGain)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { Double(device.micGain) }, set: { device.setMicGain(Int($0.rounded())) }),
                        in: -15...15, step: 1
                    )
                }
            }

            Section("DAC") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Digital filter", selection: Binding(get: { device.digitalFilter }, set: { device.setDigitalFilter($0) })) {
                        ForEach(DigitalFilter.allCases) { Text($0.name).tag($0) }
                    }
                    Text(device.digitalFilter.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Picker("Gain", selection: Binding(get: { device.gainMode }, set: { device.setGainMode($0) })) {
                    ForEach(GainMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Amplifier", selection: Binding(get: { device.ampMode }, set: { device.setAmpMode($0) })) {
                    ForEach(AmpMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button("Restore factory defaults…", role: .destructive) { confirmFactoryReset = true }
                    .confirmationDialog("Restore factory defaults?", isPresented: $confirmFactoryReset) {
                        Button("Restore", role: .destructive) { device.factoryReset() }
                    } message: {
                        Text("Resets EQ, volume trim, balance, microphone gain, filter, gain and amplifier mode on the DAC. Saved presets are kept.")
                    }
            }
        }
        .formStyle(.grouped)
        .disabled(!device.isConnected)
    }

    private var balanceLabel: String {
        switch device.balance {
        case ..<0: return "L \(-device.balance)"
        case 0: return "Center"
        default: return "R \(device.balance)"
        }
    }
}
