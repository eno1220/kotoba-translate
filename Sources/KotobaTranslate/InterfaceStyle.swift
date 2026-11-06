import SwiftUI

/// Settings scenes don't consistently apply the scene's toolbar style.
struct CompactWindowToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.toolbarStyle = .unifiedCompact }
    }

    private final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.toolbarStyle = .unifiedCompact
        }
    }
}

/// Opaque reading surfaces keep long text independent of the window backdrop.
struct ReadingSurface: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .modifier(SurfaceBorder(cornerRadius: cornerRadius))
    }
}

struct SurfaceBorder: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(contrast == .increased ? Color.primary.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.65),
                              lineWidth: contrast == .increased ? 1.5 : 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct SettingsIcon: View {
    var symbol: String
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct SettingsNavigationLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, size: 26)
            Text(title).font(.system(size: 14, weight: .medium))
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
        .font(.system(size: 14))
        .controlSize(.regular)
        .textFieldStyle(.roundedBorder)
        .toggleStyle(.switch)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct SettingsCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.primary.opacity(contrast == .increased ? 0.065 : 0.028),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.5))
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

struct SettingsRow<Control: View>: View {
    var title: String
    var description = ""
    @ViewBuilder var control: Control

    init(_ title: String, description: String = "", @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 16) {
                Text(title)
                    .frame(width: 150, alignment: .leading)
                HStack(spacing: 8) { control.labelsHidden() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 30)
            if !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DetailHeading: View {
    var title: String
    var description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(description).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 0)
    }
}
