import SwiftUI

/// Opaque reading surfaces keep long text independent of the window backdrop.
struct ReadingSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor),
                                  lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

/// Reserve glass for the controls. Older systems use a native material instead.
struct ControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.modifier(ReadingSurface(cornerRadius: 20))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
