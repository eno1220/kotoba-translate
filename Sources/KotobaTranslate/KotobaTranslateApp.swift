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
        MenuBarExtra("Kotoba Translate", systemImage: "network",
                     isInserted: .constant(server.running || server.starting)) {
            ServerStatusMenu(server: server)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct ServerStatusMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var server: LocalAPIServer

    var body: some View {
        Text(server.running ? "ローカルAPI：受付中" : server.starting ? "ローカルAPI：起動中" : "ローカルAPI：停止中")
        Text(server.baseURL)
        ServerRequestStatus(pool: server.inference)
        Text("完了 \(server.completed)件")
        Divider()
        Button("翻訳画面を表示") { showWindow("translate") }
        Button("ローカルAPIを表示") { showWindow("server") }
        Divider()
        Button("サーバーを停止", action: server.stop)
        Button("Kotoba Translateを終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ServerRequestStatus: View {
    @ObservedObject var pool: ServerInferencePool

    var body: some View {
        Text("実行 \(pool.activeCount)件 · 待機 \(pool.waitingCount)件")
    }
}
