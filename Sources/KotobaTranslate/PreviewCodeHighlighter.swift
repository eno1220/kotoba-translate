import AppKit
import Highlighter
import MarkdownUI
import SwiftUI

/// Used by both previews. Keep the JavaScript engine and a bounded, memory-only cache alive.
final class PreviewCodeHighlighter: CodeSyntaxHighlighter {
    static let shared = PreviewCodeHighlighter()

    private let highlighter: Highlighter?
    private let cache = NSCache<NSString, NSAttributedString>()

    private init() {
        highlighter = Highlighter()
        highlighter?.setTheme("github")
        highlighter?.ignoreIllegals = true
        cache.totalCostLimit = 2 * 1024 * 1024
        cache.countLimit = 128
    }

    func highlightCode(_ code: String, language: String?) -> Text {
        guard let language = language?.split(whereSeparator: { $0.isWhitespace }).first,
              !language.isEmpty else { return Text(code) }

        let name = language.lowercased()
        let key = (name + "\u{0}" + code) as NSString
        let highlighted: NSAttributedString
        if let cached = cache.object(forKey: key) {
            highlighted = cached
        } else if let result = highlighter?.highlight(code, as: name) {
            highlighted = result
            cache.setObject(result, forKey: key, cost: result.length * 2)
        } else {
            return Text(code)
        }

        // Apply colors only, so MarkdownUI still controls the code font and size.
        var text = Text("")
        highlighted.enumerateAttribute(.foregroundColor,
                                       in: NSRange(location: 0, length: highlighted.length)) { color, range, _ in
            let fragment = Text((highlighted.string as NSString).substring(with: range))
            if let color = color as? NSColor {
                text = text + fragment.foregroundColor(Color(nsColor: color))
            } else {
                text = text + fragment
            }
        }
        return text
    }
}
