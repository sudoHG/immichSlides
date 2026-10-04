//
//  ServerConfigFormView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/3/10.
//

import SwiftUI
import Foundation

// The iOS form appears in the first-boot wizard or a settings section, so the two cannot share one look.
enum IOSServerConfigFormPresentation {
    case onboarding
    case settingsSection
}

// The tvOS form appears on the first-boot screen or a settings subpage, with different width and card context.
enum TVOSServerConfigFormPresentation {
    case onboarding
    case settingsPage
}

// Shared server config form entry; input, focus and styling are handled by the platform implementations.
struct ServerConfigFormView: View {
    @Binding var serverURL: String
    @Binding var apiKey: String
    let isConnectionVerified: Bool
    let onTestConnection: () -> Void
    let onSave: () -> Void
    // iOS only; defaults to false so the debug fill button never shows in Settings.
    let showsDebugFillConfigButton: Bool
    // tvOS: first boot keeps a 620 reading width; Settings passes nil+0 to follow the parent container.
    let tvPreferredMaxWidth: CGFloat?
    let tvHorizontalPadding: CGFloat?
    let tvPresentation: TVOSServerConfigFormPresentation
    // iOS only; defaults to .onboarding so existing call sites are not silently broken.
    let iosPresentation: IOSServerConfigFormPresentation

    init(
        serverURL: Binding<String>,
        apiKey: Binding<String>,
        isConnectionVerified: Bool,
        onTestConnection: @escaping () -> Void,
        onSave: @escaping () -> Void,
        showsDebugFillConfigButton: Bool = false,
        iosPresentation: IOSServerConfigFormPresentation = .onboarding,
        tvPresentation: TVOSServerConfigFormPresentation = .onboarding,
        tvPreferredMaxWidth: CGFloat? = 620,
        tvHorizontalPadding: CGFloat? = nil
    ) {
        self._serverURL = serverURL
        self._apiKey = apiKey
        self.isConnectionVerified = isConnectionVerified
        self.onTestConnection = onTestConnection
        self.onSave = onSave
        self.showsDebugFillConfigButton = showsDebugFillConfigButton
        self.tvPreferredMaxWidth = tvPreferredMaxWidth
        self.tvHorizontalPadding = tvHorizontalPadding
        self.tvPresentation = tvPresentation
        self.iosPresentation = iosPresentation
    }

    var body: some View {
        #if os(tvOS)
        ServerConfigFormViewTV(
            serverURL: $serverURL,
            apiKey: $apiKey,
            isConnectionVerified: isConnectionVerified,
            onTestConnection: onTestConnection,
            onSave: onSave,
            presentation: tvPresentation,
            preferredMaxWidth: tvPreferredMaxWidth,
            horizontalPadding: tvHorizontalPadding
        )
        #else
        ServerConfigFormViewIOS(
            serverURL: $serverURL,
            apiKey: $apiKey,
            isConnectionVerified: isConnectionVerified,
            onTestConnection: onTestConnection,
            onSave: onSave,
            showsDebugFillConfigButton: showsDebugFillConfigButton,
            presentation: iosPresentation
        )
        #endif
    }
}

// The API Key help is a display-only sheet; it does not read or write config state or touch a ViewModel.
struct APIKeyHelpSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            #if !os(tvOS)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.secondary.opacity(0.35))
                .frame(width: 54, height: 6)
                .padding(.top, APIKeyHelpSheetMetrics.dragHandleTopPadding)
                .padding(.bottom, APIKeyHelpSheetMetrics.dragHandleBottomPadding)
                .accessibilityHidden(true)
            #endif

            VStack(alignment: .leading, spacing: APIKeyHelpSheetMetrics.headerSpacing) {
                HStack {
                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Text("Close")
                            .font(APIKeyHelpSheetMetrics.closeButtonFont)
                            .frame(
                                minWidth: APIKeyHelpSheetMetrics.closeButtonMinWidth,
                                minHeight: APIKeyHelpSheetMetrics.closeButtonMinHeight
                            )
                    }
                    .accessibilityLabel(Text("Close"))
                    .accessibilityIdentifier("server.apiKey.help.close.button")
                }
                .padding(.trailing, APIKeyHelpSheetMetrics.closeButtonTrailingSafePadding)

                Text("How to Create an Immich API Key")
                    .font(APIKeyHelpSheetMetrics.titleFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.apiKey.help.sheet")
            }
            .padding(.top, APIKeyHelpSheetMetrics.headerTopPadding)
            .padding(.horizontal, APIKeyHelpSheetMetrics.horizontalPadding)
            .padding(.bottom, APIKeyHelpSheetMetrics.headerBottomPadding)

            ScrollView {
                VStack(alignment: .leading, spacing: APIKeyHelpSheetMetrics.sectionSpacing) {
                    Text("Create an API Key in the Immich web app, then return here and paste it.")
                        .font(APIKeyHelpSheetMetrics.bodyFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    APIKeyHelpSection(systemImage: "list.number", title: "Steps to Create an API Key") {
                        APIKeyHelpNumberedRow(
                            number: "1.", text: "Open the Immich web app in a browser on your computer or phone.")
                        APIKeyHelpNumberedRow(
                            number: "2.",
                            text: "Select your profile picture in the top-right corner, then open Account Settings.")
                        APIKeyHelpNumberedRow(
                            number: "3.", text: "Open “API Keys,” create a new key, and name it immichSlides.")
                        APIKeyHelpNumberedRow(
                            number: "4.",
                            text: "Copy the full API Key after creating it, then return here and paste it.")
                    }

                    APIKeyHelpSection(systemImage: "checklist", title: "Required Permissions") {
                        APIKeyHelpBulletRow("Play photos (required): asset.read, asset.view, asset.download")
                        APIKeyHelpBulletRow(
                            "Filter photos (optional): album.read, album.statistics, person.read, person.statistics")
                    }

                    APIKeyHelpSection(systemImage: "key.fill", title: "Security Reminder") {
                        APIKeyHelpBulletRow(
                            "The API Key is stored in Apple Keychain. Never send it to support by email.")
                        APIKeyHelpBulletRow(
                            "If the connection test reports missing permissions, enable them in Immich and try again.")
                    }
                }
                .padding(.horizontal, APIKeyHelpSheetMetrics.horizontalPadding)
                .padding(.top, APIKeyHelpSheetMetrics.contentTopPadding)
                .padding(.bottom, APIKeyHelpSheetMetrics.contentBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private enum APIKeyHelpSheetMetrics {
    #if os(tvOS)
    static let headerTopPadding: CGFloat = 20
    static let headerSpacing: CGFloat = 4
    static let headerBottomPadding: CGFloat = 6
    static let closeButtonTrailingSafePadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let sectionContentSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    static let contentTopPadding: CGFloat = 6
    static let contentBottomPadding: CGFloat = 22
    static let numberMinWidth: CGFloat = 28
    static let closeButtonMinWidth: CGFloat = 56
    static let closeButtonMinHeight: CGFloat = 34
    static let closeButtonFont: Font = .system(size: 18, weight: .semibold)
    static let titleFont: Font = .system(size: 28, weight: .bold)
    static let bodyFont: Font = .system(size: 18)
    static let sectionTitleFont: Font = .system(size: 19, weight: .semibold)
    static let sectionIconFont: Font = .system(size: 18, weight: .semibold)
    static let rowFont: Font = .system(size: 17)
    static let rowMarkerFont: Font = .system(size: 17, weight: .semibold)
    #else
    static let dragHandleTopPadding: CGFloat = 10
    static let dragHandleBottomPadding: CGFloat = 4
    static let headerTopPadding: CGFloat = 0
    static let headerSpacing: CGFloat = 4
    static let headerBottomPadding: CGFloat = 6
    static let closeButtonTrailingSafePadding: CGFloat = 0
    static let horizontalPadding: CGFloat = 22
    static let sectionSpacing: CGFloat = 16
    static let sectionContentSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    static let contentTopPadding: CGFloat = 6
    static let contentBottomPadding: CGFloat = 22
    static let numberMinWidth: CGFloat = 26
    static let closeButtonMinWidth: CGFloat = 50
    static let closeButtonMinHeight: CGFloat = 32
    static let closeButtonFont: Font = .callout.weight(.semibold)
    static let titleFont: Font = .title3.weight(.bold)
    static let bodyFont: Font = .callout
    static let sectionTitleFont: Font = .headline.weight(.semibold)
    static let sectionIconFont: Font = .callout.weight(.semibold)
    static let rowFont: Font = .callout
    static let rowMarkerFont: Font = .callout.weight(.semibold)
    #endif
}

private struct APIKeyHelpSection<Content: View>: View {
    let systemImage: String
    let title: LocalizedStringResource
    let content: Content

    init(systemImage: String, title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.systemImage = systemImage
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: APIKeyHelpSheetMetrics.sectionContentSpacing) {
            Label {
                Text(String(localized: title))
                    .font(APIKeyHelpSheetMetrics.sectionTitleFont)
                    .accessibilityIdentifier("server.apiKey.help.section.\(systemImage).title")
            } icon: {
                Image(systemName: systemImage)
                    .font(APIKeyHelpSheetMetrics.sectionIconFont)
            }
            .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: APIKeyHelpSheetMetrics.rowSpacing) {
                content
            }
            .padding(.leading, 6)
        }
    }
}

private struct APIKeyHelpNumberedRow: View {
    let number: String
    let text: LocalizedStringResource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: APIKeyHelpSheetMetrics.rowSpacing) {
            Text(number)
                .font(APIKeyHelpSheetMetrics.rowMarkerFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: APIKeyHelpSheetMetrics.numberMinWidth, alignment: .trailing)

            Text(String(localized: text))
                .font(APIKeyHelpSheetMetrics.rowFont)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct APIKeyHelpBulletRow: View {
    let text: LocalizedStringResource

    init(_ text: LocalizedStringResource) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: APIKeyHelpSheetMetrics.rowSpacing) {
            Text(verbatim: "•")
                .font(APIKeyHelpSheetMetrics.rowMarkerFont)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(String(localized: text))
                .font(APIKeyHelpSheetMetrics.rowFont)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ServerConfigFormPreviewWrapper()
}

private struct ServerConfigFormPreviewWrapper: View {
    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var isConnectionVerified = false

    var body: some View {
        ZStack {
            PlatformCompat.systemGroupedBackground
                .ignoresSafeArea()

            ServerConfigFormView(
                serverURL: $serverURL,
                apiKey: $apiKey,
                isConnectionVerified: isConnectionVerified,
                onTestConnection: { isConnectionVerified.toggle() },
                onSave: {}
            )
        }
    }
}
