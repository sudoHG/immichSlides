//
//  FirstBootViewTV.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

enum TVOnboardingWizardStep: Int, CaseIterable, Hashable {
    case connectServer = 1
    case choosePlaybackMode = 2
    case refineSelection = 3

    var capsuleTitle: String {
        // The capsule title is localized here; downstream shows it as final text and no longer treats it as a key.

        return String(localized: "Setup Wizard")
    }

    var accessibilityStepValue: String {
        // The spoken step count uses LocalizedText.format, so it isn't
        // read in Chinese after the system has switched to English.

        return LocalizedText.format(
            "Step %lld of %lld",
            Int64(rawValue),
            Int64(Self.allCases.count)
        )
    }
}

// Only overlays the top-left progress capsule on the inner page; doesn't handle saving, mode selection, or filtering.

struct OnboardingWizardShellViewTV<Content: View>: View {
    let currentStep: TVOnboardingWizardStep
    let content: Content

    init(
        currentStep: TVOnboardingWizardStep,
        @ViewBuilder content: () -> Content
    ) {
        self.currentStep = currentStep
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tvOnboardingProgressOverlay(
                currentStep: currentStep,
                accessibilityIdentifier: "onboardingWizard.title"
            )
    }
}

// All three pages share the top-left capsule; change its position only here.

struct TVOnboardingProgressCapsule: View {
    @Environment(\.colorScheme) private var colorScheme

    let currentStep: TVOnboardingWizardStep
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 12) {

            Text(currentStep.capsuleTitle)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(titleColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(capsuleBackground, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(capsuleBorderColor, lineWidth: 1)
                )
                .accessibilityIdentifier(accessibilityIdentifier)
                // The screen doesn't show 1/3; the screen reader uses
                // accessibilityValue, and the short bars are hidden.

                .accessibilityValue(currentStep.accessibilityStepValue)

            HStack(spacing: 6) {
                ForEach(TVOnboardingWizardStep.allCases, id: \.self) { step in
                    progressTick(for: step)
                }
            }

            .accessibilityHidden(true)
        }
    }

    private var titleColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.82)
    }

    private var capsuleBackground: some ShapeStyle {
        if colorScheme == .dark {
            return .ultraThinMaterial
        }
        return .regularMaterial
    }

    private var capsuleBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    private var accentColor: Color {
        colorScheme == .dark
            ? Color(red: 0.41, green: 0.74, blue: 1.0)
            : Color(red: 0.12, green: 0.44, blue: 0.92)
    }

    private func progressTick(for step: TVOnboardingWizardStep) -> some View {
        let isCurrentStep = step == currentStep
        let isCompletedStep = step.rawValue < currentStep.rawValue

        return Capsule()
            .fill(progressTickColor(isCurrentStep: isCurrentStep, isCompletedStep: isCompletedStep))
            .frame(width: isCurrentStep ? 24 : 14, height: 4)
    }

    private func progressTickColor(isCurrentStep: Bool, isCompletedStep: Bool) -> Color {
        if isCurrentStep {
            return accentColor
        }
        let opacity = isCompletedStep ? 0.58 : 0.22
        return colorScheme == .dark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }
}

extension View {
    // Top-left padding is fixed at 24/40 so the capsule lands in the same place on all three pages.

    func tvOnboardingProgressOverlay(
        currentStep: TVOnboardingWizardStep,
        accessibilityIdentifier: String,
        isVisible: Bool = true
    ) -> some View {
        overlay(alignment: .topLeading) {
            if isVisible {
                TVOnboardingProgressCapsule(
                    currentStep: currentStep,
                    accessibilityIdentifier: accessibilityIdentifier
                )
                .padding(.top, 24)
                .padding(.leading, 40)
                .allowsHitTesting(false)
                .zIndex(10)
            }
        }
    }
}

// tvOS first launch is laid out with spacing and font sizes for viewing at a distance, not the iOS focus layout.

struct FirstBootViewTV: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var serverURL: String
    @Binding var apiKey: String
    let isConnectionVerified: Bool
    let isTestingConnection: Bool
    let statusMessage: String
    let onTestConnection: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backgroundGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Connect to Immich Server")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .accessibilityIdentifier("firstboot.page.title")

                    Text("Enter the server URL and API Key to connect your photo library.")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                ServerConfigFormView(
                    serverURL: $serverURL,
                    apiKey: $apiKey,
                    isConnectionVerified: isConnectionVerified,
                    onTestConnection: onTestConnection,
                    onSave: onSave
                )
                .accessibilityIdentifier("firstboot.form.card")

                // Render the status card only while testing or when there is
                // status text; when idle, no transparent placeholder is drawn.

                if shouldShowStatusSection {
                    statusSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
        }
    }

    private var shouldShowStatusSection: Bool {
        isTestingConnection || !statusMessage.isEmpty
    }

    // Keep the status card separate from the form so they can be told apart at a distance.
    private var statusSection: some View {
        Group {
            if isTestingConnection {
                SlidePlaybackLoadingView(
                    message: "Testing connection...",
                    style: .inline,
                    accessibilityIdentifier: "firstboot.connection.testing"
                )
            } else if !statusMessage.isEmpty {
                Text(LocalizedStringKey(statusMessage))
                    .accessibilityIdentifier(
                        isConnectionVerified ? "firstboot.connection.success" : "firstboot.connection.message"
                    )
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 620, minHeight: 56)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstboot.status.card")
        .animation(.easeInOut(duration: 0.2), value: isTestingConnection)
        .animation(.easeInOut(duration: 0.2), value: statusMessage)
    }

    // Low-contrast background so it doesn't compete with the focus highlight.
    private var backgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                PlatformCompat.systemBackground,
                PlatformCompat.secondarySystemBackground
            ]
        }
        return [
            Color(red: 0.97, green: 0.98, blue: 1.0),
            Color(red: 0.92, green: 0.95, blue: 0.99)
        ]
    }
}

#Preview("Onboarding Shell") {
    OnboardingWizardShellViewTV(currentStep: .choosePlaybackMode) {
        Color(red: 0.06, green: 0.08, blue: 0.10)
            .ignoresSafeArea()
    }
}
