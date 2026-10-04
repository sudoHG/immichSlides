import SwiftUI

/// Compatibility layer for the glass look.

private enum ActionButtonMetrics {
    static let cornerRadiusPoints: CGFloat = 22
    static let focusedGlassBorderWidthPoints: CGFloat = 1.3
    static let normalBorderWidthPoints: CGFloat = 0.8
    static let focusedOutlineWidthPoints: CGFloat = 2.1
    static let focusedLegacyBorderWidthPoints: CGFloat = 1.6
    static let focusSpringResponseSeconds: Double = 0.24
    static let focusSpringDampingFraction: Double = 0.82
}

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
    var shouldUseFillFocusEmphasis: Bool = true

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

        if shouldUseFillFocusEmphasis == false && colorScheme == .light {
            return accent.opacity(0.92)
        }
        return fillColor ?? defaultBaseFill
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ActionButtonMetrics.cornerRadiusPoints, style: .continuous)
        if #available(tvOS 26.0, *) {
            if shouldUseFillFocusEmphasis {
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
                            .stroke(
                                borderColor,
                                lineWidth: isFocused
                                    ? ActionButtonMetrics.focusedGlassBorderWidthPoints
                                    : ActionButtonMetrics.normalBorderWidthPoints)
                    }
                    .animation(
                        .spring(
                            response: ActionButtonMetrics.focusSpringResponseSeconds,
                            dampingFraction: ActionButtonMetrics.focusSpringDampingFraction), value: isFocused)
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
                                lineWidth: isFocused
                                    ? ActionButtonMetrics.focusedOutlineWidthPoints
                                    : ActionButtonMetrics.normalBorderWidthPoints
                            )
                    }
                    .animation(
                        .spring(
                            response: ActionButtonMetrics.focusSpringResponseSeconds,
                            dampingFraction: ActionButtonMetrics.focusSpringDampingFraction), value: isFocused)
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
                                        shouldUseFillFocusEmphasis
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
                            shouldUseFillFocusEmphasis
                                ? borderColor
                                : accent.opacity(isFocused ? 0.9 : 0.16),
                            lineWidth: isFocused
                                ? (shouldUseFillFocusEmphasis
                                    ? ActionButtonMetrics.focusedLegacyBorderWidthPoints
                                    : ActionButtonMetrics.focusedOutlineWidthPoints)
                                : ActionButtonMetrics.normalBorderWidthPoints
                        )
                }
                .animation(
                    .spring(
                        response: ActionButtonMetrics.focusSpringResponseSeconds,
                        dampingFraction: ActionButtonMetrics.focusSpringDampingFraction), value: isFocused)
        }
    }
}
