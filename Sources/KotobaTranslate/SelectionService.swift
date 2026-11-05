import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var selectionService: SelectionService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = selectionService
    }
}

@MainActor
final class SelectionService: NSObject {
    private let translator: Translator
    var showWindow: (() -> Void)?

    init(translator: Translator) {
        self.translator = translator
    }

    @objc func importSelection(_ pasteboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "選択されたテキストを読み取れませんでした。"
            return
        }
        translator.importSelection(text)
        showWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}
