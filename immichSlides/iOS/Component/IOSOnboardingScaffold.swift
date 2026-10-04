import SwiftUI

enum IOSOnboardingWizardStep: Int, CaseIterable, Hashable {
    case connectServer = 1
    case choosePlaybackMode = 2
    case refineSelection = 3

    var capsuleTitle: String {
        String(localized: "Setup Wizard")
    }

    var accessibilityStepValue: String {
        LocalizedText.format(
            "Step %lld of %lld",
            Int64(rawValue),
            Int64(Self.allCases.count)
        )
    }
}

// Font sizes, widths, button heights and corner radii shared by the three first-launch pages.

struct IOSOnboardingVisualMetrics {
    let horizontalSizeClass: UserInterfaceSizeClass?
    let verticalSizeClass: UserInterfaceSizeClass?
    let userInterfaceIdiom: UIUserInterfaceIdiom

    var isPad: Bool {
        userInterfaceIdiom == .pad
    }

    var isCompactWidth: Bool {
        horizontalSizeClass == .compact
    }

    var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    var pageMaxWidth: CGFloat {
        if isPad { return 900 }
        if isCompactHeight { return 560 }
        return 700
    }

    var pageOuterHorizontalPadding: CGFloat {
        if isCompactHeight { return 12 }
        if isCompactWidth { return 16 }
        return 24
    }

    var pageSectionSpacing: CGFloat {
        if isCompactHeight { return 14 }
        return isPad ? 24 : 18
    }

    var headerSpacing: CGFloat {
        isCompactHeight ? 10 : 14
    }

    var titleSubtitleSpacing: CGFloat {
        isCompactHeight ? 6 : 8
    }

    var headerTitleSize: CGFloat {
        if isCompactHeight { return 28 }
        if isPad { return 38 }
        return isCompactWidth ? 32 : 36
    }

    var headerSubtitleSize: CGFloat {
        if isCompactHeight { return 14 }
        return isPad ? 17 : 16
    }

    var primaryButtonMinHeight: CGFloat {
        isCompactHeight ? 44 : 50
    }

    var primaryButtonMaxWidth: CGFloat {
        if isPad { return 240 }
        if isCompactWidth { return 220 }
        return 228
    }

    var standardSurfaceCornerRadius: CGFloat {
        isCompactWidth ? 24 : 28
    }
}

// Light background shared by the three pages, so it does not pull attention from titles and forms.

struct IOSOnboardingBackgroundLayer: View {
    @Environment(\.colorScheme) private var colorScheme

    let metrics: IOSOnboardingVisualMetrics

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backgroundGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(leadingGlowColor)
                .frame(
                    width: metrics.isPad ? 520 : (metrics.isCompactWidth ? 240 : 320),
                    height: metrics.isPad ? 520 : (metrics.isCompactWidth ? 240 : 320)
                )
                .blur(radius: metrics.isPad ? 120 : (metrics.isCompactWidth ? 70 : 88))
                .offset(
                    x: metrics.isPad ? -260 : (metrics.isCompactWidth ? -120 : -170),
                    y: metrics.isPad ? -300 : (metrics.isCompactWidth ? -190 : -220)
                )

            Circle()
                .fill(trailingGlowColor)
                .frame(
                    width: metrics.isPad ? 460 : (metrics.isCompactWidth ? 230 : 300),
                    height: metrics.isPad ? 460 : (metrics.isCompactWidth ? 230 : 300)
                )
                .blur(radius: metrics.isPad ? 120 : (metrics.isCompactWidth ? 74 : 92))
                .offset(
                    x: metrics.isPad ? 300 : (metrics.isCompactWidth ? 150 : 190),
                    y: metrics.isPad ? 260 : (metrics.isCompactWidth ? 250 : 220)
                )

            Rectangle()
                .fill(veilColor)
                .ignoresSafeArea()
        }
    }

    private var backgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                PlatformCompat.systemGroupedBackground,
                PlatformCompat.secondarySystemGroupedBackground
            ]
        }

        return [
            Color(red: 0.96, green: 0.97, blue: 0.99),
            Color(red: 0.92, green: 0.95, blue: 0.98)
        ]
    }

    private var leadingGlowColor: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.10) : Color.cyan.opacity(0.08)
    }

    private var trailingGlowColor: Color {
        colorScheme == .dark ? Color.mint.opacity(0.09) : Color.blue.opacity(0.07)
    }

    private var veilColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.08) : Color.white.opacity(0.10)
    }
}

// Wizard progress is deliberately light so the page title stays the main visual focus.

struct IOSOnboardingProgressHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let currentStep: IOSOnboardingWizardStep
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 10) {
            Text(currentStep.capsuleTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(titleColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(progressCapsuleFill, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(progressCapsuleBorderColor, lineWidth: 1)
                )
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityValue(currentStep.accessibilityStepValue)

            HStack(spacing: 6) {
                ForEach(IOSOnboardingWizardStep.allCases, id: \.self) { step in
                    progressTick(for: step)
                }
            }
            .accessibilityHidden(true)

            Spacer(minLength: 0)
        }
    }

    private var titleColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.86) : Color.black.opacity(0.74)
    }

    private var progressCapsuleFill: some ShapeStyle {
        colorScheme == .dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial)
    }

    private var progressCapsuleBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var accentColor: Color {
        colorScheme == .dark
            ? Color(red: 0.41, green: 0.74, blue: 1.0)
            : Color(red: 0.12, green: 0.44, blue: 0.92)
    }

    private func progressTick(for step: IOSOnboardingWizardStep) -> some View {
        let isCurrentStep = step == currentStep
        let isCompletedStep = step.rawValue < currentStep.rawValue

        return Capsule()
            .fill(progressTickColor(isCurrentStep: isCurrentStep, isCompletedStep: isCompletedStep))
            .frame(width: isCurrentStep ? 22 : 14, height: 4)
    }

    private func progressTickColor(isCurrentStep: Bool, isCompletedStep: Bool) -> Color {
        if isCurrentStep {
            return accentColor
        }

        let opacity = isCompletedStep ? 0.46 : 0.18
        return colorScheme == .dark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }
}

struct IOSOnboardingPageHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let step: IOSOnboardingWizardStep?
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let titleAccessibilityIdentifier: String
    let metrics: IOSOnboardingVisualMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            if let step {
                IOSOnboardingProgressHeader(
                    currentStep: step,
                    accessibilityIdentifier: "onboardingWizard.title"
                )
            }

            VStack(alignment: .leading, spacing: metrics.titleSubtitleSpacing) {
                Text(title)
                    .font(.system(size: metrics.headerTitleSize, weight: .bold))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(metrics.isCompactHeight ? 2 : 1)
                    .minimumScaleFactor(0.84)
                    .accessibilityIdentifier(titleAccessibilityIdentifier)

                Text(subtitle)
                    .font(.system(size: metrics.headerSubtitleSize, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(metrics.isCompactHeight ? 3 : 2)
                    .minimumScaleFactor(0.88)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.94)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.66) : Color(red: 0.34, green: 0.41, blue: 0.49)
    }
}

// Shell shared by the three pages: same background, max width, padding and top start,
// so the title does not shift with content height.

struct IOSOnboardingPageScaffold<Content: View>: View {
    let metrics: IOSOnboardingVisualMetrics
    let topPaddingAdjustment: CGFloat
    private let content: (CGSize) -> Content

    init(
        metrics: IOSOnboardingVisualMetrics,
        topPaddingAdjustment: CGFloat = 0,
        @ViewBuilder content: @escaping (CGSize) -> Content
    ) {
        self.metrics = metrics
        self.topPaddingAdjustment = topPaddingAdjustment
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                IOSOnboardingBackgroundLayer(metrics: metrics)

                ScrollView(showsIndicators: false) {
                    content(geometry.size)
                        .frame(
                            width: contentWidth(for: geometry.size.width),
                            alignment: .leading
                        )
                        .padding(.top, adjustedContentTopPadding(for: geometry.size.height))
                        .padding(.bottom, contentBottomPadding)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private func contentWidth(for screenWidth: CGFloat) -> CGFloat {
        let availableWidth = screenWidth - metrics.pageOuterHorizontalPadding * 2
        return max(1, min(metrics.pageMaxWidth, availableWidth))
    }

    // Top padding depends only on device form factor and screen height, not on this page's content height.

    private func contentTopPadding(for screenHeight: CGFloat) -> CGFloat {
        if metrics.isCompactHeight {
            return 14
        }

        if metrics.isPad {
            return max(112, min(160, screenHeight * 0.14))
        }

        if metrics.isCompactWidth {
            return max(72, min(104, screenHeight * 0.11))
        }

        return max(80, min(128, screenHeight * 0.12))
    }

    // Pages with a system navigation bar can pass an adjustment so the content does not look pushed down.

    private func adjustedContentTopPadding(for screenHeight: CGFloat) -> CGFloat {
        max(0, contentTopPadding(for: screenHeight) + topPaddingAdjustment)
    }

    private var contentBottomPadding: CGFloat {
        if metrics.isCompactHeight {
            return 14
        }

        return metrics.isPad ? 44 : 30
    }
}

// Form, mode and filter cards share the same corner radius, border, highlight and shadow.

private struct IOSOnboardingSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let accent: Color?

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(surfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(surfaceBorderColor, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(surfaceHighlightColor, lineWidth: 1)
                    .padding(1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: surfaceShadowColor, radius: 16, x: 0, y: 10)
    }

    private var surfaceFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.20, blue: 0.23),
                        surfaceBottomColorDark
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.98),
                    surfaceBottomColorLight
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var surfaceBottomColorDark: Color {
        if let accent {
            return accent.opacity(0.08)
        }
        return Color(red: 0.13, green: 0.15, blue: 0.18)
    }

    private var surfaceBottomColorLight: Color {
        if let accent {
            return accent.opacity(0.12)
        }
        return Color(red: 0.94, green: 0.97, blue: 0.995)
    }

    private var surfaceBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var surfaceHighlightColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.72)
    }

    private var surfaceShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.26) : Color.black.opacity(0.10)
    }
}

extension View {
    // Callers only declare "draw this as the shared wizard surface".

    func appIOSOnboardingSurface(
        cornerRadius: CGFloat = 28,
        accent: Color? = nil
    ) -> some View {
        modifier(
            IOSOnboardingSurfaceModifier(
                cornerRadius: cornerRadius,
                accent: accent
            )
        )
    }
}
