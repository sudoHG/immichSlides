#if os(tvOS)

import SwiftUI

private enum PlaybackHintMetrics {
    static let verticalOffsetPoints: CGFloat = -152
    static let animationCycleCount: Int = 2
    static let emphasisDurationSeconds: Double = 0.18
    static let returnDurationSeconds: Double = 0.16
    static let emphasisHoldNanoseconds: UInt64 = 180_000_000
    static let betweenCyclesDelayNanoseconds: UInt64 = 140_000_000
    static let finalSettleDelayNanoseconds: UInt64 = 90_000_000
}

struct SlideshowControlBarViewTV: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var currentIndex: Int
    @Binding var isAutoPlay: Bool

    let totalCount: Int
    let isPreviousEnabled: Bool
    // When the parent changes this number, focus returns to Settings during the entry hint and to Play/Pause otherwise.

    let focusRequestToken: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPlayPause: () -> Void
    let onSettings: () -> Void

    let shouldPreferSettingsFocusForEntryHint: Bool
    let shouldShowEntryHintBubble: Bool
    let entryHintContent: TVSlideshowEntryHintContent
    let onMoveDownWhileEntryHintVisible: (() -> Void)?

    @FocusState private var focusedButton: ControlAction?
    // The Namespace gives these buttons their own focus scope; on wake, focus defaults to playPause.

    @Namespace private var controlBarFocusScope

    /// Actions are an enum to avoid scattered strings.
    private enum ControlAction: String, Hashable {
        case settings
        case previous
        case playPause
        case next
    }

    var body: some View {
        controlBarContent
            .overlay(alignment: .topLeading) {
                // The index is removed from the UI; a 1x1 accessibility
                // probe still exposes the current index to UI tests.

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("slideshow.control.indexProbe")
                    .accessibilityLabel(Text(LocalizedStringKey("Current photo index")))
                    .accessibilityValue(accessibilityIndexValue)
            }
    }

    // The index format read by accessibility and tests is defined in this one place; the total never goes below 0.

    private var accessibilityIndexValue: String {
        guard totalCount > 0 else { return "0/0" }
        return "\(min(currentIndex + 1, totalCount))/\(max(totalCount, 0))"
    }

    /// tvOS 26+ uses Liquid Glass; earlier versions use translucent color fills.

    @ViewBuilder
    private var controlBarContent: some View {

        let buttonSpacing: CGFloat = 28
        let barHorizontalInset: CGFloat = 34
        let barVerticalInset: CGFloat = 14
        // Opacity levels: the base plate is the most transparent, inactive is medium, focused is the least transparent.

        let controlBarStrokeOpacity: CGFloat = 0.06

        Group {
            if #available(tvOS 26.0, *) {
                HStack(spacing: buttonSpacing) {
                    controlButton(for: .settings)
                    controlButton(for: .previous)
                    controlButton(for: .playPause)
                    controlButton(for: .next)
                }
                .padding(.horizontal, barHorizontalInset)
                .padding(.vertical, barVerticalInset)
                .appTVFocusScope(
                    controlBarFocusScope,
                    focused: $focusedButton,
                    default: shouldPreferSettingsFocusForEntryHint ? .settings : .playPause,
                    // Wake uses .userInitiated so the system adopts the specified default focus more readily.

                    priority: .userInitiated
                )
                .onAppear {
                    requestPreferredFocus()
                }
                .onChange(of: focusRequestToken) { _, _ in
                    // Return focus to the main button when the parent explicitly requests it.

                    requestPreferredFocus()
                }
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(

                            .clear,
                            in: Capsule(style: .continuous)
                        )
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(controlBarStrokeOpacity), lineWidth: 0.9)
                }
                .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
            } else {
                HStack(spacing: buttonSpacing) {
                    controlButton(for: .settings)
                    controlButton(for: .previous)
                    controlButton(for: .playPause)
                    controlButton(for: .next)
                }
                .padding(.horizontal, barHorizontalInset)
                .padding(.vertical, barVerticalInset)
                .appTVFocusScope(
                    controlBarFocusScope,
                    focused: $focusedButton,
                    default: shouldPreferSettingsFocusForEntryHint ? .settings : .playPause,
                    priority: .userInitiated
                )
                .onAppear {
                    requestPreferredFocus()
                }
                .onChange(of: focusRequestToken) { _, _ in
                    requestPreferredFocus()
                }
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 8)
            }
        }
        .onChange(of: shouldPreferSettingsFocusForEntryHint) { _, isTeaching in
            guard isTeaching else { return }
            requestPreferredFocus()
        }
        .onMoveCommand { direction in
            guard shouldShowEntryHintBubble, direction == .down else { return }
            onMoveDownWhileEntryHintVisible?()
        }
    }

    @ViewBuilder
    private func controlButton(for action: ControlAction) -> some View {
        // Compute the icon as a local constant to avoid repeating branches in each Button.
        let iconName: String = {
            switch action {
            case .settings:
                return "gearshape.fill"
            case .previous:

                return "arrowshape.left.fill"
            case .playPause:
                return isAutoPlay ? "pause.fill" : "play.fill"
            case .next:

                return "arrowshape.right.fill"
            }
        }()

        // The focused base is brighter so the current target is recognizable from 3 meters away.

        let isFocused = focusedButton == action
        let isEnabled = isActionEnabled(action)
        // Separate the focus bounds from the glowing capsule so the highlight doesn't overflow the whole button.

        let buttonFrameWidth: CGFloat = 126
        let buttonFrameHeight: CGFloat = 74
        let visualCapsuleInset: CGFloat = 6
        let visualCapsuleWidth = buttonFrameWidth - (visualCapsuleInset * 2)
        let visualCapsuleHeight = buttonFrameHeight - (visualCapsuleInset * 2)
        // Two glass levels, inactive and focused; light mode strengthens
        // the dark edge so white buttons don't blend into bright photos.

        let idleButtonGlassOpacity: CGFloat = colorScheme == .light ? 0.16 : 0.18
        let idleButtonStrokeOpacity: CGFloat = colorScheme == .light ? 0.11 : 0.06
        let idleButtonDarkOutlineOpacity: CGFloat = colorScheme == .light ? 0.22 : 0.10
        let focusedButtonStrokeOpacity: CGFloat = 0.18
        let idleIconShadowOpacity: CGFloat = colorScheme == .light ? 0.50 : 0.34
        let idleIconShadowRadius: CGFloat = colorScheme == .light ? 10 : 7

        let activateAction: () -> Void = {
            guard isActionEnabled(action) else { return }
            switch action {
            case .settings:
                onSettings()
            case .previous:
                onPrevious()
            case .playPause:
                onPlayPause()
            case .next:
                onNext()
            }
        }

        // Use a system Button to handle Select, with plain style to
        // drop default styling, and draw the focus state ourselves.

        Button(action: activateAction) {
            ZStack {
                if #available(tvOS 26.0, *) {
                    if isFocused {
                        Capsule(style: .continuous)
                            .fill(Color.white)
                            .frame(width: visualCapsuleWidth, height: visualCapsuleHeight)
                    } else {
                        let idleButtonStyle = Glass.regular
                            .tint(Color.white.opacity(idleButtonGlassOpacity))

                        Capsule(style: .continuous)
                            .fill(Color.clear)
                            .frame(width: visualCapsuleWidth, height: visualCapsuleHeight)
                            .glassEffect(
                                idleButtonStyle,
                                in: Capsule(style: .continuous)
                            )
                    }
                } else {
                    Capsule(style: .continuous)
                        .fill(
                            isFocused
                                ? Color.white
                                : Color.white.opacity(0.24)
                        )
                        .frame(width: visualCapsuleWidth, height: visualCapsuleHeight)
                }

                Image(systemName: iconName)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)

                    .shadow(
                        color: .black.opacity(isFocused ? 0.08 : idleIconShadowOpacity),
                        radius: isFocused ? 1.5 : idleIconShadowRadius,
                        x: 0,
                        y: isFocused ? 1 : 2
                    )
            }
            .frame(width: buttonFrameWidth, height: buttonFrameHeight)
            .overlay(
                Capsule(style: .continuous)
                    .inset(by: visualCapsuleInset)
                    .stroke(

                        Color.black.opacity(isFocused ? 0.10 : idleButtonDarkOutlineOpacity),
                        lineWidth: isFocused ? 0.8 : 1
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .inset(by: visualCapsuleInset)
                    .stroke(
                        Color.white.opacity(
                            isFocused ? focusedButtonStrokeOpacity : idleButtonStrokeOpacity
                        ),
                        lineWidth: 1
                    )
            )
            // Focus, hit testing, and the visible outline all use the inset capsule so the visual bounds match.

            .clipShape(Capsule(style: .continuous).inset(by: visualCapsuleInset))
            .contentShape(Capsule(style: .continuous).inset(by: visualCapsuleInset))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focused($focusedButton, equals: action)
        .appTVDisableDefaultFocusEffect(true)
        .hoverEffectDisabled(true)
        .opacity(isEnabled ? 1 : 0.42)
        .animation(.easeInOut(duration: PlaybackHintMetrics.emphasisDurationSeconds), value: isFocused)
        .accessibilityIdentifier("slideshow.control.\(action.rawValue).button")
        .accessibilityLabel(Text(LocalizedStringKey(accessibilityLabel(for: action))))
        .accessibilityValue(
            action == .playPause
                ? Text(LocalizedStringKey(isAutoPlay ? "pause" : "play"))
                // Non-play buttons use verbatim for the empty accessibility value, to avoid an empty localization key.

                : Text(verbatim: "")
        )
        .overlay(alignment: .topLeading) {
            if action == .settings, shouldShowEntryHintBubble {
                TVSlideshowEntryHintBubble(content: entryHintContent)
                    // The tutorial bubble sits 152pt above the Settings button.
                    .offset(x: 0, y: PlaybackHintMetrics.verticalOffsetPoints)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .bottomLeading)
                                .combined(with: .offset(x: 0, y: 10))
                                .combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private func isActionEnabled(_ action: ControlAction) -> Bool {
        switch action {
        case .previous:
            return isPreviousEnabled
        case .settings, .playPause, .next:
            return true
        }
    }

    private func accessibilityLabel(for action: ControlAction) -> String {
        switch action {
        case .settings:
            return "Settings"
        case .previous:
            return "Previous"
        case .playPause:
            return isAutoPlay ? "Pause Autoplay" : "Start Autoplay"
        case .next:
            return "Next"
        }
    }

    private func requestPreferredFocus() {
        // Set focus on the next frame, after conditional rendering; a normal wake
        // goes back to playPause, the tutorial state goes to settings first.

        DispatchQueue.main.async {
            focusedButton = shouldPreferSettingsFocusForEntryHint ? .settings : .playPause
        }
    }
}

struct TVSlideshowEntryHintContent {

    let title: String
    let actionInstruction: LocalizedKeycapInstruction

    init(title: String, actionTemplate: String, actionKeyLabel: String) {
        self.title = title
        actionInstruction = LocalizedKeycapInstruction(
            template: actionTemplate,
            keycapLabel: actionKeyLabel
        )
    }
}

private struct TVSlideshowEntryHintBubble: View {
    let content: TVSlideshowEntryHintContent

    private let bubbleCornerRadius: CGFloat = 22
    private let bubbleTailWidth: CGFloat = 28
    private let bubbleTailHeight: CGFloat = 18

    private let bubbleTailCenterX: CGFloat = 62

    @State private var hasFinishedEntranceAnimation: Bool = false

    var body: some View {

        let bubbleShape = TVSlideshowEntryHintBubbleShape(
            cornerRadius: bubbleCornerRadius,
            tailWidth: bubbleTailWidth,
            tailHeight: bubbleTailHeight,
            tailCenterX: bubbleTailCenterX
        )

        VStack(alignment: .leading, spacing: 14) {

            Text(content.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.98))
                .multilineTextAlignment(.leading)
                .lineSpacing(3)
                .lineLimit(2)
                .minimumScaleFactor(0.92)
                .accessibilityIdentifier("slideshow.entryHint.title")

            TVSlideshowEntryHintActionRow(content: content)
                .accessibilityIdentifier("slideshow.entryHint.action")
        }

        .opacity(hasFinishedEntranceAnimation ? 1 : 0)
        .offset(y: hasFinishedEntranceAnimation ? 0 : 8)
        // The bubble sizes to its content width instead of a hard-coded 520 that left empty space on the right.

        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 22)
        // Top and bottom padding are asymmetric to leave room for the tail.
        .padding(.top, 18)
        .padding(.bottom, 26)
        .background {
            bubbleShape
                .fill(.ultraThinMaterial)
        }
        .overlay {
            bubbleShape
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .fixedSize(horizontal: false, vertical: true)

        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow.entryHint.banner")
        .task {

            guard hasFinishedEntranceAnimation == false else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                hasFinishedEntranceAnimation = true
            }
        }
    }
}

private struct TVSlideshowEntryHintActionRow: View {
    let content: TVSlideshowEntryHintContent

    // Full-line spoken text for UI tests and accessibility;
    // visually it's still split into Press + keycap + description.

    private var accessibilityActionLabel: String {
        content.actionInstruction.accessibilityLabel
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(content.actionInstruction.leadingText)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82))
                .accessibilityIdentifier("slideshow.entryHint.actionPrefix")

            TVSlideshowEntryHintKeycap(label: content.actionInstruction.keycapLabel)

            Text(content.actionInstruction.trailingText)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82))
                .accessibilityIdentifier("slideshow.entryHint.actionSuffix")
        }
        // Height grows with the content so the small keycap doesn't break the line height.

        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: accessibilityActionLabel))
    }
}

private struct TVSlideshowEntryHintKeycap: View {
    let label: String
    // The Down key hint plays a light animation a limited number of times,
    // not an infinite loop, so it doesn't distract from watching focus.

    @State private var arrowVerticalOffset: CGFloat = 0
    @State private var isKeycapEmphasized: Bool = false
    @State private var hasPlayedHintAnimation: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {

            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.96))
                .offset(y: arrowVerticalOffset)

            Text(label)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    Color.white.opacity(isKeycapEmphasized ? 0.32 : 0.22),
                    lineWidth: 1
                )
        }
        .shadow(
            color: .black.opacity(isKeycapEmphasized ? 0.18 : 0.12),
            radius: isKeycapEmphasized ? 8 : 6,
            x: 0,
            y: isKeycapEmphasized ? 3 : 2
        )

        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("slideshow.entryHint.keycap")
        .task {
            await playHintAnimationIfNeeded()
        }
    }

    @MainActor
    private func playHintAnimationIfNeeded() async {
        guard hasPlayedHintAnimation == false else { return }
        hasPlayedHintAnimation = true

        for cycle in 0..<PlaybackHintMetrics.animationCycleCount {
            withAnimation(.easeInOut(duration: PlaybackHintMetrics.emphasisDurationSeconds)) {
                arrowVerticalOffset = 4
                isKeycapEmphasized = true
            }
            try? await Task.sleep(nanoseconds: PlaybackHintMetrics.emphasisHoldNanoseconds)

            withAnimation(.easeOut(duration: PlaybackHintMetrics.returnDurationSeconds)) {
                arrowVerticalOffset = 0
                isKeycapEmphasized = false
            }
            try? await Task.sleep(
                nanoseconds: cycle == 0
                    ? PlaybackHintMetrics.betweenCyclesDelayNanoseconds
                    : PlaybackHintMetrics.finalSettleDelayNanoseconds)
        }
    }
}

// Draw the body and tail as one Shape, instead of awkwardly joining a rounded rectangle and a small square.

private struct TVSlideshowEntryHintBubbleShape: Shape {
    let cornerRadius: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat
    let tailCenterX: CGFloat

    func path(in rect: CGRect) -> Path {
        let bodyMaxY = rect.maxY - tailHeight
        let clampedCornerRadius = min(cornerRadius, (bodyMaxY - rect.minY) / 2, rect.width / 2)

        // Clamp the tail center to a safe range so it doesn't clash with the left/right rounded corners.

        let minTailCenterX = rect.minX + clampedCornerRadius + tailWidth * 0.9
        let maxTailCenterX = rect.maxX - clampedCornerRadius - tailWidth * 0.9
        let resolvedTailCenterX = min(
            max(rect.minX + tailCenterX, minTailCenterX),
            maxTailCenterX
        )
        let tailLeftX = resolvedTailCenterX - tailWidth / 2
        let tailRightX = resolvedTailCenterX + tailWidth / 2
        let tailTip = CGPoint(x: resolvedTailCenterX, y: rect.maxY)

        var path = Path()

        path.move(to: CGPoint(x: rect.minX + clampedCornerRadius, y: rect.minY))

        path.addLine(to: CGPoint(x: rect.maxX - clampedCornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + clampedCornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: bodyMaxY - clampedCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - clampedCornerRadius, y: bodyMaxY),
            control: CGPoint(x: rect.maxX, y: bodyMaxY)
        )

        path.addLine(to: CGPoint(x: tailRightX, y: bodyMaxY))

        path.addQuadCurve(
            to: tailTip,
            control: CGPoint(
                x: resolvedTailCenterX + tailWidth * 0.22,
                y: bodyMaxY + tailHeight * 0.58
            )
        )
        path.addQuadCurve(
            to: CGPoint(x: tailLeftX, y: bodyMaxY),
            control: CGPoint(
                x: resolvedTailCenterX - tailWidth * 0.22,
                y: bodyMaxY + tailHeight * 0.58
            )
        )

        path.addLine(to: CGPoint(x: rect.minX + clampedCornerRadius, y: bodyMaxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyMaxY - clampedCornerRadius),
            control: CGPoint(x: rect.minX, y: bodyMaxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + clampedCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + clampedCornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

#endif
