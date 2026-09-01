import AppKit
import SwiftUI

@main
struct HearsayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("hearsay", systemImage: "waveform") {
            MenuView(coordinator: delegate.coordinator)
        }
        Window("hearsay", id: "settings") {
            SettingsWindowView(coordinator: delegate.coordinator)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = Coordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }
}
