import SwiftUI

/// The app's three button looks: big action (right panel), small pill (inline), round icon.
/// All share hover highlight, press feedback and a dimmed disabled state.

/// Full-width action. `filled` = main action (solid color), otherwise tinted.
struct ActionButtonStyle: ButtonStyle {
    var color: Color = .accentColor
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration) { hover, enabled in
            configuration.label
                .font(.body.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .foregroundStyle(filled ? Color.white : color)
                .background(color.opacity(filled ? (hover ? 0.85 : 1) : (hover ? 0.22 : 0.13)), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(filled ? 0 : 0.3)))
                .shadow(color: filled && enabled ? color.opacity(0.35) : .clear, radius: hover ? 6 : 3, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Small capsule for inline commands (Tous, Aucune, Retards…).
struct PillButtonStyle: ButtonStyle {
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration) { hover, _ in
            configuration.label
                .font(.callout.weight(.medium))
                .padding(.vertical, 4).padding(.horizontal, 10)
                .foregroundStyle(color)
                .background(color.opacity(hover ? 0.2 : 0.1), in: Capsule())
                .contentShape(Capsule())
        }
    }
}

/// Round icon-only button (chevron, close, refresh…). Give it an accessibilityLabel.
struct IconButtonStyle: ButtonStyle {
    var color: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration) { hover, _ in
            configuration.label
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(hover ? Color.primary : color)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(hover ? 0.18 : 0), in: Circle())
                .contentShape(Circle())
        }
    }
}

/// Shared hover / press / disabled behavior (a ButtonStyle cannot hold @State itself).
private struct Styled<Content: View>: View {
    let configuration: ButtonStyleConfiguration
    @ViewBuilder let content: (_ hover: Bool, _ enabled: Bool) -> Content
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        content(hover && enabled, enabled)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hover)
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static func action(_ color: Color = .accentColor, filled: Bool = false) -> ActionButtonStyle { .init(color: color, filled: filled) }
}
extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ color: Color = .accentColor) -> PillButtonStyle { .init(color: color) }
}
extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { .init() }
}
