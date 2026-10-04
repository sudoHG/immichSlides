//
//  FirstBootViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

// iOS first launch keeps its scrolling and orientation behavior and does not use the tvOS focus layout.

struct FirstBootViewIOS: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Binding var serverURL: String
    @Binding var apiKey: String
    let isConnectionVerified: Bool
    let isTestingConnection: Bool
    let testingStatusMessage: String
    let statusMessage: String
    let onTestConnection: () -> Void
    let onSave: () -> Void

    private var onboardingMetrics: IOSOnboardingVisualMetrics {
        IOSOnboardingVisualMetrics(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    var body: some View {
        IOSOnboardingPageScaffold(metrics: onboardingMetrics) { _ in
            contentStack
        }
    }

    private var localNetworkPermissionHint: String? {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        guard ImmichServer.isLikelyLocalNetworkServerURL(serverURL) else {
            return nil
        }

        return String(
            localized:
                "If this is a home or office Immich server, your iPhone may ask for Local Network access the first time you connect. Tap Allow."
        )
    }

    // The step 1 content column is narrower than pageMaxWidth and centered, so iPad landscape does not lean left.

    private var contentColumnMaxWidth: CGFloat {
        if onboardingMetrics.isPad {
            return 760
        }

        return onboardingMetrics.pageMaxWidth
    }

    // Single-column information hierarchy, kept on small screens and after rotation.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: onboardingMetrics.pageSectionSpacing) {
            IOSOnboardingPageHeader(
                step: .connectServer,
                title: "Connect to Immich Server",
                subtitle: "Enter the server URL and API Key to connect your photo library.",
                titleAccessibilityIdentifier: "firstboot.page.title",
                metrics: onboardingMetrics
            )

            ServerConfigFormView(
                serverURL: $serverURL,
                apiKey: $apiKey,
                isConnectionVerified: isConnectionVerified,
                onTestConnection: onTestConnection,
                onSave: onSave,
                showsDebugFillConfigButton: true
            )

            if let localNetworkPermissionHint {
                Text(LocalizedStringKey(localNetworkPermissionHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("firstboot.localNetwork.hint")
            }

            statusSection
        }
        .frame(maxWidth: contentColumnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // The status area stays out of the main form layout so text changes do not make the form jump.
    private var statusSection: some View {
        Group {
            if isTestingConnection {
                SlidePlaybackLoadingView(
                    message: testingStatusMessage,
                    style: .inline,
                    accessibilityIdentifier: "firstboot.connection.testing"
                )
            } else if !statusMessage.isEmpty {
                Text(LocalizedStringKey(statusMessage))
                    .accessibilityIdentifier(
                        isConnectionVerified ? "firstboot.connection.success" : "firstboot.connection.message"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .accessibilityIdentifier("firstboot.status.card")
        .animation(.easeInOut(duration: 0.2), value: isTestingConnection)
        .animation(.easeInOut(duration: 0.2), value: statusMessage)
    }
}
