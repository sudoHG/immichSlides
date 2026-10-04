//
//  ServerConfigFormViewTV.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI
import Foundation
#if os(tvOS)
import UIKit

enum TVOSServerConfigFormMetrics {
    static let inputCapsuleHeight: CGFloat = 46
    static let inputFontSize: CGFloat = 32
    static let placeholderFontSize: CGFloat = 17
}
#endif

private enum ServerFormLayout {
    static let compactHorizontalPaddingPoints: CGFloat = 12
    static let regularHorizontalPaddingPoints: CGFloat = 20
    static let compactVerticalPaddingPoints: CGFloat = 8
    static let regularVerticalPaddingPoints: CGFloat = 12
    static let settingsSectionSpacingPoints: CGFloat = 16
    static let compactSectionSpacingPoints: CGFloat = 12
    static let regularSectionSpacingPoints: CGFloat = 18
    static let compactActionSpacingPoints: CGFloat = 8
    static let regularActionVerticalSpacingPoints: CGFloat = 10
    static let regularActionHorizontalSpacingPoints: CGFloat = 12
    static let compactActionFontSizePoints: CGFloat = 15
    static let regularActionFontSizePoints: CGFloat = 17
    static let compactActionHeightPoints: CGFloat = 40
    static let regularActionHeightPoints: CGFloat = 44
    static let compactDebugActionFontSizePoints: CGFloat = 14
    static let regularDebugActionFontSizePoints: CGFloat = 16
    static let compactDebugActionHeightPoints: CGFloat = 38
    static let regularDebugActionHeightPoints: CGFloat = 42
    static let dividerLeadingPaddingPoints: CGFloat = 18
    static let focusAnimationDurationSeconds: Double = 0.2
    static let inputRowSpacingPoints: CGFloat = 11
    static let inputContentSpacingPoints: CGFloat = 10
    static let compactInputTitleSizePoints: CGFloat = 14
    static let regularInputTitleSizePoints: CGFloat = 17
    static let compactVerificationIconSizePoints: CGFloat = 16
    static let regularVerificationIconSizePoints: CGFloat = 20
    static let inputTopPaddingPoints: CGFloat = 2
    static let compactInputHorizontalPaddingPoints: CGFloat = 12
    static let regularInputHorizontalPaddingPoints: CGFloat = 18
    static let compactInputVerticalPaddingPoints: CGFloat = 12
    static let regularInputVerticalPaddingPoints: CGFloat = 16
    static let textFieldHorizontalPaddingPoints: CGFloat = 12
}

struct ServerConfigFormViewTV: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    @Binding var serverURL: String
    @Binding var apiKey: String
    let isConnectionVerified: Bool
    let onTestConnection: () -> Void
    let onSave: () -> Void
    let presentation: TVOSServerConfigFormPresentation
    let preferredMaxWidth: CGFloat?
    let horizontalPadding: CGFloat?

    private enum FormField: Hashable {
        case serverURL
        case apiKey
        case apiKeyHelpButton
        case fillAPIKeyButton
        case testConnectionButton
        case saveConfigButton
    }

    @FocusState private var focusedField: FormField?
    @State private var lastStableFocusedField: FormField?
    @State private var isAPIKeyHelpPresented = false
    @Namespace private var formFocusScope

    private var canSaveConfig: Bool { isConnectionVerified }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }
    private var isSettingsPagePresentation: Bool { presentation == .settingsPage }
    private var resolvedMaxWidth: CGFloat { preferredMaxWidth ?? .infinity }
    private var resolvedHorizontalPadding: CGFloat {
        horizontalPadding
            ?? (isCompactHeight
                ? ServerFormLayout.compactHorizontalPaddingPoints : ServerFormLayout.regularHorizontalPaddingPoints)
    }

    private var focusedRowBorderColor: Color { Color.cyan.opacity(0.9) }
    private var focusedRowBorderWidth: CGFloat { 2 }
    private var inputRowCornerRadius: CGFloat { 12 }
    private var buttonCornerRadius: CGFloat { 10 }

    private var debugServerURLFromConfig: String? {
        guard let rawURL = PlatformCompat.debugInfoPlistString("IMMICH_SERVER_URL") else {
            return nil
        }
        let normalizedURL = ImmichServer.normalizeServerURL(rawURL)
        return normalizedURL.isEmpty ? nil : normalizedURL
    }

    private var debugAPIKeyFromConfig: String? {
        PlatformCompat.debugInfoPlistString("IMMICH_API_KEY")
    }

    private var debugServerConfigFromInfoPlist: (url: String, apiKey: String)? {
        guard
            let serverURL = debugServerURLFromConfig,
            let apiKey = debugAPIKeyFromConfig
        else {
            return nil
        }
        return (serverURL, apiKey)
    }

    private var isDebugFillAPIKeyButtonEnabled: Bool {
        PlatformCompat.debugInfoPlistString("ENABLE_DEBUG_FILL_APIKEY_BUTTON") == "1"
    }

    // Tests can hide the debug fill button via an environment variable, so acceptance checks see the normal user flow.

    private var isDebugFillAPIKeyButtonSuppressedByUITest: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] == "1"
    }

    private var canShowFillAPIKeyButton: Bool {
        PlatformCompat.isDebugBuild && isDebugFillAPIKeyButtonEnabled && !isDebugFillAPIKeyButtonSuppressedByUITest
            && debugServerConfigFromInfoPlist != nil
    }

    var body: some View {
        formContent
            .overlay {
                TVOSServerConfigFocusGuideBridge(
                    upwardSourceIdentifiers: actionButtonIdentifiers,
                    upwardDestinationIdentifier: "firstboot.apiKey.field",
                    downwardSourceIdentifier: "firstboot.apiKey.field",
                    downwardPreferredDestinationIdentifier: "firstboot.testConnection.button",
                    downwardDestinationIdentifiers: actionButtonIdentifiers
                )
                .allowsHitTesting(false)
            }
            .sheet(isPresented: $isAPIKeyHelpPresented) {
                APIKeyHelpSheetView()
            }
            .appTVFocusScope(formFocusScope, focused: $focusedField, default: .serverURL)
            .frame(maxWidth: resolvedMaxWidth)
            .padding(.horizontal, resolvedHorizontalPadding)
            .padding(
                .vertical,
                isSettingsPagePresentation
                    ? 0
                    : (isCompactHeight
                        ? ServerFormLayout.compactVerticalPaddingPoints : ServerFormLayout.regularVerticalPaddingPoints)
            )
            .animation(.easeInOut(duration: ServerFormLayout.focusAnimationDurationSeconds), value: focusedField)
            .onAppear {
                DispatchQueue.main.async {
                    focusedField = .serverURL
                }
            }
            .onChange(of: focusedField) { _, newValue in
                if let newValue {
                    lastStableFocusedField = newValue
                } else {
                    repairFocusIfNeeded()
                }
            }
            .onChange(of: isAPIKeyHelpPresented) { _, isPresented in
                guard isPresented == false else { return }
                DispatchQueue.main.async {
                    focusedField = .apiKeyHelpButton
                }
            }
            .onChange(of: canSaveConfig) { _, canSaveConfig in
                guard canSaveConfig else { return }
                DispatchQueue.main.async {
                    focusedField = .saveConfigButton
                }
            }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: formSectionSpacing) {
            styledInputSection
            actionSection
        }
    }

    private var formSectionSpacing: CGFloat {
        isSettingsPagePresentation
            ? ServerFormLayout.settingsSectionSpacingPoints
            : (isCompactHeight
                ? ServerFormLayout.compactSectionSpacingPoints : ServerFormLayout.regularSectionSpacingPoints)
    }

    private var actionButtonIdentifiers: [String] {
        var identifiers: [String] = []
        identifiers.append("server.apiKey.help.button")
        identifiers.append("firstboot.testConnection.button")
        if canSaveConfig {
            identifiers.append("firstboot.saveConfig.button")
        }
        return identifiers
    }

    private func repairFocusIfNeeded() {
        let fallbackField: FormField?
        switch lastStableFocusedField {
        case .fillAPIKeyButton:
            fallbackField = canShowFillAPIKeyButton ? .fillAPIKeyButton : .testConnectionButton
        case .testConnectionButton:
            fallbackField = .testConnectionButton
        case .saveConfigButton:
            fallbackField = canSaveConfig ? .saveConfigButton : .testConnectionButton
        case .apiKeyHelpButton:
            fallbackField = .apiKeyHelpButton
        case .apiKey:
            fallbackField = .apiKey
        case .serverURL:
            fallbackField = .serverURL
        case nil:
            fallbackField = nil
        }

        guard let fallbackField else { return }
        DispatchQueue.main.async {
            if focusedField == nil {
                focusedField = fallbackField
            }
        }
    }

    private var inputSectionContent: some View {
        VStack(spacing: 0) {
            inputRow(
                title: "Server URL",
                placeholder: "Enter the Immich server URL",
                text: $serverURL,
                field: .serverURL,
                showVerifiedBadge: isConnectionVerified
            )

            Divider()
                .padding(.leading, ServerFormLayout.dividerLeadingPaddingPoints)

            inputRow(
                title: "API Key",
                placeholder: "Enter API Key",
                text: $apiKey,
                field: .apiKey,
                showVerifiedBadge: isConnectionVerified
            )
        }
        .frame(maxWidth: .infinity)
    }

    // The shell changes with the page context, so the Settings page
    // doesn't still look like the standalone first-launch card.

    private var styledInputSection: some View {
        inputSectionContent
            .background(
                RoundedRectangle(cornerRadius: inputSectionCornerRadius, style: .continuous)
                    .fill(cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: inputSectionCornerRadius, style: .continuous)
                    .stroke(cardBorderColor, lineWidth: 1)
            )
            .shadow(color: cardShadowColor, radius: 12, x: 0, y: 6)
    }

    private var actionSection: some View {
        VStack(
            spacing: isCompactHeight
                ? ServerFormLayout.compactActionSpacingPoints : ServerFormLayout.regularActionVerticalSpacingPoints
        ) {
            HStack(
                spacing: isCompactHeight
                    ? ServerFormLayout.compactActionSpacingPoints
                    : ServerFormLayout.regularActionHorizontalSpacingPoints
            ) {
                apiKeyHelpActionButton
                testConnectionButton
                saveConfigButton
            }
            .frame(maxWidth: .infinity)
            .appTVFocusSection()

            if canShowFillAPIKeyButton {
                fillAPIKeyButton
            }
        }
        .frame(maxWidth: .infinity)
    }

    // Put the help entry in the action row, so the API Key row doesn't handle both editing and help focus.
    private var apiKeyHelpActionButton: some View {
        Button {
            isAPIKeyHelpPresented = true
        } label: {
            Text("Need Help?")
                .accessibilityIdentifier("server.apiKey.help.button")
                .font(
                    .system(
                        size: isCompactHeight
                            ? ServerFormLayout.compactActionFontSizePoints
                            : ServerFormLayout.regularActionFontSizePoints, weight: .semibold)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(
                    maxWidth: .infinity,
                    minHeight: isCompactHeight
                        ? ServerFormLayout.compactActionHeightPoints : ServerFormLayout.regularActionHeightPoints
                )
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("server.apiKey.help.button")
        }
        .buttonStyle(TVFocusButtonStyle())
        .focused($focusedField, equals: .apiKeyHelpButton)
        .appButtonRole(.secondary)
        .appTVDisableDefaultFocusEffect()
        .background(
            RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
                .fill(buttonBaseBackgroundColor)
        )
        .appTVFocusOutline(
            isFocused: focusedField == .apiKeyHelpButton,
            focusedColor: focusedRowBorderColor,
            focusedLineWidth: focusedRowBorderWidth,
            cornerRadius: buttonCornerRadius,
            normalColor: buttonNormalOutlineColor
        )
        .accessibilityLabel(Text("Need Help?"))
        .accessibilityIdentifier("server.apiKey.help.button")
        .appTVOnMoveCommand { direction in
            switch direction {
            case .right:
                focusedField = .testConnectionButton
            case .up:
                focusedField = .apiKey
            case .down:
                if canShowFillAPIKeyButton {
                    focusedField = .fillAPIKeyButton
                }
            default:
                break
            }
        }
    }

    private var fillAPIKeyButton: some View {
        Button {
            if let config = debugServerConfigFromInfoPlist {
                serverURL = config.url
                apiKey = config.apiKey
                focusedField = .testConnectionButton
            }
        } label: {
            Label("Autofill Settings", systemImage: "doc.on.clipboard")
                .font(
                    .system(
                        size: isCompactHeight
                            ? ServerFormLayout.compactDebugActionFontSizePoints
                            : ServerFormLayout.regularDebugActionFontSizePoints, weight: .semibold)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(
                    maxWidth: .infinity,
                    minHeight: isCompactHeight
                        ? ServerFormLayout.compactDebugActionHeightPoints
                        : ServerFormLayout.regularDebugActionHeightPoints)
        }
        .buttonStyle(TVFocusButtonStyle())
        .focused($focusedField, equals: .fillAPIKeyButton)
        .appTVDisableDefaultFocusEffect()
        .background(
            RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
                .fill(buttonBaseBackgroundColor)
        )
        .appTVFocusOutline(
            isFocused: focusedField == .fillAPIKeyButton,
            focusedColor: focusedRowBorderColor,
            focusedLineWidth: focusedRowBorderWidth,
            cornerRadius: buttonCornerRadius,
            normalColor: buttonNormalOutlineColor
        )
        .accessibilityIdentifier("firstboot.fillConfig.button")
        .appTVOnMoveCommand { direction in
            switch direction {
            case .up:
                focusedField = .testConnectionButton
            default:
                break
            }
        }
    }

    private var testConnectionButton: some View {
        Button {
            onTestConnection()
        } label: {
            Text("Test Connection")
                .accessibilityIdentifier("firstboot.testConnection.button")
                .font(
                    .system(
                        size: isCompactHeight
                            ? ServerFormLayout.compactActionFontSizePoints
                            : ServerFormLayout.regularActionFontSizePoints, weight: .semibold)
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: isCompactHeight
                        ? ServerFormLayout.compactActionHeightPoints : ServerFormLayout.regularActionHeightPoints
                )
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("firstboot.testConnection.button")
        }
        .buttonStyle(TVFocusButtonStyle())
        .focused($focusedField, equals: .testConnectionButton)
        .appButtonRole(.secondary)
        .appTVDisableDefaultFocusEffect()
        .background(
            RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
                .fill(buttonBaseBackgroundColor)
        )
        .appTVFocusOutline(
            isFocused: focusedField == .testConnectionButton,
            focusedColor: focusedRowBorderColor,
            focusedLineWidth: focusedRowBorderWidth,
            cornerRadius: buttonCornerRadius,
            normalColor: buttonNormalOutlineColor
        )
        .accessibilityIdentifier("firstboot.testConnection.button")
        .appTVOnMoveCommand { direction in
            switch direction {
            case .left:
                focusedField = .apiKeyHelpButton
            case .right:
                if canSaveConfig {
                    focusedField = .saveConfigButton
                }
            case .up:
                focusedField = .apiKey
            case .down:
                if canShowFillAPIKeyButton {
                    focusedField = .fillAPIKeyButton
                }
            default:
                break
            }
        }
    }

    // The Save button can't be focused until the connection is verified.
    private var saveConfigButton: some View {
        Button {
            onSave()
        } label: {
            HStack(spacing: 8) {
                Text("Save Settings")
                    .accessibilityIdentifier("firstboot.saveConfig.button")
                if !canSaveConfig {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                }
            }
            .font(
                .system(
                    size: isCompactHeight
                        ? ServerFormLayout.compactActionFontSizePoints : ServerFormLayout.regularActionFontSizePoints,
                    weight: .semibold)
            )
            .frame(
                maxWidth: .infinity,
                minHeight: isCompactHeight
                    ? ServerFormLayout.compactActionHeightPoints : ServerFormLayout.regularActionHeightPoints
            )
            .foregroundStyle(saveButtonLabelColor)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("firstboot.saveConfig.button")
        }
        .buttonStyle(TVFocusButtonStyle())
        .disabled(!canSaveConfig)
        .focused($focusedField, equals: .saveConfigButton)
        .appButtonRole(.primary)
        .appTVDisableDefaultFocusEffect()
        .appTVDisabledEmphasis(canSaveConfig)
        .background(
            RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
                .fill(
                    canSaveConfig
                        ? buttonBaseBackgroundColor
                        : (colorScheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.62))
                )
        )
        .appTVFocusOutline(
            isFocused: focusedField == .saveConfigButton,
            focusedColor: focusedRowBorderColor,
            focusedLineWidth: focusedRowBorderWidth,
            cornerRadius: buttonCornerRadius,
            normalColor: canSaveConfig ? buttonNormalOutlineColor : Color.black.opacity(0.10)
        )
        .accessibilityIdentifier("firstboot.saveConfig.button")
        .appTVOnMoveCommand { direction in
            switch direction {
            case .left:
                focusedField = .testConnectionButton
            case .up:
                focusedField = .apiKey
            case .down:
                if canShowFillAPIKeyButton {
                    focusedField = .fillAPIKeyButton
                }
            default:
                break
            }
        }
    }

    private var cardBackgroundColor: Color {
        if isSettingsPagePresentation {
            return colorScheme == .dark
                ? Color.white.opacity(0.05)
                : Color.black.opacity(0.035)
        }

        return colorScheme == .dark
            ? PlatformCompat.secondarySystemBackground
            : Color.white.opacity(0.96)
    }

    private var cardBorderColor: Color {
        if isSettingsPagePresentation {
            return colorScheme == .dark
                ? Color.white.opacity(0.10)
                : Color.black.opacity(0.07)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.12)
    }

    private var cardShadowColor: Color {
        isSettingsPagePresentation
            ? .clear
            : (colorScheme == .dark
                ? Color.black.opacity(0.35)
                : Color.black.opacity(0.10))
    }

    private var inputSectionCornerRadius: CGFloat {
        isSettingsPagePresentation ? 24 : 20
    }

    private var buttonBaseBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.88)
    }

    private var buttonNormalOutlineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.20)
    }

    private var saveButtonLabelColor: Color {
        canSaveConfig
            ? .primary
            : (colorScheme == .dark ? Color.white.opacity(0.65) : Color.white.opacity(0.92))
    }

    @ViewBuilder
    private func inputRow(
        title: LocalizedStringResource,
        placeholder: LocalizedStringResource,
        text: Binding<String>,
        field: FormField,
        showVerifiedBadge: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: ServerFormLayout.inputRowSpacingPoints) {
            HStack(alignment: .center, spacing: ServerFormLayout.inputContentSpacingPoints) {
                Text(String(localized: title))
                    .font(
                        .system(
                            size: isCompactHeight
                                ? ServerFormLayout.compactInputTitleSizePoints
                                : ServerFormLayout.regularInputTitleSizePoints, weight: .semibold)
                    )
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)
            }

            HStack(spacing: ServerFormLayout.inputContentSpacingPoints) {
                formInputField(placeholder: placeholder, text: text, field: field)

                if showVerifiedBadge {
                    Image(systemName: "checkmark.circle.fill")
                        .font(
                            .system(
                                size: isCompactHeight
                                    ? ServerFormLayout.compactVerificationIconSizePoints
                                    : ServerFormLayout.regularVerificationIconSizePoints)
                        )
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .padding(.top, ServerFormLayout.inputTopPaddingPoints)
        .padding(
            .horizontal,
            isCompactHeight
                ? ServerFormLayout.compactInputHorizontalPaddingPoints
                : ServerFormLayout.regularInputHorizontalPaddingPoints
        )
        .padding(
            .vertical,
            isCompactHeight
                ? ServerFormLayout.compactInputVerticalPaddingPoints
                : ServerFormLayout.regularInputVerticalPaddingPoints
        )
        .overlay(
            RoundedRectangle(cornerRadius: inputRowCornerRadius, style: .continuous)
                .stroke(
                    focusedField == field ? focusedRowBorderColor : Color.clear,
                    lineWidth: focusedField == field ? focusedRowBorderWidth : 0
                )
        )
        // Whole-row accessibility container, so different input states
        // don't expose the UIKit text field as different element types.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(field == .apiKey ? "firstboot.apiKey.row" : "firstboot.serverURL.row")
    }

    // Use a UIKit text field to remove height and font differences between SwiftUI TextField and SecureField.
    @ViewBuilder
    private func formInputField(
        placeholder: LocalizedStringResource,
        text: Binding<String>,
        field: FormField
    ) -> some View {

        let localizedPlaceholder = String(localized: placeholder)

        #if os(tvOS)
        TVSystemCapsuleTextField(
            text: text,
            placeholder: localizedPlaceholder,
            isSecure: field == .apiKey,
            isFocused: focusedField == field,
            accessibilityIdentifier: field == .apiKey ? "firstboot.apiKey.field" : "firstboot.serverURL.field"
        )
        .appFormTextInputBehavior()
        .multilineTextAlignment(.leading)
        .foregroundStyle(.primary)
        .padding(.horizontal, ServerFormLayout.textFieldHorizontalPaddingPoints)
        .frame(
            maxWidth: .infinity,
            minHeight: TVOSServerConfigFormMetrics.inputCapsuleHeight,
            maxHeight: TVOSServerConfigFormMetrics.inputCapsuleHeight,
            alignment: .leading
        )
        .focused($focusedField, equals: field)
        .appTVOnMoveCommand { direction in
            switch direction {
            case .down:
                if field == .serverURL {
                    focusedField = .apiKey
                } else {
                    focusedField = .testConnectionButton
                }
            case .up:
                if field == .apiKey {
                    focusedField = .serverURL
                }
            default:
                break
            }
        }
        #else
        EmptyView()
        #endif
    }
}

#if os(tvOS)
private final class TVStableWidthTextField: UITextField {
    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        size.width = UIView.noIntrinsicMetric
        return size
    }
}

private struct TVSystemCapsuleTextField: UIViewRepresentable {
    typealias Coordinator = TVSystemCapsuleTextFieldCoordinator

    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    let isFocused: Bool
    let accessibilityIdentifier: String

    func makeUIView(context: Context) -> UITextField {
        let textField = TVStableWidthTextField()
        let inputFont = UIFont.systemFont(ofSize: TVOSServerConfigFormMetrics.inputFontSize, weight: .regular)
        let resolvedTextColor = resolvedInputTextColor(isFocused: isFocused)
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.textAlignment = .left
        textField.clearButtonMode = .never
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.returnKeyType = .next
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Lock the font so the focused state doesn't switch to a larger default style.
        textField.font = inputFont
        textField.textColor = resolvedTextColor
        textField.defaultTextAttributes = [
            .font: inputFont,
            .foregroundColor: resolvedTextColor
        ]
        textField.typingAttributes = [
            .font: inputFont,
            .foregroundColor: resolvedTextColor
        ]
        textField.adjustsFontForContentSizeCategory = false
        textField.adjustsFontSizeToFitWidth = false
        // Attach the identifier to the UIKit control, so XCTest can still see the input field after SwiftUI wrapping.
        textField.accessibilityIdentifier = accessibilityIdentifier
        textField.isAccessibilityElement = true
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(TVSystemCapsuleTextFieldCoordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        let inputFont = UIFont.systemFont(ofSize: TVOSServerConfigFormMetrics.inputFontSize, weight: .regular)
        let placeholderFont = UIFont.systemFont(
            ofSize: TVOSServerConfigFormMetrics.placeholderFontSize, weight: .regular)
        let resolvedTextColor = resolvedInputTextColor(isFocused: isFocused)
        uiView.accessibilityIdentifier = accessibilityIdentifier
        uiView.accessibilityLabel = placeholder
        uiView.font = inputFont
        uiView.textColor = resolvedTextColor
        context.coordinator.updateResolvedTextColor(resolvedTextColor)

        if isSecure {
            if uiView.isSecureTextEntry == false {
                let wasFirstResponder = uiView.isFirstResponder
                uiView.isSecureTextEntry = true
                uiView.defaultTextAttributes = [
                    .font: inputFont,
                    .foregroundColor: resolvedTextColor
                ]
                uiView.typingAttributes = [
                    .font: inputFont,
                    .foregroundColor: resolvedTextColor
                ]
                if wasFirstResponder {
                    uiView.becomeFirstResponder()
                }
            }

            if uiView.text != text {
                uiView.text = text
            }
        } else {
            if uiView.isSecureTextEntry {
                let wasFirstResponder = uiView.isFirstResponder
                uiView.isSecureTextEntry = false
                if wasFirstResponder {
                    uiView.becomeFirstResponder()
                }
            }

            if uiView.text != text {
                uiView.text = text
            }
        }

        uiView.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: placeholderFont,
                // While the default-focus row's UITextField isn't first
                // responder yet, the placeholder can't hard-code secondaryLabel.

                .foregroundColor: resolvedPlaceholderColor(isFocused: isFocused)
            ]
        )
    }

    private func resolvedInputTextColor(isFocused: Bool) -> UIColor {
        // Use dark input text when focused, to avoid white text on a bright capsule.

        UIColor { traits in
            if isFocused {
                return traits.userInterfaceStyle == .dark
                    ? UIColor(white: 0.08, alpha: 0.98)
                    : UIColor.black.withAlphaComponent(0.96)
            }

            return UIColor.label
        }
    }

    private func resolvedPlaceholderColor(isFocused: Bool) -> UIColor {
        // Use a dynamic color for the focused placeholder; it follows light/dark mode and is clearer than secondary.

        UIColor { traits in
            if isFocused {
                // The focused capsule is nearly white, so the placeholder can't use the near-white primary text color.

                return traits.userInterfaceStyle == .dark
                    ? UIColor(white: 0.18, alpha: 0.96)
                    : UIColor.black.withAlphaComponent(0.94)
            }

            return UIColor.secondaryLabel
        }
    }

    func makeCoordinator() -> Coordinator {
        TVSystemCapsuleTextFieldCoordinator(text: $text, isSecure: isSecure)
    }
}

// The Coordinator writes the UIKit text back to the Binding when editing ends, covering HeadBoard's late commit.

final class TVSystemCapsuleTextFieldCoordinator: NSObject, UITextFieldDelegate {
    private var text: Binding<String>
    private let isSecure: Bool
    private let inputFont = UIFont.systemFont(ofSize: TVOSServerConfigFormMetrics.inputFontSize, weight: .regular)
    private var currentTextColor: UIColor = .label

    init(text: Binding<String>, isSecure: Bool) {
        self.text = text
        self.isSecure = isSecure
    }

    func updateResolvedTextColor(_ color: UIColor) {
        currentTextColor = color
    }

    private func syncBindingFromTextField(_ textField: UITextField) {
        text.wrappedValue = textField.text ?? ""
    }

    // Keep a consistent text style while editing, so the font size doesn't jump after switching input methods.
    private func enforceConsistentTypingStyle(on textField: UITextField) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: inputFont,
            .foregroundColor: currentTextColor
        ]
        textField.defaultTextAttributes = attrs
        textField.typingAttributes = attrs

        guard let rawText = textField.text, !rawText.isEmpty else { return }
        let selectedRange = textField.selectedTextRange
        textField.attributedText = NSAttributedString(string: rawText, attributes: attrs)
        if let selectedRange {
            textField.selectedTextRange = selectedRange
        }
    }

    @objc func textDidChange(_ sender: UITextField) {
        enforceConsistentTypingStyle(on: sender)
        syncBindingFromTextField(sender)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if isSecure {
            textField.isSecureTextEntry = true
            textField.text = text.wrappedValue
        }
        enforceConsistentTypingStyle(on: textField)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        // When editing ends, write back to the Binding first, then restore the secure-entry appearance.

        syncBindingFromTextField(textField)

        if isSecure {

            textField.isSecureTextEntry = true
            textField.text = text.wrappedValue
        }

        enforceConsistentTypingStyle(on: textField)
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        enforceConsistentTypingStyle(on: textField)
        return true
    }
}
#endif

private struct TVFocusButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct TVOSServerConfigFocusGuideBridge: UIViewRepresentable {
    let upwardSourceIdentifiers: [String]
    let upwardDestinationIdentifier: String
    let downwardSourceIdentifier: String
    let downwardPreferredDestinationIdentifier: String
    let downwardDestinationIdentifiers: [String]

    func makeUIView(context: Context) -> TVOSServerConfigFocusGuideHostView {
        TVOSServerConfigFocusGuideHostView()
    }

    func updateUIView(_ uiView: TVOSServerConfigFocusGuideHostView, context: Context) {
        uiView.configure(
            upwardSourceIdentifiers: upwardSourceIdentifiers,
            upwardDestinationIdentifier: upwardDestinationIdentifier,
            downwardSourceIdentifier: downwardSourceIdentifier,
            downwardPreferredDestinationIdentifier: downwardPreferredDestinationIdentifier,
            downwardDestinationIdentifiers: downwardDestinationIdentifiers
        )
    }
}

private final class TVOSServerConfigFocusGuideHostView: UIView {
    private let upwardGuide = UIFocusGuide()
    private let downwardGuide = UIFocusGuide()

    private var upwardSourceIdentifiers: [String] = []
    private var upwardDestinationIdentifier: String = ""
    private var downwardSourceIdentifier: String = ""
    private var downwardPreferredDestinationIdentifier: String = ""
    private var downwardDestinationIdentifiers: [String] = []
    private var hasInstalledGuides = false
    private var installedConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        upwardSourceIdentifiers: [String],
        upwardDestinationIdentifier: String,
        downwardSourceIdentifier: String,
        downwardPreferredDestinationIdentifier: String,
        downwardDestinationIdentifiers: [String]
    ) {
        self.upwardSourceIdentifiers = upwardSourceIdentifiers
        self.upwardDestinationIdentifier = upwardDestinationIdentifier
        self.downwardSourceIdentifier = downwardSourceIdentifier
        self.downwardPreferredDestinationIdentifier = downwardPreferredDestinationIdentifier
        self.downwardDestinationIdentifiers = downwardDestinationIdentifiers
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installGuidesIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        installGuidesIfNeeded()
        updateGuides()
    }

    private func installGuidesIfNeeded() {
        guard hasInstalledGuides == false, let container = superview else { return }
        hasInstalledGuides = true
        container.addLayoutGuide(upwardGuide)
        container.addLayoutGuide(downwardGuide)
    }

    private func updateGuides() {
        guard let container = superview else { return }
        NSLayoutConstraint.deactivate(installedConstraints)
        installedConstraints.removeAll()

        let upwardSourceViews = upwardSourceIdentifiers.compactMap {
            findFocusableView(withIdentifier: $0, in: container)
        }
        guard
            let topInputView = findFocusableView(withIdentifier: downwardSourceIdentifier, in: container),
            let upperDestination = findFocusableView(withIdentifier: upwardDestinationIdentifier, in: container),
            let leftMostActionView = upwardSourceViews.min(by: { $0.frame.minX < $1.frame.minX })
        else {
            upwardGuide.isEnabled = false
            downwardGuide.isEnabled = false
            return
        }

        // The main downward path should still go to Test Connection first, not the help entry.
        let downwardDestinationView =
            findFocusableView(withIdentifier: downwardPreferredDestinationIdentifier, in: container)
            ?? leftMostActionView
        downwardGuide.preferredFocusEnvironments = [downwardDestinationView]
        upwardGuide.preferredFocusEnvironments = [upperDestination]
        downwardGuide.isEnabled = true
        upwardGuide.isEnabled = true

        let rightMostActionView = upwardSourceViews.max(by: { $0.frame.maxX < $1.frame.maxX }) ?? leftMostActionView

        installedConstraints.append(contentsOf: [
            downwardGuide.leadingAnchor.constraint(equalTo: topInputView.leadingAnchor),
            downwardGuide.trailingAnchor.constraint(equalTo: rightMostActionView.trailingAnchor),
            downwardGuide.topAnchor.constraint(equalTo: topInputView.bottomAnchor, constant: 8),
            downwardGuide.bottomAnchor.constraint(equalTo: leftMostActionView.topAnchor, constant: -8),

            upwardGuide.leadingAnchor.constraint(equalTo: leftMostActionView.leadingAnchor),
            upwardGuide.trailingAnchor.constraint(equalTo: rightMostActionView.trailingAnchor),
            upwardGuide.topAnchor.constraint(equalTo: topInputView.bottomAnchor, constant: 8),
            upwardGuide.bottomAnchor.constraint(equalTo: leftMostActionView.topAnchor, constant: -8)
        ])

        NSLayoutConstraint.activate(installedConstraints)
    }

    private func findFocusableView(withIdentifier identifier: String, in root: UIView) -> UIView? {
        findFocusableView(
            withIdentifier: identifier,
            in: root,
            nearestFocusableAncestor: root.canBecomeFocused ? root : nil
        )
    }

    private func findFocusableView(
        withIdentifier identifier: String,
        in root: UIView,
        nearestFocusableAncestor: UIView?
    ) -> UIView? {
        let focusableCandidate = root.canBecomeFocused ? root : nearestFocusableAncestor

        if root.accessibilityIdentifier == identifier {
            return focusableCandidate
        }

        for subview in root.subviews {
            if let match = findFocusableView(
                withIdentifier: identifier,
                in: subview,
                nearestFocusableAncestor: focusableCandidate
            ) {
                return match
            }
        }
        return nil
    }
}
