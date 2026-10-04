import SwiftUI

extension SettingsViewTV {
    var serverSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Connection and Sync",
            title: "Immich Server",
            description: "Set the server URL and API Key.",
            symbolName: "server.rack",
            accent: Color.blue,
            secondaryAccent: Color.mint,
            summary: serverHeroSummary,
            summaryAccessibilityIdentifier: "settings.server.hero.summary"
        ) {
            TVSettingsCard {
                if let saveFeedbackText = serverSaveFeedbackText {
                    TVSettingsProminentResultBanner(
                        text: saveFeedbackText,
                        tint: .green,
                        systemImage: "checkmark.circle.fill",
                        accessibilityIdentifier: "settings.server.feedback.save.success"
                    )

                    Divider()
                }

                // The server form declares itself a Settings subpage,
                // so it doesn't use the large first-launch card shell.

                ServerConfigFormView(
                    serverURL: $serverURL,
                    apiKey: $apiKey,
                    isConnectionVerified: isConnectionVerified,
                    onTestConnection: onTestConnection,
                    onSave: onSaveServerConfig,
                    tvPresentation: .settingsPage,
                    tvPreferredMaxWidth: nil,
                    tvHorizontalPadding: 0
                )
            }
        }
        .alert(serverErrorAlertTitle, isPresented: $isServerErrorAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(serverErrorMessage))
        }
    }

    var cacheSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Storage and Performance",
            title: "Cache Management",
            description: "View cache usage and clear it when needed.",
            symbolName: "internaldrive.fill",
            accent: Color.mint,
            secondaryAccent: Color.cyan,
            summary: cacheHeroSummary
        ) {
            TVSettingsCard {

                TVSettingsReadOnlyRow(
                    title: "Disk Cache",
                    value: formatBytes(cacheSummary.diskBytes),
                    accessibilityIdentifier: "settings.cache.disk.row"
                )
                TVSettingsReadOnlyRow(
                    title: "Tracked URL Count",
                    value: "\(cacheSummary.trackedAssetURLCount)",
                    accessibilityIdentifier: "settings.cache.trackedURL.row"
                )
                TVSettingsReadOnlyRow(
                    title: "Tracked State Count",
                    value: "\(cacheSummary.trackedStateCount)",
                    accessibilityIdentifier: "settings.cache.trackedState.row"
                )
                TVSettingsReadOnlyRow(
                    title: "Running Tasks",
                    value: "\(cacheSummary.runningTaskCount)",
                    accessibilityIdentifier: "settings.cache.runningTask.row"
                )

                Divider()

                TVSettingsActionRow(
                    title: "Clear Disk Cache",
                    value: "Requires Confirmation",
                    valueTint: .orange,
                    isEnabled: !isClearingCache,
                    accessibilityIdentifier: "settings.cache.clearDisk.button",
                    action: onClearDiskCache
                )

                if isClearingCache {
                    SlidePlaybackLoadingView(
                        message: "Clearing cache...",
                        style: .inline,
                        accessibilityIdentifier: "settings.cache.clearing.status"
                    )
                } else if !cacheStatusMessage.isEmpty {
                    TVSettingsStatusBanner(
                        text: cacheStatusMessage,
                        tint: .secondary,
                        accessibilityIdentifier: "settings.cache.status.message"
                    )
                }
            }
        }
        .alert("Confirm Disk Cache Clear", isPresented: $isClearDiskCacheAlertPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                onConfirmClearDiskCache()
            }
        } message: {
            Text("This will clear the disk cache and also clear related state dictionaries in the download manager.")
        }
    }

    var serverHeroSummary: String {
        if isTestingConnection {
            return String(localized: "Testing server connection")
        }

        if isConnectionVerified {
            return String(localized: "Server connection verified")
        }

        if serverStatusMessage.isEmpty == false {
            return serverStatusMessage
        }

        return String(localized: "Current settings need verification. Please test the connection.")
    }

    var serverSaveFeedbackText: String? {

        guard serverStatusMessage == String(localized: "Configuration saved") else {
            return nil
        }
        return serverStatusMessage
    }

    var cacheHeroSummary: String {
        LocalizedText.format("Current disk cache %@", formatBytes(cacheSummary.diskBytes))
    }

    func formatBytes(_ bytes: UInt) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
