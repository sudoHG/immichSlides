import SwiftUI

extension SettingsViewTV {
    var accessProtectionSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Privacy & Protection",
            title: "Access Protection",
            description: "Use a 6-digit PIN to protect the settings entry.",
            symbolName: "lock.shield.fill",
            accent: Color.orange,
            secondaryAccent: Color.pink,
            summary: accessProtectionHeroSummary
        ) {
            TVSettingsCard {
                accessProtectionUITestStateProbe

                TVSettingsReadOnlyRow(
                    title: "Current status",
                    value: accessProtectionCurrentStatusText,
                    accessibilityIdentifier: "settings.pin.status.row"
                )

                Divider()

                // Show success feedback at the top of the card, so it doesn't
                // look like there was no feedback after the action area changes.

                if !accessProtectionErrorMessage.isEmpty {
                    TVSettingsProminentResultBanner(
                        text: accessProtectionErrorMessage,
                        tint: .red,
                        systemImage: "exclamationmark.triangle.fill",
                        accessibilityIdentifier: "settings.pin.feedback.error.prominent"
                    )

                    Divider()
                } else if !accessProtectionStatusMessage.isEmpty {
                    let successFeedbackStyle = accessProtectionSuccessFeedbackStyle
                    TVSettingsProminentResultBanner(
                        text: accessProtectionStatusMessage,
                        tint: successFeedbackStyle.tint,
                        systemImage: successFeedbackStyle.systemImage,
                        accessibilityIdentifier: "settings.pin.feedback.success.prominent"
                    )

                    Divider()
                }

                if accessProtectionEnabled && accessProtectionNeedsRecovery {
                    TVSettingsSectionBlock(
                        title: "Recovery",
                        subtitle: "An access protection state issue was detected."
                    ) {
                        TVSettingsStatusBanner(text: "Access Protection State Issue", tint: .orange)

                        Text("Reset access protection first, then set the PIN again.")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.secondary)

                        TVSettingsActionRow(
                            title: "Reset Access Protection",
                            value: "Clear Error State",
                            valueTint: .orange,
                            accessibilityIdentifier: "settings.pin.resetProtection.button",
                            action: onResetProtection
                        )
                        .focused($focusedDetailItem, equals: .accessProtectionReset)
                    }
                } else if accessProtectionEnabled {
                    TVSettingsSectionBlock(
                        title: "Turn Off Access Protection",
                        subtitle: "Enter the current PIN before turning it off."
                    ) {
                        pinInputRow(
                            title: "Enter Current PIN",
                            value: disablePin,
                            target: .disablePin,
                            focusTarget: .accessProtectionDisablePin
                        )

                        TVSettingsActionRow(
                            title: "Turn Off Access Protection",
                            value: "Current PIN Required",
                            valueTint: .secondary,
                            isEnabled: disablePin.count == 6,
                            accessibilityIdentifier: "settings.pin.disable.button",
                            action: onDisableProtection
                        )
                    }

                    Divider()

                    TVSettingsSectionBlock(
                        title: "Change PIN",
                        subtitle: "Enter the current PIN, new PIN, and confirmation PIN in order."
                    ) {
                        pinInputRow(
                            title: "Current PIN",
                            value: currentPinForChange,
                            target: .currentPinForChange
                        )

                        pinInputRow(
                            title: "New PIN (6 digits)",
                            value: newPin,
                            target: .newPin
                        )

                        pinInputRow(
                            title: "Confirm New PIN",
                            value: newPinConfirm,
                            target: .newPinConfirm
                        )

                        TVSettingsActionRow(
                            title: "Save New PIN",
                            value: "Current PIN and New PIN Required",
                            valueTint: .secondary,
                            isEnabled: canChangePIN,
                            accessibilityIdentifier: "settings.pin.change.button",
                            action: onChangePIN
                        )
                    }
                } else {
                    TVSettingsSectionBlock(
                        title: "Turn On Access Protection",
                        subtitle: "Set a PIN first, then enter it again to confirm."
                    ) {
                        pinInputRow(
                            title: "Set PIN (6 digits)",
                            value: enablePin,
                            target: .enablePin,
                            focusTarget: .accessProtectionEnablePin
                        )

                        pinInputRow(
                            title: "Confirm PIN",
                            value: enablePinConfirm,
                            target: .enablePinConfirm
                        )

                        TVSettingsActionRow(
                            title: "Turn On Access Protection",
                            value: "PIN Setup and Confirmation Required",
                            valueTint: .secondary,
                            isEnabled: canEnablePIN,
                            accessibilityIdentifier: "settings.pin.enable.button",
                            action: onEnableProtection
                        )
                    }
                }

            }
        }
        .appTVFocusScope(
            detailListFocusScope,
            focused: $focusedDetailItem,
            default: accessProtectionPageDefaultFocusTarget,
            priority: .userInitiated
        )
        .onAppear {
            DispatchQueue.main.async {
                focusedDetailItem = accessProtectionPageDefaultFocusTarget
            }
        }
        .onChange(of: accessProtectionEnabled) { _, _ in
            // After the branch switches, give focus to the new branch's first item on the next frame.

            DispatchQueue.main.async {
                focusedDetailItem = accessProtectionPageDefaultFocusTarget
            }
        }
    }

    @ViewBuilder
    var accessProtectionUITestStateProbe: some View {
        if shouldExposeAccessProtectionUITestStateProbe {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("settings.pin.stateProbe")
                .accessibilityLabel(Text(verbatim: "Access protection test state"))
                .accessibilityValue(Text(verbatim: accessProtectionUITestStateProbeValue))
        }
    }

    var shouldExposeAccessProtectionUITestStateProbe: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["UI_TEST_RESET_STATE"] == "1" else {
            return false
        }

        // The probe is visible only under XCTest; it doesn't appear in normal Debug or production environments.

        return ImmichServer.isRunningXCTest
        #else
        return false
        #endif
    }

    var accessProtectionUITestStateProbeValue: String {
        [
            "enabled=\(accessProtectionEnabled)",
            "needsRecovery=\(accessProtectionNeedsRecovery)",
            "enablePinCount=\(enablePin.count)",
            "enableConfirmCount=\(enablePinConfirm.count)",
            "disablePinCount=\(disablePin.count)",
            "status=\(accessProtectionStatusMessage)",
            "error=\(accessProtectionErrorMessage)"
        ].joined(separator: " | ")
    }

    @ViewBuilder
    func pinInputRow(
        title: String,
        value: String,
        target: AccessPinInputTarget,
        focusTarget: DetailFocusTarget? = nil
    ) -> some View {
        let pinRow = TVSettingsFocusableControl(
            accessibilityLabel: title,
            accessibilityIdentifier: pinInputAccessibilityID(target),
            action: {
                onOpenPinInput(target)
            }
        ) {
            TVSettingsActionRowLabel(
                title: title,
                value: maskedPINText(for: value),
                valueTint: .secondary,
                isEnabled: true,
                // Pass true only when the target focus matches; otherwise fall
                // back to system focus, to avoid focus with no highlight.

                isFocusedOverride: focusTarget.flatMap { focusedDetailItem == $0 ? true : nil }
            )
        }

        if let focusTarget {
            pinRow.focused($focusedDetailItem, equals: focusTarget)
        } else {
            pinRow
        }
    }
    var canEnablePIN: Bool {
        enablePin.count == 6 && enablePinConfirm.count == 6
    }

    var canChangePIN: Bool {
        currentPinForChange.count == 6 && newPin.count == 6 && newPinConfirm.count == 6
    }

    var accessProtectionPageDefaultFocusTarget: DetailFocusTarget {
        if accessProtectionEnabled && accessProtectionNeedsRecovery {
            return .accessProtectionReset
        }

        if accessProtectionEnabled {
            return .accessProtectionDisablePin
        }

        return .accessProtectionEnablePin
    }

    var accessProtectionCurrentStatusText: String {
        if accessProtectionEnabled && accessProtectionNeedsRecovery {
            return String(localized: "Error (Recovery Needed)")
        }

        return accessProtectionEnabled ? String(localized: "Turned on") : String(localized: "Not enabled")
    }
    var accessProtectionHeroSummary: String {
        if accessProtectionEnabled && accessProtectionNeedsRecovery {
            return String(localized: "Access protection error. Recovery required.")
        }

        return accessProtectionEnabled
            ? String(localized: "Access protection is on") : String(localized: "Access protection is disabled")
    }

    var accessProtectionSuccessFeedbackStyle: (tint: Color, systemImage: String) {
        // Use green for a successful enable; use orange for disable/reset so it doesn't share the enable color.

        if accessProtectionStatusMessage == String(localized: "Access protection is off") {
            return (.orange, "lock.open.fill")
        }

        if accessProtectionStatusMessage == String(localized: "Access protection was reset. Set the PIN again.") {
            return (.orange, "arrow.counterclockwise.circle.fill")
        }

        if accessProtectionStatusMessage == String(localized: "Access protection is on") {
            return (.green, "lock.fill")
        }

        return (.green, "checkmark.circle.fill")
    }
    func maskedPINText(for value: String) -> String {
        // The empty-value hint to the right of the PIN must be localized; once entered, show masked dots.

        if value.isEmpty {
            return String(localized: "Tap to enter")
        }

        return String(repeating: "●", count: value.count)
    }
}
