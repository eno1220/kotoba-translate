import AppKit
import SwiftUI

/// Let the input method consume Return while marked text is present.
/// Handling this in NSTextView keeps Japanese/Chinese/Korean composition intact.
struct InputEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    var font: NSFont = .systemFont(ofSize: 16)
    var textColor: NSColor = .textColor
    var submit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = Editor()
        editor.isRichText = false
        editor.isEditable = editable
        editor.isSelectable = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = font
        editor.textColor = textColor
        editor.textContainerInset = NSSize(width: 16, height: 18)
        editor.drawsBackground = false
        scroll.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.submit = submit
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        editor.submit = submit
        if editor.string != text && !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if editor.font != font { editor.font = font }
        if editor.textColor != textColor { editor.textColor = textColor }
        editor.typingAttributes[.font] = font
        editor.typingAttributes[.foregroundColor] = textColor
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputEditor
        init(_ parent: InputEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
    final class Editor: NSTextView {
        var submit: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if isEditable && (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
                if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
                else { submit?() }
                return
            }
            super.keyDown(with: event)
        }
    }
}
