import SwiftUI

private enum PlaybackIntervalControlMetrics {
    static let minimumSeconds: Double = 5
    static let maximumSeconds: Double = 30
    static let stepSeconds: Double = 1
}

#if os(iOS)
private struct PlaybackFilterBlockedAlertHost<Content: View>: View {
    @ObservedObject var promptState: SettingsPromptStore
    let content: Content
    let onOpenFilterEditor: () -> Void
    let onCancel: () -> Void

    var body: some View {
        content
            .alert("Can't Switch to Filtered Playback", isPresented: $promptState.shouldShowFilterModeBlockedAlert) {
                Button("Set Up Filters", role: .destructive) {
                    onOpenFilterEditor()
                }
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
            } message: {
                Text("No filters are set. Choose albums or people first.")
            }
    }
}

private struct ClearDiskCacheAlertHost<Content: View>: View {
    @ObservedObject var promptState: SettingsPromptStore
    let content: Content
    let onConfirm: () -> Void

    var body: some View {
        content
            .alert("Confirm Disk Cache Clear", isPresented: $promptState.shouldShowClearDiskCacheAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    onConfirm()
                }
            } message: {
                Text("This will clear the cached photos and temporary data.")
            }
    }
}
#endif

extension SettingsView {
    @ViewBuilder
    func settingsDetail(_ selection: SettingSelection) -> some View {
        switch selection {
        case .server:
            serverSettings()
        case .accessProtection:
            accessProtectionSettings()
        case .playback:
            playbackSettings()
        case .cache:
            cacheSettings()
        case .about:
            aboutSettings()
        }
    }

    func playbackSettings() -> some View {
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playback Settings")
                        .accessibilityIdentifier("settings.playback.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Configure autoplay, interval, and display options.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, SettingsCardLayout.titleLeading)
                .padding(.top, 6)

                SettingsSectionCardView(
                    innerHorizontalInset: SettingsCardLayout.cardInnerHorizontalInset,
                    innerVerticalInset: SettingsCardLayout.cardInnerVerticalInset,
                    outerHorizontalInset: SettingsCardLayout.cardOuterHorizontalInset,
                    cornerRadius: SettingsCardLayout.cardCornerRadius
                ) {
                    Toggle("Autoplay", isOn: settingsBinding(\.autoPlayEnabled))
                        .accessibilityIdentifier("settings.playback.autoPlay.toggle")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Autoplay Interval")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack {
                            // Slider is iOS-only; the TV interval control lives in SettingsViewTV+PlaybackPages.
                            #if os(iOS)
                            Slider(
                                value: settingsBinding(\.intervalSeconds),
                                in: PlaybackIntervalControlMetrics
                                    .minimumSeconds...PlaybackIntervalControlMetrics.maximumSeconds,
                                step: PlaybackIntervalControlMetrics.stepSeconds
                            )
                            .accessibilityIdentifier("settings.playback.interval.slider")
                            .disabled(!playbackVM.settings.autoPlayEnabled)
                            #endif

                            Text("\(Int(playbackVM.settings.intervalSeconds)) sec")
                                .accessibilityIdentifier("settings.playback.interval.value")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Playback Mode")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("Default Playback Mode", selection: playbackModeBinding) {
                            Text("Random Playback").tag(DefaultPlaybackMode.random)
                            Text("Filtered Playback").tag(DefaultPlaybackMode.filtered)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("settings.playback.mode.picker")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display Mode")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("Display Mode", selection: settingsBinding(\.displayMode)) {
                            Text("Smart Fill").tag(PlaybackDisplayMode.smartFill)
                                .accessibilityIdentifier("settings.playback.displayMode.smartFill.option")
                            Text("Single Photo Mode").tag(PlaybackDisplayMode.singlePhoto)
                                .accessibilityIdentifier("settings.playback.displayMode.singlePhoto.option")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("settings.playback.displayMode.picker")
                    }

                    if playbackVM.settings.defaultPlaybackMode == .filtered {
                        Button {
                            openFilterEditor()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Filters")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)

                                    Text(filterSummaryText)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("Edit")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("settings.playback.filterConfig.button")

                        if filterVM.selection.isEmpty {
                            Text("Filtered Playback is selected, but no filters are set up yet.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    Toggle("Show EXIF Info", isOn: settingsBinding(\.showExif))
                        .accessibilityIdentifier("settings.playback.showExif.toggle")

                    if PlatformCompat.isPlaybackDebugPanelEnabled {
                        Toggle("Show Debug Panel", isOn: settingsBinding(\.showDebugOverlay))
                            .accessibilityIdentifier("settings.playback.showDebug.toggle")
                    }
                }
            }
            .frame(maxWidth: SettingsCardLayout.sectionMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 14)
        }
        #if os(iOS)
        return PlaybackFilterBlockedAlertHost(
            promptState: promptState,
            content: content,
            onOpenFilterEditor: openFilterEditor,
            onCancel: cancelFilterModeBlockedAlert
        )
        #else
        return content
        #endif
    }

    func serverSettings() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Immich Server")
                        .accessibilityIdentifier("settings.server.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Enter the server URL and API Key to connect your photo library.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, SettingsCardLayout.titleLeading)
                .padding(.top, 6)

                SettingsSectionCardView(
                    innerHorizontalInset: SettingsCardLayout.cardInnerHorizontalInset,
                    innerVerticalInset: SettingsCardLayout.cardInnerVerticalInset,
                    outerHorizontalInset: SettingsCardLayout.cardOuterHorizontalInset,
                    cornerRadius: SettingsCardLayout.cardCornerRadius
                ) {
                    // Pass settingsSection explicitly to turn off the large first-boot card shell.

                    ServerConfigFormView(
                        serverURL: $serverVM.serverURL,
                        apiKey: $serverVM.apiKey,
                        isConnectionVerified: serverVM.isConnectionVerified,
                        onTestConnection: testServerConnection,
                        onSave: saveServerConfiguration,
                        iosPresentation: .settingsSection
                    )

                    if serverVM.isTestingConnection {
                        SlidePlaybackLoadingView(
                            message: serverVM.testingStatusMessage,
                            style: .inline,
                            accessibilityIdentifier: "settings.server.status.testing"
                        )
                    } else if !serverVM.statusMessage.isEmpty {
                        Text(LocalizedStringKey(serverVM.statusMessage))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.server.status.message")
                    }
                }
            }
            .frame(maxWidth: SettingsCardLayout.sectionMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 14)
        }
        // The failure alert must be attached to the detail page, otherwise iPhone/tvOS only shows it after going
        // back to the list.

        .alert(serverVM.errorAlertTitle, isPresented: $serverVM.shouldShowErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(serverVM.errorMessage))
        }
    }

    func cacheSettings() -> some View {
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cache Management")
                        .accessibilityIdentifier("settings.cache.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("View cache usage and run a cleanup.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, SettingsCardLayout.titleLeading)
                .padding(.top, 6)

                SettingsSectionCardView(
                    innerHorizontalInset: SettingsCardLayout.cardInnerHorizontalInset,
                    innerVerticalInset: SettingsCardLayout.cardInnerVerticalInset,
                    outerHorizontalInset: SettingsCardLayout.cardOuterHorizontalInset,
                    cornerRadius: SettingsCardLayout.cardCornerRadius
                ) {
                    cacheRow(title: "Disk Cache", value: formatBytes(cacheSummary.diskBytes))
                    cacheRow(title: "Tracked URL Count", value: "\(cacheSummary.trackedAssetURLCount)")
                    cacheRow(title: "Tracked State Count", value: "\(cacheSummary.trackedStateCount)")
                    cacheRow(title: "Running Tasks", value: "\(cacheSummary.runningTaskCount)")

                    Divider()

                    Button("Clear Disk Cache", role: .destructive) {
                        requestClearDiskCache()
                    }
                    .appButtonRole(.primary)
                    .disabled(isClearingCache)
                    .accessibilityIdentifier("settings.cache.clearDisk.button")

                    if isClearingCache {
                        SlidePlaybackLoadingView(
                            message: "Clearing cache...",
                            style: .inline,
                            accessibilityIdentifier: "settings.cache.clearing.status"
                        )
                    } else if !cacheStatusMessage.isEmpty {
                        Text(LocalizedStringKey(cacheStatusMessage))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.cache.status.message")
                    }
                }
            }
            .frame(maxWidth: SettingsCardLayout.sectionMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 14)
        }
        // Refresh only while this page is on screen, so downloads do not re-render the other pages.
        .onAppear { refreshCacheSummary() }
        .onReceive(downloadManager.activeTaskCountChanges) { _ in
            refreshCacheSummary()
        }
        #if os(iOS)
        return ClearDiskCacheAlertHost(
            promptState: promptState,
            content: content,
            onConfirm: confirmClearDiskCache
        )
        #else
        return content
        #endif
    }

    func aboutSettings() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("About")
                        .accessibilityIdentifier("settings.about.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("View the current version, runtime environment, and feedback guidance.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, SettingsCardLayout.titleLeading)
                .padding(.top, 6)

                aboutSettingsCard {

                    aboutSectionHeader(title: "App Information")

                    aboutInfoRow(
                        title: "App Name",
                        value: aboutMetadata.appDisplayName,
                        accessibilityIdentifier: "settings.about.appName.row"
                    )
                    aboutInfoRow(
                        title: "Version",
                        value: aboutMetadata.versionAndBuildText,
                        accessibilityIdentifier: "settings.about.version.row"
                    )
                    aboutInfoRow(
                        title: "Platform",
                        value: aboutMetadata.platformLabel,
                        accessibilityIdentifier: "settings.about.platform.row"
                    )
                }

                aboutSettingsCard {

                    aboutSectionHeader(title: "Unofficial Notice")

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text(
                            "immichSlides is an independently developed unofficial app. It is not the official Immich app and is not endorsed, sponsored, or approved by Immich."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(PlatformCompat.secondarySystemBackground)
                    )
                    .accessibilityIdentifier("settings.about.unofficialNotice.hint")
                }

                aboutSettingsCard {
                    aboutSectionHeader(title: "Feedback & Support")

                    Button {
                        openSupportEmail()
                    } label: {
                        aboutNavigationRow(
                            title: SettingsSupportReference.entryTitle,
                            subtitle: SettingsSupportReference.emailAddress
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.about.feedback.email.link")

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)

                        Text("To report an issue, note the version number and steps to reproduce.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(PlatformCompat.secondarySystemBackground)
                    )
                    .accessibilityIdentifier("settings.about.feedback.hint")
                }

                aboutSettingsCard {
                    // iOS opens the privacy policy in the system browser to avoid a laggy in-app WKWebView.

                    aboutSectionHeader(title: "Privacy & Protection")

                    #if os(iOS)
                    Button {

                        if let privacyPolicyURL = SettingsPrivacyPolicyReference.url {
                            openURL(privacyPolicyURL)
                        }
                    } label: {
                        aboutNavigationRow(
                            title: SettingsPrivacyPolicyReference.entryTitle,
                            subtitle: SettingsPrivacyPolicyReference.entrySubtitle
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.about.privacyPolicy.link")
                    #endif
                }

                aboutSettingsCard {

                    aboutSectionHeader(title: "Open Source Licenses")

                    #if os(iOS)
                    Button {
                        // Only issues a state request to open the licenses; iPhone pushes, iPad switches the
                        // right-hand detail.

                        isShowingOpenSourceLicenses = true
                    } label: {
                        aboutNavigationRow(
                            title: "Third-Party Component Licenses",
                            subtitle: openSourceLicensePackageSummary
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.about.opensource.link")
                    #endif
                }
            }
            .frame(maxWidth: SettingsCardLayout.sectionMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 14)
        }
    }

    func aboutSettingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {

        SettingsSectionCardView(
            innerHorizontalInset: SettingsCardLayout.cardInnerHorizontalInset,
            innerVerticalInset: SettingsCardLayout.cardInnerVerticalInset,
            outerHorizontalInset: SettingsCardLayout.cardOuterHorizontalInset,
            cornerRadius: SettingsCardLayout.cardCornerRadius,
            content: content
        )
    }

    func openSourceLicensesSettings() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Source Licenses")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Review the third-party components and license notices included in the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, SettingsCardLayout.titleLeading)
                .padding(.top, 6)

                ForEach(openSourceLicenseNotices) { notice in
                    SettingsSectionCardView(
                        innerHorizontalInset: SettingsCardLayout.cardInnerHorizontalInset,
                        innerVerticalInset: SettingsCardLayout.cardInnerVerticalInset,
                        outerHorizontalInset: SettingsCardLayout.cardOuterHorizontalInset,
                        cornerRadius: SettingsCardLayout.cardCornerRadius
                    ) {

                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notice.packageName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)

                                Text(notice.subtitleText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            aboutTextBlock(
                                title: "Repository URL",
                                value: notice.repositoryURL,
                                accessibilityIdentifier:
                                    "settings.about.opensource.\(notice.accessibilitySlug).repository"
                            )

                            aboutTextBlock(
                                title: "Copyright Notice",
                                value: notice.copyrightNotice,
                                accessibilityIdentifier:
                                    "settings.about.opensource.\(notice.accessibilitySlug).copyright"
                            )

                            aboutTextBlock(
                                title: "License Text",
                                value: notice.licenseText,
                                shouldUseMonospacedFont: true,
                                accessibilityIdentifier: "settings.about.opensource.\(notice.accessibilitySlug).license"
                            )
                        }
                        .accessibilityIdentifier("settings.about.opensource.\(notice.accessibilitySlug).card")
                    }
                }
            }
            .frame(maxWidth: SettingsCardLayout.sectionMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 14)
            .accessibilityIdentifier("settings.about.opensource.page")
        }
    }

    func accessProtectionSettings() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Access Protection")
                        .accessibilityIdentifier("settings.accessProtection.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("When this is on, opening Settings requires a 6-digit PIN.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, SettingsCardLayout.titleLeading)
                .padding(.top, 6)

                SettingsSectionCardView(
                    innerHorizontalInset: SettingsCardLayout.cardInnerHorizontalInset,
                    innerVerticalInset: SettingsCardLayout.cardInnerVerticalInset,
                    outerHorizontalInset: SettingsCardLayout.cardOuterHorizontalInset,
                    cornerRadius: SettingsCardLayout.cardCornerRadius
                ) {
                    if accessProtectionVM.isEnabled && accessProtectionVM.isRecoveryNeeded {
                        Text("Status: Error")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)

                        Text(
                            "Access Protection is on, but the PIN data is missing. Reset it first, then set a new PIN."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Button("Reset Access Protection", role: .destructive) {
                            resetAccessProtectionForRecovery()
                        }
                        .appButtonRole(.primary)
                        .accessibilityIdentifier("settings.pin.resetProtection.button")
                    } else if accessProtectionVM.isEnabled {
                        Text("Status: On")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Turn Off Access Protection")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            pinEntryButton(
                                title: "Enter Current PIN",
                                value: disablePin,
                                target: .disablePin
                            )

                            Button("Turn Off Access Protection", role: .destructive) {
                                disableAccessProtection()
                            }
                            .appButtonRole(.secondary)
                            .disabled(disablePin.count != 6)
                            .accessibilityIdentifier("settings.pin.disable.button")
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Change PIN")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            pinEntryButton(
                                title: "Current PIN",
                                value: currentPinForChange,
                                target: .currentPinForChange
                            )

                            pinEntryButton(
                                title: "New PIN (6 digits)",
                                value: newPin,
                                target: .newPin
                            )

                            pinEntryButton(
                                title: "Confirm New PIN",
                                value: newPinConfirm,
                                target: .newPinConfirm
                            )

                            Button("Save New PIN") {
                                changeAccessProtectionPIN()
                            }
                            .appButtonRole(.primary)
                            .disabled(
                                currentPinForChange.count != 6 || newPin.count != 6 || newPinConfirm.count != 6
                            )
                            .accessibilityIdentifier("settings.pin.change.button")
                        }
                    } else {
                        Text("Status: Off")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        pinEntryButton(
                            title: "Set PIN (6 digits)",
                            value: enablePin,
                            target: .enablePin
                        )

                        pinEntryButton(
                            title: "Confirm PIN",
                            value: enablePinConfirm,
                            target: .enablePinConfirm
                        )

                        Button("Turn On Access Protection") {
                            enableAccessProtection()
                        }
                        .appButtonRole(.primary)
                        .disabled(enablePin.count != 6 || enablePinConfirm.count != 6)
                        .accessibilityIdentifier("settings.pin.enable.button")
                    }

                    if !accessProtectionStatusMessage.isEmpty {
                        Text(LocalizedStringKey(accessProtectionStatusMessage))
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }

                    if !accessProtectionErrorMessage.isEmpty {
                        Text(LocalizedStringKey(accessProtectionErrorMessage))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: SettingsCardLayout.sectionMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 14)
        }
    }

    func pinEntryButton(
        title: String,
        value: String,
        target: AccessPinInputTarget
    ) -> some View {
        Button {
            openPinInput(target)
        } label: {
            HStack {
                Text(LocalizedStringKey(title))
                    .foregroundStyle(.primary)

                Spacer()

                if value.isEmpty {

                    Text(String(localized: "Tap to enter"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(repeating: "●", count: value.count))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PlatformCompat.secondarySystemBackground)
            )
        }
        .appButtonRole(.ghost)
        .accessibilityIdentifier(pinInputAccessibilityID(target))
    }

    func cacheRow(title: String, value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    func aboutSectionHeader(title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            if let subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func aboutInfoRow(
        title: String,
        value: String,
        accessibilityIdentifier: String
    ) -> some View {
        // At large text sizes, fall back from one horizontal row to two stacked rows.

        ViewThatFits {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    func aboutNavigationRow(
        title: String,
        subtitle: String
    ) -> some View {

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PlatformCompat.secondarySystemBackground)
        )
    }

    func aboutTextBlock(
        title: String,
        value: String,
        shouldUseMonospacedFont: Bool = false,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(
                    shouldUseMonospacedFont
                        ? .footnote.monospaced()
                        : .footnote
                )
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PlatformCompat.secondarySystemBackground)
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
