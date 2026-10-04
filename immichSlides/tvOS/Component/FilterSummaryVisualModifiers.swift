import SwiftUI

/// Compatibility layer for the glass look.

struct TVGlassPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let tint: Color

    private var borderColor: Color {
        colorScheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }

    private var fallbackMaterialOpacity: Double {
        colorScheme == .light ? 0.92 : 0.70
    }

    private var fallbackTintOpacity: Double {
        colorScheme == .light ? 0.14 : 0.06
    }

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(
                            .regular.tint(tint).interactive(),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.8)
                }
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(fallbackMaterialOpacity))
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(fallbackTintOpacity))
                        }
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
        }
    }
}

/// The action button background is extracted separately to keep styling out of the main view.
struct TVActionButtonBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let isFocused: Bool
    let accent: Color
    var fillColor: Color? = nil
    var usesFillFocusEmphasis: Bool = true

    private var defaultBaseFill: Color {
        if colorScheme == .light {
            return Color(red: 0.95, green: 0.97, blue: 0.99).opacity(0.96)
        }
        return Color.black.opacity(0.34)
    }

    private var borderColor: Color {
        colorScheme == .light
            ? Color.black.opacity(isFocused ? 0.14 : 0.08) : Color.white.opacity(isFocused ? 0.18 : 0.06)
    }

    private var focusedPrimaryForegroundColor: Color {

        return .white
    }

    private var restingForegroundColor: Color {
        colorScheme == .light ? Color.black.opacity(0.82) : .white
    }

    private var secondaryFocusedBaseFill: Color {

        if usesFillFocusEmphasis == false && colorScheme == .light {
            return accent.opacity(0.92)
        }
        return fillColor ?? defaultBaseFill
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(tvOS 26.0, *) {
            if usesFillFocusEmphasis {
                content
                    .foregroundStyle(isFocused ? focusedPrimaryForegroundColor : restingForegroundColor)
                    .background {
                        shape
                            .fill(Color.clear)
                            .glassEffect(
                                .regular.tint(accent.opacity(isFocused ? 0.78 : 0.26)).interactive(),
                                in: shape
                            )
                    }
                    .overlay {
                        shape
                            .stroke(borderColor, lineWidth: isFocused ? 1.3 : 0.8)
                    }
                    .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isFocused)
            } else {
                content
                    .foregroundStyle(isFocused ? focusedPrimaryForegroundColor : restingForegroundColor)
                    .background {
                        shape
                            .fill(isFocused ? secondaryFocusedBaseFill : (fillColor ?? defaultBaseFill))
                            .overlay {
                                shape
                                    .fill(accent.opacity(isFocused ? 0.24 : 0.05))
                            }
                            .overlay {
                                shape
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(isFocused ? 0.12 : 0.03),
                                                Color.clear
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                    }
                    .overlay {
                        shape
                            .strokeBorder(
                                accent.opacity(isFocused ? 0.9 : 0.16),
                                lineWidth: isFocused ? 2.1 : 0.8
                            )
                    }
                    .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isFocused)
            }
        } else {
            content
                .foregroundStyle(isFocused ? focusedPrimaryForegroundColor : restingForegroundColor)
                .background(
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(
                                        usesFillFocusEmphasis
                                            ? (isFocused ? 0.96 : 0.38)
                                            : 0.0
                                    ),
                                    (fillColor ?? defaultBaseFill)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay {
                    shape
                        .strokeBorder(
                            usesFillFocusEmphasis
                                ? borderColor
                                : accent.opacity(isFocused ? 0.9 : 0.16),
                            lineWidth: isFocused ? (usesFillFocusEmphasis ? 1.6 : 2.1) : 0.8
                        )
                }
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isFocused)
        }
    }
}
