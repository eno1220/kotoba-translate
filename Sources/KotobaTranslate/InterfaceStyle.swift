import AppKit
import SwiftUI

/// Shared visual language for the translation, settings, and local API windows.
/// The window itself is white; grouped content and reading surfaces are a
/// barely-there neutral gray. The system accent is reserved for controls,
/// status, and the few places that carry meaning.
enum KotobaTheme {
    /// White window backdrop, matching the grouped layout used by recent Apple apps.
    static let canvas = Color(nsColor: .textBackgroundColor)
    /// Airier neutral behind the main workspace, so the white reading card floats.
    static let mainCanvas = Color(white: 0.968)
    /// Gray fill for grouped settings and API content.
    static let grouped = Color.primary.opacity(0.045)
    /// Pure white surface for popovers and editors that need maximum contrast.
    static let surface = Color(nsColor: .textBackgroundColor)
    static let well = Color.primary.opacity(0.05)
    static let border = Color.primary.opacity(0.085)
    static let strongBorder = Color.primary.opacity(0.28)

    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.10)

    static let cardRadius: CGFloat = 14
    static let panelRadius: CGFloat = 18
    static let contentInset: CGFloat = 16
}

/// A flat, achromatic backdrop. Grouped content sits above it in soft gray.
struct ScreenBackground: View {
    var fill: Color = KotobaTheme.canvas

    var body: some View {
        fill.ignoresSafeArea().accessibilityHidden(true)
    }
}

/// Keep only the native window controls above the persistent settings sidebar.
struct MinimalWindowTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { (view as? Anchor)?.configureWindow() }
    }

    private final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.toolbar = nil
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

/// Opaque reading surfaces keep long text independent of the window backdrop.
struct ReadingSurface: ViewModifier {
    var cornerRadius: CGFloat = 12
    var fill: Color = KotobaTheme.surface

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .modifier(SurfaceBorder(cornerRadius: cornerRadius))
    }
}

/// A bordered panel used for the reading area and the options sidebar.
struct PanelSurface: ViewModifier {
    var cornerRadius: CGFloat = KotobaTheme.panelRadius

    func body(content: Content) -> some View {
        content
            .background(KotobaTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .modifier(SurfaceBorder(cornerRadius: cornerRadius))
    }
}

struct SurfaceBorder: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(contrast == .increased ? KotobaTheme.strongBorder : KotobaTheme.border,
                              lineWidth: contrast == .increased ? 1.5 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A plain SF Symbol accent. No tile or background, keeping the layout open.
struct SettingsIcon: View {
    var symbol: String
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: max(12, size * 0.46), weight: .medium))
            .foregroundStyle(KotobaTheme.accent)
            .symbolRenderingMode(.hierarchical)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SettingsNavigationLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
            Text(title).font(.system(size: 13.5, weight: .medium))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsPage<Content: View>: View {
    var title: String
    var description: String
    @ViewBuilder var content: Content

    init(title: String = "", description: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !title.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 22, weight: .bold))
                            .accessibilityAddTraits(.isHeader)
                        if !description.isEmpty {
                            Text(description)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                content
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 14))
        .controlSize(.regular)
        .textFieldStyle(SettingsTextFieldStyle())
        .toggleStyle(.switch)
        .background(Color.clear)
    }
}

/// One subtle rounded bezel around the system editor, without a nested square bezel.
struct SettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        Field(content: configuration)
    }

    private struct Field<Content: View>: View {
        var content: Content
        @FocusState private var focused: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            content
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor).opacity(enabled ? 1 : 0.5),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(contrast == .increased ? KotobaTheme.strongBorder : Color.primary.opacity(0.18))
                        .allowsHitTesting(false)
                }
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 3)
                            .padding(-3)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

/// Hover and pressed feedback for the small icon buttons in the main window.
struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    struct HoverBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isEnabled
                              ? (configuration.isPressed ? Color.primary.opacity(0.13)
                                 : hovering ? Color.primary.opacity(0.07) : Color.clear)
                              : Color.clear)
                }
                .onHover { hovering = isEnabled && $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct SelectOption<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var id: Value { value }
}

/// System pop-up control, sharing sizing across settings and translation options.
struct SelectField<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [SelectOption<Value>]
    var placeholder = ""
    var width: CGFloat?
    var large = false
    var compact = false

    private var height: CGFloat {
        if compact { return 24 }
        return large ? 30 : 26
    }

    var body: some View {
        Picker(title, selection: $selection) {
            if options.isEmpty {
                Text(placeholder).tag(selection)
            }
            ForEach(options) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(compact ? .small : large ? .large : .regular)
        .font(.system(size: compact ? 11.5 : large ? 14.5 : 13,
                      weight: large ? .medium : .regular))
        .frame(width: width, alignment: .leading)
        .frame(minHeight: height)
        .accessibilityLabel(title)
    }
}

struct SettingsCard<Content: View>: View {
    var title: String
    var symbol: String?
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(KotobaTheme.accent)
                            .symbolRenderingMode(.hierarchical)
                    }
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(KotobaTheme.contentInset)
                .background(KotobaTheme.grouped,
                            in: RoundedRectangle(cornerRadius: KotobaTheme.cardRadius, style: .continuous))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: KotobaTheme.cardRadius, style: .continuous)
                            .strokeBorder(KotobaTheme.strongBorder, lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

struct SettingsRow<Control: View>: View {
    var title: String
    var description = ""
    var hideControlLabels = true
    @ViewBuilder var control: Control

    init(_ title: String, description: String = "", hideControlLabels: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.hideControlLabels = hideControlLabels
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 16) {
                Text(title)
                    .frame(width: 150, alignment: .leading)
                HStack(spacing: 8) {
                    if hideControlLabels { control.labelsHidden() }
                    else { control }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 26)
            if !description.isEmpty {
                Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Status is always carried by text, never by color alone.
struct StatusBadge: View {
    enum Tone {
        case neutral, active, busy, warning

        var color: Color {
            switch self {
            case .neutral: Color(nsColor: .secondaryLabelColor)
            case .active: Color(red: 0.11, green: 0.55, blue: 0.30)
            case .busy: KotobaTheme.accent
            case .warning: Color(red: 0.72, green: 0.42, blue: 0.05)
            }
        }
    }

    var text: String
    var tone: Tone
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            } else {
                Circle().fill(tone.color).frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A compact metric used by the local API status area.
struct StatTile: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Monospaced value used for endpoints and identifiers.
struct CodeValue: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Grouped-content footnote used consistently across the settings windows.
struct SettingsFootnote: View {
    var text: String
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
