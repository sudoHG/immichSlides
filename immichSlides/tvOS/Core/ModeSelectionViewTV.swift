//
//  ModeSelectionViewTV.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

// Child buttons report the system's actual focus, so the page doesn't guess the highlight from @FocusState.

private struct ModeSelectionFocusedTargetKey: FocusedValueKey {
    typealias Value = String
}

private extension FocusedValues {
    var modeSelectionFocusedTarget: String? {
        get { self[ModeSelectionFocusedTargetKey.self] }
        set { self[ModeSelectionFocusedTargetKey.self] = newValue }
    }
}

// The tvOS mode page manages its own focus chain and big-screen layout; it isn't shared with iOS.

struct ModeSelectionViewTV: View {
    private enum FocusTarget: String, Hashable {
        case randomCard
        case filteredCard
        case continueButton
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selectedMode: SlideMode?
    let previewFocusedModeOverride: SlideMode?
    let showsOnboardingProgress: Bool
    let onSelectMode: (SlideMode) -> Void
    let onContinue: () -> Void

    // focusedTarget is only used to request focus from the system; it doesn't decide the on-screen highlight.

    @FocusState private var focusedTarget: FocusTarget?
    // The target just requested, a fallback for momentary focus loss during transitions.

    @State private var requestedFocusTarget: FocusTarget?
    // The focus most recently confirmed by the system, used as a second-level fallback.

    @State private var lastStableFocusTarget: FocusTarget?
    // The system's actual focus comes from the buttons' .focusedValue reports.

    @FocusedValue(\.modeSelectionFocusedTarget) private var systemFocusedTargetRawValue: String?
    @Namespace private var modeFocusScope
    private let currentOnboardingStep: TVOnboardingWizardStep = .choosePlaybackMode

    private var layout: ViewLayoutTraits {
        ViewLayoutTraits(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    private var requestedFocusedTarget: FocusTarget? {
        requestedFocusTarget
    }

    // systemFocusedTarget is the target confirmed by the focus engine, not a guess from the outer layer.

    private var systemFocusedTarget: FocusTarget? {
        guard let systemFocusedTargetRawValue else { return nil }
        return FocusTarget(rawValue: systemFocusedTargetRawValue)
    }

    // The highlight follows the system's actual focus; only during
    // brief focus loss does it fall back to the target just requested.

    private var visualFocusedTarget: FocusTarget? {
        systemFocusedTarget ?? requestedFocusedTarget
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundLayer

                VStack {
                    Spacer(minLength: 0)
                    VStack(spacing: 36) {
                        headerView
                        cardsContainer(height: cardsContainerHeight(for: geometry.size.height))
                        continueButton
                    }
                    .frame(width: contentWidth(for: geometry.size.width))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tvOnboardingProgressOverlay(
            currentStep: currentOnboardingStep,
            accessibilityIdentifier: "mode.onboarding.title",
            isVisible: showsOnboardingProgress
        )
        .appTVFocusScope(modeFocusScope, focused: $focusedTarget, default: .randomCard)
        .onAppear {
            initializeFocusIfNeeded()
        }
        .onChange(of: systemFocusedTargetRawValue) { _, newRawValue in
            let newValue = newRawValue.flatMap(FocusTarget.init(rawValue:))

            if let newValue {
                lastStableFocusTarget = newValue
                requestedFocusTarget = nil

                // Sync focusedTarget to the system's actual focus so later moves share the same context.

                if focusedTarget != newValue {
                    focusedTarget = newValue
                }
            } else {
                repairFocusIfNeeded()
            }
        }
    }

    private func cardsContainer(height: CGFloat) -> some View {
        // The subtitle covers albums/faces and no longer implies location.

        let filteredModeDescription = "Filter the photos to show by album and person."

        return HStack(spacing: 30) {
            modeButton(
                mode: .random, icon: "photo.stack", title: "Shuffle All Photos",
                description: "Play all photos in the library in random order and start right away.",
                cardHeight: height)
            modeButton(
                mode: .filtered, icon: "photo.badge.plus.fill", title: "Filter slideshow photos",
                description: filteredModeDescription,
                cardHeight: height)
        }
        .frame(height: height)
    }

    private func modeButton(
        mode: SlideMode,
        icon: String,
        title: String,
        description: String,
        cardHeight: CGFloat
    ) -> some View {
        Button {
            onSelectMode(mode)
        } label: {
            ModeCardView(
                icon: icon,
                title: title,
                description: description,
                isSelected: selectedMode == mode,
                isFocused: visualFocusedTarget == focusTarget(for: mode)
            )
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight, alignment: .center)
            .animation(.spring(response: 0.3), value: selectedMode)
            .animation(.easeInOut(duration: 0.18), value: visualFocusedTarget)
        }
        .buttonStyle(ModeSelectionCardButtonStyle())
        .focused($focusedTarget, equals: focusTarget(for: mode))
        // No longer wrapped in appTVButtonInteraction, to avoid
        // stacking focusable on the Button and getting double focus.

        .focusedValue(\.modeSelectionFocusedTarget, focusTarget(for: mode).rawValue)
        .appTVDisableDefaultFocusEffect()
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(mode == .random ? "mode.random.button" : "mode.filtered.button")
        .appTVOnMoveCommand { direction in
            handleMoveCommand(direction, from: mode)
        }
    }

    // The Continue button is the next focus target below the cards.
    private var continueButton: some View {
        Button {
            onContinue()
        } label: {
            Text("Continue")
                .font(.system(size: 30, weight: .bold))
                .padding(.vertical, 18)
                .padding(.horizontal, 44)
        }
        .appButtonRole(.primary)
        .disabled(selectedMode == nil)
        .focused($focusedTarget, equals: .continueButton)
        .focusedValue(\.modeSelectionFocusedTarget, FocusTarget.continueButton.rawValue)
        .appTVDisabledEmphasis(selectedMode != nil)
        .accessibilityIdentifier("mode.continue.button")
        .appTVOnMoveCommand { direction in
            if direction == .up {
                moveFocus(to: focusTarget(for: selectedMode ?? previewFocusedModeOverride ?? .random))
            }
        }
    }

    // The title only describes this page's task; progress is shown by the shared capsule in the top-left corner.

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose Playback Mode")
                    .font(.system(size: 46, weight: .heavy))
                    .padding(.vertical, 5)
                    .accessibilityIdentifier("mode.page.title")
                Text("Choose whether to shuffle all photos or pick albums and people first.")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contentWidth(for screenWidth: CGFloat) -> CGFloat {
        min(1260, screenWidth - 120)
    }

    // Keep the card height within a stable range to control the focus scale ratio.
    private func cardsContainerHeight(for screenHeight: CGFloat) -> CGFloat {
        max(380, min(screenHeight * 0.48, 430))
    }

    // Selected and currently focused use two separate states that aren't mixed.
    private func focusTarget(for mode: SlideMode) -> FocusTarget {
        mode == .random ? .randomCard : .filteredCard
    }

    // When no mode is selected, Down doesn't go to Continue, to avoid requesting an unavailable target.

    private var preferredContinueFocusTarget: FocusTarget? {
        selectedMode == nil ? nil : .continueButton
    }

    private var defaultCardFocusTarget: FocusTarget {
        focusTarget(for: previewFocusedModeOverride ?? .random)
    }

    // Arrow key rules live here, without changing the button body.
    private func handleMoveCommand(_ direction: AppMoveDirection, from mode: SlideMode) {
        switch direction {
        case .left:
            if mode == .filtered { moveFocus(to: .randomCard) }
        case .right:
            if mode == .random { moveFocus(to: .filteredCard) }
        case .down:
            if let preferredContinueFocusTarget {
                moveFocus(to: preferredContinueFocusTarget)
            }
        default:
            break
        }
    }

    // When the system's actual focus isn't established yet, explicitly request the default card.

    private func initializeFocusIfNeeded() {
        guard systemFocusedTarget == nil else { return }
        moveFocus(to: defaultCardFocusTarget)
    }

    // On focus loss, first restore the target just requested, then the last stable focus, otherwise the default card.

    private func repairFocusIfNeeded() {
        let fallbackTarget: FocusTarget

        if let requestedFocusTarget, isFocusTargetAvailable(requestedFocusTarget) {
            fallbackTarget = requestedFocusTarget
        } else if let lastStableFocusTarget, isFocusTargetAvailable(lastStableFocusTarget) {
            fallbackTarget = lastStableFocusTarget
        } else {
            fallbackTarget = defaultCardFocusTarget
        }

        DispatchQueue.main.async {
            if systemFocusedTarget == nil {
                moveFocus(to: fallbackTarget)
            }
        }
    }

    // Direction rules only say where to go; the request state is maintained here.

    private func moveFocus(to target: FocusTarget) {
        requestedFocusTarget = target
        focusedTarget = target
    }

    // The Continue button is an available focus target only when
    // a mode is selected; both mode cards are always available.

    private func isFocusTargetAvailable(_ target: FocusTarget) -> Bool {
        switch target {
        case .randomCard, .filteredCard:
            return true
        case .continueButton:
            return selectedMode != nil
        }
    }

    // The background isn't coupled to the cards, so visual changes don't affect focus.
    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: backgroundGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(accentGlowLeading)
                .frame(width: 460, height: 460)
                .blur(radius: 90)
                .offset(x: -360, y: -180)

            Circle()
                .fill(accentGlowTrailing)
                .frame(width: 420, height: 420)
                .blur(radius: 100)
                .offset(x: 360, y: 120)

            Rectangle()
                .fill(.regularMaterial.opacity(colorScheme == .dark ? 0.18 : 0.32))
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black.opacity(0.25), location: 0.25),
                            .init(color: .black, location: 0.7),
                            .init(color: .black, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
        }
    }

    private var backgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.11, green: 0.12, blue: 0.14),
                Color(red: 0.07, green: 0.08, blue: 0.10)
            ]
        }
        return [
            Color(red: 0.96, green: 0.97, blue: 0.99),
            Color(red: 0.91, green: 0.94, blue: 0.98)
        ]
    }

    private var accentGlowLeading: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.14) : Color.cyan.opacity(0.10)
    }

    private var accentGlowTrailing: Color {
        colorScheme == .dark ? Color.mint.opacity(0.10) : Color.blue.opacity(0.08)
    }

}

private struct ModeSelectionCardButtonStyle: ButtonStyle {
    // Subtle press feedback, keeping the system's default button style out.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
