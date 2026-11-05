import AppKit
import SwiftUI

@main
struct KotobaTranslateApp: App {
    @StateObject private var preferences: Preferences
    @StateObject private var translator: Translator

    init() {
        let settings = Preferences()
        _preferences = StateObject(wrappedValue: settings)
        _translator = StateObject(wrappedValue: Translator(preferences: settings))
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        Window("Kotoba Translate", id: "translate") {
            ContentView(preferences: preferences, translator: translator)
                .preferredColorScheme(.light)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1060, height: 720)
        .windowToolbarStyle(.unified)
        Settings { PreferencesView(preferences: preferences) }
    }
}
