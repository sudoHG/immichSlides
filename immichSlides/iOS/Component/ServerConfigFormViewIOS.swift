//
//  ServerConfigFormViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI
import Foundation

// iOS server form; the debug autofill appears only when the caller explicitly enables it.

struct ServerConfigFormViewIOS: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedInputField: ServerConfigInputField?
    @State private var isAPIKeyHelpPresented = false

    @Binding var serverURL: String
    @Binding var apiKey: String
    let isConnectionVerified: Bool
    let onTestConnection: () -> Void
    let onSave: () -> Void

    let showsDebugFillConfigButton: Bool

    let presentation: IOSServerConfigFormPresentation

    private var canSaveConfig: Bool { isConnectionVerified }
    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }
    private var usesSettingsSectionPresentation: Bool { presentation == .settingsSection }
    private var onboardingMetrics: IOSOnboardingVisualMetrics {
        IOSOnboardingVisualMetrics(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    private var inputFieldCornerRadius: CGFloat { 8 }
    private enum ServerConfigInputField: Hashable {
        case serverURL
        case apiKey
    }

    private var debugFillConfigButtonEnabled: Bool {
        PlatformCompat.debugInfoPlistString("ENABLE_DEBUG_FILL_APIKEY_BUTTON") == "1"
    }

    // UI tests can hide the debug autofill with an environment variable; real users are not affected.

    private var isDebugFillConfigButtonSuppressedByUITest: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] == "1"
    }

    private var debugServerConfigFromInfoPlist: ImmichServer? {
        ImmichServer.debugTestServerFromInfoPlist()
    }

    // Debug autofill needs caller opt-in, a DEBUG build, the plist flag and a usable test config, all at once.

    private var canShowDebugFillConfigButton: Bool {
        showsDebugFillConfigButton && PlatformCompat.isDebugBuild && debugFillConfigButtonEnabled
            && !isDebugFillConfigButtonSuppressedByUITest && debugServerConfigFromInfoPlist != nil
    }

    var body: some View {
        VStack(spacing: sectionSpacing) {
            styledInputSection
            actionSection
        }
        // First launch uses a narrow reading width; Settings fills the parent card.

        .frame(maxWidth: formMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, verticalPadding)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedInputField = nil
                }
                .accessibilityIdentifier("server.keyboard.done.button")
            }
        }
        .sheet(isPresented: $isAPIKeyHelpPresented) {
            APIKeyHelpSheetView()
        }
    }

    private var inputSectionContent: some View {
        VStack(spacing: 0) {
            inputRow(
                title: "Server URL",
                placeholder: "Enter the Immich server URL",
                text: $serverURL,
                isSecure: false,
                field: .serverURL,
                showVerifiedBadge: isConnectionVerified
            )

            Divider()
                .padding(.leading, 18)

            inputRow(
                title: "API Key",
                placeholder: "Enter API Key",
                text: $apiKey,
                isSecure: true,
                field: .apiKey,
                showVerifiedBadge: isConnectionVerified,
                showsHelpButton: true
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var styledInputSection: some View {
        inputSectionContent
            .appIOSOnboardingSurface(cornerRadius: onboardingMetrics.standardSurfaceCornerRadius)
    }

    private var formMaxWidth: CGFloat {
        usesSettingsSectionPresentation ? .infinity : (onboardingMetrics.isPad ? 760 : 680)
    }

    private var verticalPadding: CGFloat {
        usesSettingsSectionPresentation ? 0 : (isCompactHeight ? 8 : 12)
    }

    private var sectionSpacing: CGFloat {
        usesSettingsSectionPresentation ? 14 : (isCompactHeight ? 12 : 18)
    }

    // The help button only opens the explanation sheet; it never edits input or triggers a connection test or save.
    private var apiKeyHelpButton: some View {
        Button {
            isAPIKeyHelpPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: isCompactHeight ? 20 : 22, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: isCompactHeight ? 30 : 34, height: isCompactHeight ? 30 : 34)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(Text("How to Create an Immich API Key"))
        .accessibilityIdentifier("server.apiKey.help.button")
    }

    // Portrait puts the debug button on its own row; landscape puts all three buttons in one row to save height.

    private var actionSection: some View {
        Group {
            if isCompactHeight {
                HStack(spacing: 8) {
                    if canShowDebugFillConfigButton {
                        debugFillConfigButton
                    }
                    testConnectionButton
                    saveConfigButton
                }
            } else {
                VStack(spacing: 12) {
                    if canShowDebugFillConfigButton {
                        debugFillConfigButton
                    }

                    HStack(spacing: 12) {
                        testConnectionButton
                        saveConfigButton
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // Debug autofill only fills the input fields; it does not test the connection or save.

    private var debugFillConfigButton: some View {
        Button {
            fillDebugServerConfig()
        } label: {
            Label("Autofill Settings", systemImage: "doc.on.clipboard")
                .font(.system(size: isCompactHeight ? 15 : 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: onboardingMetrics.primaryButtonMinHeight)
        }
        .appButtonRole(.secondary)
        .accessibilityIdentifier("firstboot.fillConfig.button")
    }

    private var testConnectionButton: some View {
        Button {
            onTestConnection()
        } label: {
            Text("Test Connection")
                .font(.system(size: isCompactHeight ? 15 : 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: onboardingMetrics.primaryButtonMinHeight)
        }
        .appButtonRole(.secondary)
        .accessibilityIdentifier("firstboot.testConnection.button")
    }

    private var saveConfigButton: some View {
        Button {
            onSave()
        } label: {
            Text("Save Settings")
                .font(.system(size: isCompactHeight ? 15 : 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: onboardingMetrics.primaryButtonMinHeight)
                .foregroundStyle(saveButtonLabelColor)
        }
        .disabled(!canSaveConfig)
        .opacity(!canSaveConfig ? 0.72 : 1.0)
        .appButtonRole(.primary)
        .accessibilityIdentifier("firstboot.saveConfig.button")
    }

    private func fillDebugServerConfig() {
        guard let config = debugServerConfigFromInfoPlist else { return }
        serverURL = config.immichURL ?? ""
        apiKey = config.immichApiKey ?? ""
    }

    private var inputFieldClipColor: Color {

        Color.clear
    }

    private var inputFieldBrightness: Double {

        colorScheme == .dark ? 0.14 : 0.18
    }

    private var saveButtonLabelColor: Color {
        canSaveConfig ? .primary : .secondary.opacity(0.75)
    }

    @ViewBuilder
    private func inputRow(
        title: LocalizedStringResource,
        placeholder: LocalizedStringResource,
        text: Binding<String>,
        isSecure: Bool,
        field: ServerConfigInputField,
        showVerifiedBadge: Bool,
        showsHelpButton: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Titles stay LocalizedStringResource so they are collected into the String Catalog.

            HStack(alignment: .center, spacing: 8) {
                Text(String(localized: title))
                    .font(.system(size: isCompactHeight ? 14 : 17, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if showsHelpButton {
                    apiKeyHelpButton
                }
            }

            HStack(spacing: 10) {
                formInputField(placeholder: placeholder, text: text, isSecure: isSecure, field: field)

                if showVerifiedBadge {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: isCompactHeight ? 16 : 20))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, isCompactHeight ? 12 : 18)
        .padding(.vertical, isCompactHeight ? 12 : 16)
    }

    private func formInputField(
        placeholder: LocalizedStringResource,
        text: Binding<String>,
        isSecure: Bool,
        field: ServerConfigInputField
    ) -> some View {
        IOSServerConfigTextInput(
            placeholder: placeholder,
            text: text,
            isSecure: isSecure,
            field: field,
            focusedField: $focusedInputField,
            font: inputFieldFont,
            textColor: inputFieldTextColor,
            cornerRadius: inputFieldCornerRadius,
            brightness: inputFieldBrightness,
            accessibilityIdentifier: isSecure ? "firstboot.apiKey.field" : "firstboot.serverURL.field"
        )
    }

    private var inputFieldFont: Font {
        .system(size: isCompactHeight ? 16 : (isCompact ? 18 : 20))
    }

    private var inputFieldTextColor: Color {
        colorScheme == .dark ? Color.white : Color.black.opacity(0.80)
    }
}
