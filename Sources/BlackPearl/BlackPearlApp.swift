import AppKit
import SwiftUI

@main
struct BlackPearlApp: App {
    @StateObject private var device = DeviceController()

    init() {
        // Running straight from `swift run` has no bundle; make sure we still get a Dock icon and focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Black Pearl") {
            ContentView()
                .environmentObject(device)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 920, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
