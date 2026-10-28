import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var device: DeviceController

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            Divider()
            TabView {
                EQView()
                    .tabItem { Label("Equalizer", systemImage: "slider.horizontal.3") }
                DeviceView()
                    .tabItem { Label("Device", systemImage: "hifispeaker") }
            }
            .padding(.top, 6)
        }
        .frame(minWidth: 860, minHeight: 620)
        .overlay(alignment: .bottom) {
            if let notice = device.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: device.notice)
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var device: DeviceController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(device.isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                if device.isConnected {
                    Text("\(device.productName)")
                        .fontWeight(.semibold)
                    Text("S/N \(device.serialNumber)")
                        .foregroundStyle(.secondary)
                    Text("Firmware \(device.firmware)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No Black Pearl connected")
                        .fontWeight(.semibold)
                    Text("Plug headphones into the DAC first — it stays asleep on USB until it sees a load.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if device.isSyncing {
                    ProgressView().controlSize(.small)
                    Text("Reading…").foregroundStyle(.secondary)
                }
                Button {
                    Task { await device.sync() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!device.isConnected || device.isSyncing)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let error = device.accessError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.18))
            }
        }
    }
}
