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
        .defaultSize(width: 1060, height: 720)
        .windowToolbarStyle(.unified)
        Window("ローカルAPI — Kotoba Translate", id: "server") {
            ServerView(server: server, preferences: preferences, translator: translator)
        }
        .defaultSize(width: 800, height: 780)
        Settings { PreferencesView(preferences: preferences) }
        MenuBarExtra(isInserted: .constant(server.running || server.starting)) {
            ServerStatusMenu(server: server)
        } label: {
            Image(nsImage: Self.menuBarIcon)
                .accessibilityLabel("Kotoba Translate")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct ServerStatusMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var server: LocalAPIServer

    var body: some View {
        VStack(spacing: 6) {
            Menu {
                Menu("接続情報") {
                    Text(server.baseURL)
                    Button("Base URLをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(server.baseURL, forType: .string)
                    }
                }
                Menu("処理状況") {
                    ServerRequestStatus(pool: server.inference)
                    Text("完了 \(server.completed)件")
                }
                Divider()
                Button("ローカルAPI設定を開く…") { showWindow("server") }
                Button(server.starting ? "起動を中止" : "サーバーを停止") {
                    dismiss()
                    server.stop()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kotoba Translate")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(server.running ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(server.running ? "API 受付中" : server.starting ? "API 起動中" : "API 停止中")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(server.running ? Color.green : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(server.running ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(MenuBarRowStyle())
            .accessibilityLabel("Kotoba Translate、\(server.running ? "API受付中" : server.starting ? "API起動中" : "API停止中")、詳細メニュー")

            Divider().padding(.horizontal, 10)
            Button { showWindow("translate") } label: {
                Label("翻訳画面を開く", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .buttonStyle(MenuBarRowStyle())
            Divider().padding(.horizontal, 10)
            Button { NSApp.terminate(nil) } label: {
                HStack {
                    Text("Kotoba Translateを終了")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .buttonStyle(MenuBarRowStyle())
            .keyboardShortcut("q")
        }
        .padding(6)
        .frame(width: 320)
        .preferredColorScheme(.light)
    }

    private func showWindow(_ id: String) {
        dismiss()
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

private struct ServerRequestStatus: View {
    @ObservedObject var pool: ServerInferencePool

    var body: some View {
        Text("実行 \(pool.activeCount)件 · 待機 \(pool.waitingCount)件")
    }
}
