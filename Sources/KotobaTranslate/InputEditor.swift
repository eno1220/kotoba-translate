import AppKit
import SwiftUI

/// Let the input method consume Return while marked text is present.
/// Handling this in NSTextView keeps Japanese/Chinese/Korean composition intact.
struct InputEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    var font: NSFont = .systemFont(ofSize: 16)
    var textColor: NSColor = .textColor
    var focusRequest: UUID?
    var placeholder = ""
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
        editor.placeholder = placeholder
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        editor.submit = submit
        editor.placeholder = placeholder
        if let focusRequest, editor.focusRequest != focusRequest {
            // An explicit import replaces even an unfinished composition in this editor.
            editor.unmarkText()
        }
        editor.focusRequest = focusRequest
        if editor.string != text && !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            let replacement = text as NSString
            let oldLength = (editor.string as NSString).length
            // Streaming output normally appends. Preserve the existing text storage
            // and its layout instead of replacing the entire translation each time.
            if !editable, replacement.length >= oldLength,
               replacement.compare(editor.string, options: .literal,
                                   range: NSRange(location: 0, length: oldLength)) == .orderedSame,
               let storage = editor.textStorage {
                storage.replaceCharacters(in: NSRange(location: oldLength, length: 0),
                                          with: replacement.substring(from: oldLength))
            } else {
                editor.string = text
            }
            editor.setSelectedRange(NSRange(location: min(selection.location, replacement.length), length: 0))
            editor.needsDisplay = true
        }
        if editor.font != font { editor.font = font }
        if editor.textColor != textColor { editor.textColor = textColor }
        if editor.typingAttributes[.font] as? NSFont != font {
            editor.typingAttributes[.font] = font
        }
        if editor.typingAttributes[.foregroundColor] as? NSColor != textColor {
            editor.typingAttributes[.foregroundColor] = textColor
        }
        if focusRequest != nil {
            DispatchQueue.main.async { [weak editor] in editor?.focusIfRequested() }
        }
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
        var placeholder = "" {
            didSet { if placeholder != oldValue { needsDisplay = true } }
        }
        var focusRequest: UUID?
        private var appliedFocusRequest: UUID?

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
            let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                                 y: textContainerOrigin.y)
            (placeholder as NSString).draw(at: origin, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.placeholderTextColor
            ])
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            needsDisplay = true
        }

        override func unmarkText() {
            super.unmarkText()
            needsDisplay = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Wait until SwiftUI has finished choosing the window's initial responder.
            DispatchQueue.main.async { [weak self] in self?.focusIfRequested() }
        }

        func focusIfRequested() {
            guard isEditable, let focusRequest, focusRequest != appliedFocusRequest,
                  let window, window.makeFirstResponder(self) else { return }
            appliedFocusRequest = focusRequest
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
            scrollRangeToVisible(selectedRange())
        }

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
