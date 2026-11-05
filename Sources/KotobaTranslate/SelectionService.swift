import AppKit
import Combine

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var selectionService: SelectionService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = selectionService
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        selectionService?.showWindow?()
        sender.activate(ignoringOtherApps: true)
        return false
    }
}

@MainActor
final class SelectionService: NSObject {
    private let translator: Translator
    private var activationSubscription: AnyCancellable?
    private var lastSourceBundleID: String?
    var showWindow: (() -> Void)?

    init(translator: Translator) {
        self.translator = translator
        super.init()
        rememberSource(NSWorkspace.shared.frontmostApplication)
        activationSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                self?.rememberSource(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
    }

    private func rememberSource(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        // Automation hosts do not identify the app that originally supplied their text.
        let id = app.bundleIdentifier
        lastSourceBundleID = ["com.apple.shortcuts", "com.apple.shortcuts.events", "com.apple.Automator", "com.apple.AutomatorRunner"].contains(id ?? "") ? nil : id
    }

    @objc func importSelection(_ pasteboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "選択されたテキストを読み取れませんでした。"
            return
        }
        // Capture before showing/activating our window. The service pasteboard itself
        // has no documented sender identifier; retain the last activation for launches
        // where macOS has already brought this app to the foreground.
        rememberSource(NSWorkspace.shared.frontmostApplication)
        translator.applyAppPreset(bundleID: lastSourceBundleID)
        translator.importSelection(text)
        showWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}
