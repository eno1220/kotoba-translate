import AppKit
import SwiftUI

@main
struct KotobaTranslateApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @StateObject private var preferences: Preferences
    @StateObject private var translator: Translator
    @StateObject private var server: LocalAPIServer
    private static let menuBarIcon: NSImage = {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png", subdirectory: "Resources"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing menu bar icon resource")
        }
        image.size = NSSize(width: 18 * image.size.width / image.size.height, height: 18)
        image.isTemplate = true
        return image
    }()

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
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        Window("ローカルAPI — Kotoba Translate", id: "server") {
            ServerView(server: server, preferences: preferences, translator: translator)
        }
        .defaultSize(width: 1040, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        Settings { PreferencesView(preferences: preferences) }
            .windowToolbarStyle(.unifiedCompact)
        MenuBarExtra {
            ServerStatusMenu(server: server)
        } label: {
            MenuBarStatusLabel(icon: Self.menuBarIcon, server: server, pool: server.inference)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct ServerStatusMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var server: LocalAPIServer

    var body: some View {
        Group {
            Text("Kotoba Translate")
            Label(server.running ? "ローカルAPI：受付中" : server.starting ? "ローカルAPI：起動中" : "ローカルAPI：停止中",
                  systemImage: "network")
            ModelMenuStatus(pool: server.inference)
            if server.running {
                Label(server.requestActivity ? "APIリクエストを受信・処理中" : "APIリクエストの受信待ち",
                      systemImage: "arrow.down.arrow.up")
                if let receivedAt = server.lastRequestAt {
                    Text("最終API受信：\(receivedAt.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("APIリクエストはまだ受信していません")
                }
            }
            Divider()
            Button("翻訳画面を開く", systemImage: "macwindow") { showWindow("translate") }
            Button("ローカルAPI設定を開く…", systemImage: "slider.horizontal.3") { showWindow("server") }
            Button("Base URLをコピー", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.baseURL, forType: .string)
            }
            .help(server.baseURL)
            Divider()
            Toggle("サーバーモード", isOn: Binding(
                get: { server.running || server.starting },
                set: { if $0 { server.start() } else { server.stop() } }
            ))
            if let error = server.error {
                Text(error)
                Button("サーバー設定を確認…") { showWindow("server") }
            }
            Divider()
            Button("Kotoba Translateを終了", systemImage: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .preferredColorScheme(.light)
    }

    private func showWindow(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarStatusLabel: View {
    let icon: NSImage
    @ObservedObject var server: LocalAPIServer
    @ObservedObject var pool: ServerInferencePool

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: icon)
            if pool.hasLoadedModel || pool.isLoadingModel {
                Image(systemName: pool.hasLoadedModel ? "circle.fill" : "circle.lefthalf.filled")
                    .renderingMode(.original)
                    .foregroundStyle(.green)
                    .font(.system(size: 7))
            }
            if server.requestActivity {
                Image(systemName: "arrow.down.arrow.up").font(.system(size: 10))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kotoba Translate、\(pool.hasLoadedModel ? "モデル読み込み済み" : pool.isLoadingModel ? "モデル読み込み中" : "モデル未読み込み")、\(server.requestActivity ? "API通信中" : server.running ? "API受付中" : "API停止中")")
        .help("緑の点：モデル読み込み済み／半円：読み込み中、矢印：APIリクエストを受信・処理中")
    }
}

private struct ModelMenuStatus: View {
    @ObservedObject var pool: ServerInferencePool

    var body: some View {
        Label(pool.hasLoadedModel ? "モデル：読み込み済み" : pool.isLoadingModel ? "モデル：読み込み中" : "モデル：未読み込み",
              systemImage: pool.hasLoadedModel ? "checkmark.circle.fill" : pool.isLoadingModel ? "circle.lefthalf.filled" : "circle")
        if pool.hasLoadedModel && pool.isLoadingModel {
            Text("追加のモデルを読み込み中")
        }
    }
}
