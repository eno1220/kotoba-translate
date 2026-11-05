import AppKit
import SwiftUI

@main
struct KotobaTranslateApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @StateObject private var preferences: Preferences
    @StateObject private var translator: Translator
    @StateObject private var server: LocalAPIServer

    init() {
        let settings = Preferences()
        let engine = Translator(preferences: settings)
        _preferences = StateObject(wrappedValue: settings)
        _translator = StateObject(wrappedValue: engine)
        _server = StateObject(wrappedValue: LocalAPIServer(preferences: settings, translator: engine))
        appDelegate.selectionService = SelectionService(translator: engine)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        Window("Kotoba Translate", id: "translate") {
            ContentView(preferences: preferences, translator: translator, selectionService: appDelegate.selectionService)
                .preferredColorScheme(.light)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1060, height: 720)
        .windowToolbarStyle(.unified)
        Window("ローカルAPI — Kotoba Translate", id: "server") {
            ServerView(server: server, preferences: preferences, translator: translator)
        }
        .defaultSize(width: 800, height: 780)
        Settings { PreferencesView(preferences: preferences) }
    }
}
