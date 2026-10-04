import SwiftUI

private enum PrivacyLanguageFocusTiming {
    static let appearanceDelaySeconds: TimeInterval = 0.16
    static let selectionChangeDelaySeconds: TimeInterval = 0.05
}

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

    var aboutSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "App Information",
            title: "About",
            description: "View the current version, runtime environment, and feedback guidance.",
            symbolName: "sparkles.tv.fill",
            accent: Color.indigo,
            secondaryAccent: Color.cyan,
            summary: aboutHeroSummary
        ) {
            TVSettingsCard {
                TVSettingsStaticFocusSection(
                    accessibilityLabel: "App Information",
                    accessibilityIdentifier: "settings.about.appInfo.section",
                    focusedTarget: $focusedAboutSection,
                    target: .appInfo
                ) {
                    TVSettingsSectionBlock(
                        title: "App Information",
                        subtitle: "Use this to confirm the current version and runtime environment."
                    ) {
                        TVSettingsReadOnlyRow(
                            title: "App Name",
                            value: aboutAppDisplayName,
                            accessibilityIdentifier: "settings.about.appName.row"
                        )
                        TVSettingsReadOnlyRow(
                            title: "Version",
                            value: aboutVersionAndBuildText,
                            accessibilityIdentifier: "settings.about.version.row"
                        )
                        TVSettingsReadOnlyRow(
                            title: "Platform",
                            value: aboutPlatformLabel,
                            accessibilityIdentifier: "settings.about.platform.row"
                        )
                    }
                }

                Divider()

                TVSettingsStaticFocusSection(
                    accessibilityLabel: "Unofficial Notice",
                    accessibilityIdentifier: "settings.about.unofficialNotice.section",
                    focusedTarget: $focusedAboutSection,
                    target: .unofficialNotice
                ) {
                    TVSettingsSectionBlock(
                        title: "Unofficial Notice",
                        subtitle: "Explains this app's relationship with the official Immich project."
                    ) {

                        TVSettingsStatusBanner(
                            text:
                                "immichSlides is an independently developed unofficial app. It is not the official Immich app and is not endorsed, sponsored, or approved by Immich.",
                            tint: .orange,
                            accessibilityIdentifier: "settings.about.unofficialNotice.hint"
                        )
                    }
                }

                Divider()

                TVSettingsStaticFocusSection(
                    accessibilityLabel: "Feedback & Support",
                    accessibilityIdentifier: "settings.about.feedback.section",
                    focusedTarget: $focusedAboutSection,
                    target: .feedback
                ) {
                    TVSettingsSectionBlock(
                        title: "Feedback & Support",

                        subtitle: "Before reporting an issue, confirm the version and platform first."
                    ) {
                        // On tvOS, show the support email read-only; don't open mailto.

                        TVSettingsReadOnlyRow(
                            title: "Support Email",
                            value: SettingsSupportReference.emailAddress,
                            accessibilityIdentifier: "settings.about.feedback.email"
                        )

                        TVSettingsStatusBanner(
                            text: "To report an issue, note the version number and steps to reproduce.",
                            tint: .secondary,
                            accessibilityIdentifier: "settings.about.feedback.hint"
                        )
                    }
                }

                Divider()

                TVSettingsSectionBlock(
                    title: "Privacy & Protection",
                    subtitle: SettingsPrivacyPolicyReference.sectionSubtitle
                ) {
                    // Apple TV has no reliable system browser, so the privacy policy is read inside the app.

                    TVSettingsFocusableNavigationControl(
                        accessibilityLabel: SettingsPrivacyPolicyReference.entryTitle,
                        accessibilityValue: SettingsPrivacyPolicyReference.displayHost,
                        accessibilityIdentifier: "settings.about.privacyPolicy.link",
                        destination: {
                            screenContainer {
                                privacyPolicySettingsView
                            }
                            .toolbar(.hidden, for: .navigationBar)
                        }
                    ) {
                        TVSettingsActionRowLabel(
                            title: SettingsPrivacyPolicyReference.entryTitle,
                            value: SettingsPrivacyPolicyReference.displayHost,
                            valueTint: .secondary,
                            isEnabled: true
                        )
                    }
                    .focused($focusedAboutSection, equals: .privacyPolicy)
                }

                Divider()

                TVSettingsSectionBlock(
                    title: "Open Source Licenses",
                    subtitle: "Review the third-party components and license notices included in the app."
                ) {

                    TVSettingsFocusableNavigationControl(
                        accessibilityLabel: "Open Source Licenses",
                        accessibilityValue: String(openSourceLicenseNotices.count),
                        accessibilityIdentifier: "settings.about.opensource.link",
                        destination: {
                            screenContainer {
                                openSourceLicensesSettingsView
                            }
                            .toolbar(.hidden, for: .navigationBar)
                        }
                    ) {
                        TVSettingsActionRowLabel(
                            title: "Open Source Licenses",
                            value: String(openSourceLicenseNotices.count),
                            valueTint: .secondary,
                            isEnabled: true
                        )
                    }
                    .focused($focusedAboutSection, equals: .openSource)
                }
            }
            // The About page has its own focus scope and defaults to app
            // info, so the read-only page always has an initial focus.

            .appTVFocusScope(
                aboutFocusScope,
                focused: $focusedAboutSection,
                default: .appInfo,
                priority: .userInitiated
            )
            // About cards form their own focus section; up/down movement follows the module order.

            .appTVFocusSection()
        }
        .onAppear {
            // On first entry to About, focus starts at the top;
            // returning from open-source licenses doesn't force a reset.

            if focusedAboutSection == nil {
                focusedAboutSection = .appInfo
            }
        }
    }

    var privacyPolicySettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Compliance & Notices",
            title: SettingsPrivacyPolicyReference.entryTitle,
            description: SettingsPrivacyPolicyReference.sectionSubtitle,
            symbolName: "lock.shield.fill",
            accent: Color.teal,
            secondaryAccent: Color.cyan,
            summary: privacyPolicyHeroSummary
        ) {
            TVSettingsCard {
                if let privacyPolicyDocument {
                    let selectedSections = privacyPolicyDocument.sections(for: selectedPrivacyPolicyLanguage)

                    privacyPolicyLanguageSelectorView

                    ForEach(Array(selectedSections.enumerated()), id: \.element.id) { index, section in
                        Divider()

                        TVSettingsStaticFocusSection(
                            accessibilityLabel: section.title,
                            accessibilityIdentifier: "settings.about.privacyPolicy.section.\(index)",
                            focusedTarget: $focusedPrivacyPolicySection,
                            target: .section(index)
                        ) {
                            // Split the policy's ### subsections into body blocks that can be focused one at a time.

                            tvPrivacyPolicySectionBlock(
                                section: section,
                                sectionIndex: index,
                                accessibilityIdentifier: "settings.about.privacyPolicy.section.\(index).text"
                            )
                        }
                        .appTVOnMoveCommand { direction in
                            handlePrivacyPolicySectionMove(
                                direction,
                                sectionIndex: index,
                                sectionCount: selectedSections.count
                            )
                        }
                    }
                } else {

                    TVSettingsFocusableControl(
                        accessibilityLabel: SettingsPrivacyPolicyReference.entryTitle,
                        accessibilityIdentifier: "settings.about.privacyPolicy.summary",
                        action: {}
                    ) {
                        tvSettingsTextBlock(
                            title: SettingsPrivacyPolicyReference.entryTitle,
                            value: SettingsPrivacyPolicyReference.urlString,
                            accessibilityIdentifier: "settings.about.privacyPolicy.summary.text"
                        )
                    }
                    .focused($focusedPrivacyPolicySection, equals: .summary)
                }
            }
            .appTVFocusScope(
                privacyPolicyFocusScope,
                focused: $focusedPrivacyPolicySection,
                default: .language(selectedPrivacyPolicyLanguage),
                priority: .userInitiated
            )
            .appTVFocusSection()
        }
        .onAppear {
            let initialLanguage: SettingsBundledPrivacyPolicy.Language
            if hasInitializedPrivacyPolicyLanguage {
                initialLanguage = selectedPrivacyPolicyLanguage
            } else {
                // When opening the privacy page, recompute the default language from the current
                // system language, so it doesn't stay in Chinese if it was created too early.

                let currentDefaultLanguage = SettingsBundledPrivacyPolicy.Language.defaultForCurrentAppLocalization
                selectedPrivacyPolicyLanguage = currentDefaultLanguage
                hasInitializedPrivacyPolicyLanguage = true
                initialLanguage = currentDefaultLanguage
            }

            // After the push, set the default focus on the next main-thread
            // turn, since layout isn't finished in the same turn.

            DispatchQueue.main.async {
                if privacyPolicyDocument == nil {
                    focusedPrivacyPolicySection = .summary
                } else {
                    focusedPrivacyPolicySection = .language(initialLanguage)
                }
            }
        }
    }

    var openSourceLicensesSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Compliance & Notices",
            title: "Open Source Licenses",
            description: "Review the third-party components and license notices included in the app.",
            symbolName: "doc.text.fill",
            accent: Color.indigo,
            secondaryAccent: Color.cyan,
            summary: aboutOpenSourceLicenseSummary
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Open Source Components"
                ) {
                    VStack(spacing: 18) {
                        ForEach(Array(openSourceLicenseNoticeRows.enumerated()), id: \.offset) { _, rowNotices in
                            HStack(alignment: .top, spacing: 18) {
                                ForEach(rowNotices) { notice in
                                    openSourceLicenseSummaryBlock(for: notice)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                if rowNotices.count < openSourceLicenseGridColumnCount {
                                    ForEach(0..<(openSourceLicenseGridColumnCount - rowNotices.count), id: \.self) {
                                        _ in
                                        Color.clear
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()

                // When both dependencies share MIT, show the license text only once.

                if let sharedLicenseText = openSourceSharedLicenseText {
                    TVSettingsSectionBlock(
                        title: "License Text"
                    ) {
                        tvSettingsTextBlock(
                            title: SettingsOpenSourceLicenseNotice.licenseName,
                            value: sharedLicenseText,
                            usesMonospacedFont: true,
                            accessibilityIdentifier: "settings.about.opensource.sharedLicense"
                        )
                    }
                } else {
                    TVSettingsSectionBlock(
                        title: "License Text"
                    ) {
                        VStack(spacing: 14) {
                            ForEach(openSourceLicenseNotices) { notice in
                                tvSettingsTextBlock(
                                    title: notice.packageName,
                                    value: notice.licenseText,
                                    usesMonospacedFont: true,
                                    accessibilityIdentifier:
                                        "settings.about.opensource.\(notice.accessibilitySlug).license"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    func openSourceLicenseSummaryBlock(
        for notice: SettingsOpenSourceLicenseNotice
    ) -> some View {
        // The open-source license block only shows information and doesn't open another page.

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: notice.packageName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: notice.subtitleText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey("Repository URL"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(verbatim: notice.repositoryURL)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey("Copyright Notice"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(verbatim: notice.copyrightNotice)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PlatformCompat.secondarySystemBackground)
        )
        .accessibilityIdentifier("settings.about.opensource.\(notice.accessibilitySlug).summary")
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

    var aboutMetadata: SettingsAboutMetadata {

        SettingsAboutMetadata.current(platformName: "tvOS")
    }

    var aboutHeroSummary: String {
        aboutMetadata.heroSummary
    }

    var aboutAppDisplayName: String {
        aboutMetadata.appDisplayName
    }

    var aboutVersionAndBuildText: String {
        aboutMetadata.versionAndBuildText
    }

    var aboutPlatformLabel: String {
        aboutMetadata.platformLabel
    }

    var openSourceLicenseNotices: [SettingsOpenSourceLicenseNotice] {
        SettingsOpenSourceLicenseNotice.currentCatalog
    }

    var aboutOpenSourceLicenseSummary: String {
        SettingsOpenSourceLicenseNotice.packageSummaryText
    }

    var privacyPolicyDocument: SettingsBundledPrivacyPolicyDocument? {
        SettingsBundledPrivacyPolicy.localizedDocument()
    }

    var privacyPolicyHeroSummary: String {
        let lastUpdatedLine =
            privacyPolicyDocument?.lastUpdatedLine.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if lastUpdatedLine.isEmpty == false {
            return localizedPrivacyPolicyLastUpdatedSummary(
                from: lastUpdatedLine,
                language: selectedPrivacyPolicyLanguage
            )
        }

        return SettingsPrivacyPolicyReference.displayHost
    }

    func localizedPrivacyPolicyLastUpdatedSummary(
        from lastUpdatedLine: String,
        language: SettingsBundledPrivacyPolicy.Language
    ) -> String {
        // Take only the date after the colon from the date line, so the English
        // page header doesn't still show the original Chinese/English text.

        let trimmedLine = lastUpdatedLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateText =
            trimmedLine
            .components(separatedBy: ":")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let labelParts = trimmedLine.components(separatedBy: "/")
        let chineseLabel =
            labelParts
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let englishLabel =
            labelParts
            .dropFirst()
            .joined(separator: "/")
            .components(separatedBy: ":")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard dateText.isEmpty == false else {
            return trimmedLine
        }

        switch language {
        case .chinese:
            guard chineseLabel.isEmpty == false else {
                return trimmedLine
            }
            return "\(chineseLabel)：\(dateText)"
        case .english:
            guard englishLabel.isEmpty == false else {
                return trimmedLine
            }
            return "\(englishLabel): \(dateText)"
        }
    }

    var privacyPolicyLanguageSelectorView: some View {
        TVSettingsSectionBlock(
            title: "Reading Language",
            subtitle: "Choose which policy language to show on this page."
        ) {
            // The privacy page is read in sections per language, so
            // focus isn't hard to move through an overly long page.

            HStack(spacing: 16) {
                ForEach(SettingsBundledPrivacyPolicy.Language.allCases) { language in
                    TVSettingsFocusedChoiceButton(
                        title: language.displayTitle,
                        isSelected: selectedPrivacyPolicyLanguage == language,
                        accessibilityIdentifier:
                            "settings.about.privacyPolicy.language.\(language.accessibilitySlug).button",
                        focusedTarget: $focusedPrivacyPolicySection,
                        target: .language(language),
                        action: {
                            selectPrivacyPolicyLanguage(language)
                        }
                    )
                    .appTVOnMoveCommand { direction in
                        handlePrivacyPolicyLanguageMove(direction, from: language)
                    }
                }
            }
        }
    }

    func handlePrivacyPolicyLanguageMove(
        _ direction: AppMoveDirection,
        from language: SettingsBundledPrivacyPolicy.Language
    ) {
        let target: PrivacyPolicyFocusTarget?

        switch (language, direction) {
        case (.chinese, .right):
            target = .language(.english)
        case (.english, .left):
            target = .language(.chinese)
        case (_, .up):
            target = .summary
        case (_, .down):
            target = .section(0)
        default:
            target = nil
        }

        guard let target else { return }

        // Left/right only moves focus; Select switches the language.

        DispatchQueue.main.async {
            focusedPrivacyPolicySection = target
        }
    }

    func handlePrivacyPolicySectionMove(
        _ direction: AppMoveDirection,
        sectionIndex: Int,
        sectionCount: Int
    ) {
        let target: PrivacyPolicyFocusTarget?

        switch direction {
        case .up where sectionIndex == 0:
            target = .language(selectedPrivacyPolicyLanguage)
        case .up:
            target = .section(max(sectionIndex - 1, 0))
        case .down where sectionIndex + 1 < sectionCount:
            target = .section(sectionIndex + 1)
        default:
            target = nil
        }

        guard let target else { return }

        // After switching language, move focus by array index instead
        // of letting the system guess the previous/next section.

        DispatchQueue.main.async {
            focusedPrivacyPolicySection = target
        }
    }

    func selectPrivacyPolicyLanguage(_ language: SettingsBundledPrivacyPolicy.Language) {
        selectedPrivacyPolicyLanguage = language

        // After switching language, keep focus on the language button just
        // pressed, so it doesn't stay on a section that has disappeared.

        focusedPrivacyPolicySection = .language(language)
    }

    func tvPrivacyPolicySectionBlock(
        section: SettingsBundledPrivacyPolicyDocument.Section,
        sectionIndex: Int,
        accessibilityIdentifier: String
    ) -> some View {
        // Render policy body tables/lists as blocks, instead of a single Text that shows raw Markdown markup.

        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: section.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(section.blocks.enumerated()), id: \.offset) { blockIndex, block in
                tvPrivacyPolicyContentBlock(
                    block,
                    sectionIndex: sectionIndex,
                    blockIndex: blockIndex
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 980, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PlatformCompat.secondarySystemBackground)
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    func tvPrivacyPolicyContentBlock(
        _ block: SettingsBundledPrivacyPolicyDocument.ContentBlock,
        sectionIndex: Int,
        blockIndex: Int
    ) -> some View {
        switch block {
        case .paragraph(let text):
            Text(verbatim: text)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            TVPrivacyPolicyBulletListView(items: items)

        case .table(let table):
            TVPrivacyPolicyTableView(
                table: table,
                accessibilityIdentifier:
                    "settings.about.privacyPolicy.section.\(sectionIndex).block.\(blockIndex).table"
            )
        }
    }

    var openSourceLicenseNoticeRows: [[SettingsOpenSourceLicenseNotice]] {
        stride(from: 0, to: openSourceLicenseNotices.count, by: openSourceLicenseGridColumnCount).map { startIndex in
            let endIndex = min(startIndex + openSourceLicenseGridColumnCount, openSourceLicenseNotices.count)
            return Array(openSourceLicenseNotices[startIndex..<endIndex])
        }
    }

    var openSourceLicenseGridColumnCount: Int {
        2
    }

    // The tvOS page can't access the SettingsView helper, so it checks locally whether the license text is shared.

    var openSourceSharedLicenseText: String? {
        let uniqueLicenseTexts = Set(openSourceLicenseNotices.map(\.licenseText))

        guard uniqueLicenseTexts.count == 1 else {
            return nil
        }

        return openSourceLicenseNotices.first?.licenseText
    }

    func tvSettingsTextBlock(
        title: String,
        value: String,
        usesMonospacedFont: Bool = false,
        accessibilityIdentifier: String
    ) -> some View {
        // Long license text doesn't use the short-value capsule row on the right.

        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(
                    usesMonospacedFont
                        ? .system(size: 15, weight: .regular, design: .monospaced)
                        : .system(size: 18, weight: .regular)
                )
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        // Center legal text and widen the reading width, to avoid an overly narrow column with empty margins.

        .frame(maxWidth: 980, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PlatformCompat.secondarySystemBackground)
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    func formatBytes(_ bytes: UInt) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

private struct TVPrivacyPolicyBulletListView: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(Color.teal.opacity(0.82))
                        .frame(width: 7, height: 7)
                        .padding(.top, 8)

                    Text(verbatim: item)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct TVPrivacyPolicyTableView: View {
    let table: SettingsBundledPrivacyPolicyDocument.Table
    let accessibilityIdentifier: String

    var body: some View {
        // Render each Markdown table row as a small card, since narrow columns are hard to read.

        VStack(alignment: .leading, spacing: 14) {
            ForEach(table.rows) { row in
                TVPrivacyPolicyTableRowView(headers: table.headers, row: row)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct TVPrivacyPolicyTableRowView: View {
    @Environment(\.colorScheme) private var colorScheme

    let headers: [String]
    let row: SettingsBundledPrivacyPolicyDocument.Table.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = row.cells.first, title.isEmpty == false {
                Text(verbatim: title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(detailItems) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text(verbatim: item.value)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(rowBorderColor, lineWidth: 1)
        )
    }

    private var detailItems: [TVPrivacyPolicyTableDetailItem] {
        row.cells.indices.dropFirst().compactMap { index in
            guard index < headers.count else {
                return nil
            }

            let value = row.cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty == false else {
                return nil
            }

            return TVPrivacyPolicyTableDetailItem(
                id: "\(index)-\(headers[index])",
                title: headers[index],
                value: value
            )
        }
    }

    private var rowBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.035)
    }

    private var rowBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.07)
    }
}

private struct TVPrivacyPolicyTableDetailItem: Identifiable {
    let id: String
    let title: String
    let value: String
}

// Read-only About modules also take focus; otherwise the remote can't scroll the long page down.

private struct TVSettingsStaticFocusSection<FocusTarget: Hashable, Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocusBindingFocused: Bool

    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let focusedTarget: FocusState<FocusTarget?>.Binding
    let target: FocusTarget
    @ViewBuilder let content: Content

    init(
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        focusedTarget: FocusState<FocusTarget?>.Binding,
        target: FocusTarget,
        @ViewBuilder content: () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.focusedTarget = focusedTarget
        self.target = target
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Read-only blocks use a transparent focus layer to drive scrolling,
            // which is more reliable than making the whole block focusable.

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .focusable(true, interactions: .activate)
                .focused($isFocusBindingFocused)
                .focused(focusedTarget, equals: target)
                .appTVDisableDefaultFocusEffect()
                .onTapGesture {
                    // Read-only focus blocks only drive scrolling; Select doesn't open another page.

                }
                .accessibilityLabel(Text(LocalizedStringKey(accessibilityLabel)))
                .accessibilityValue(accessibilityValueText)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(borderColor, lineWidth: hasVisualFocus ? 3 : 1)
        )
        .overlay {
            if hasVisualFocus {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .inset(by: 5)
                    .strokeBorder(innerFocusBorderColor, lineWidth: 1.2)
            }
        }
        .shadow(color: focusShadowColor, radius: hasVisualFocus ? 14 : 0, x: 0, y: 0)
        .scaleEffect(hasVisualFocus ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.16), value: hasVisualFocus)
    }

    private var hasVisualFocus: Bool {
        isFocused || isFocusBindingFocused
    }

    private var backgroundColor: Color {
        guard hasVisualFocus else { return .clear }

        return colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    private var borderColor: Color {
        guard hasVisualFocus else { return .clear }

        return colorScheme == .dark
            ? Color(red: 0.35, green: 0.78, blue: 1.0).opacity(0.80)
            : Color.blue.opacity(0.58)
    }

    private var innerFocusBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.30)
            : Color.white.opacity(0.78)
    }

    private var focusShadowColor: Color {
        colorScheme == .dark
            ? Color(red: 0.35, green: 0.78, blue: 1.0).opacity(0.18)
            : Color.blue.opacity(0.12)
    }

    private var shouldExposeUITestFocusMarker: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_RESET_STATE"] == "1"
    }

    private var accessibilityValueText: Text {
        guard shouldExposeUITestFocusMarker else {
            return Text(verbatim: "")
        }

        return Text(verbatim: hasVisualFocus ? "focused" : "")
    }
}

// On complex pages, bind focused inside the choice button, since an outer .focused is unreliable.

private struct TVSettingsFocusedChoiceButton<FocusTarget: Hashable>: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocusBindingFocused: Bool

    let title: String
    let isSelected: Bool
    let accessibilityIdentifier: String
    let focusedTarget: FocusState<FocusTarget?>.Binding
    let target: FocusTarget
    let action: () -> Void

    var body: some View {
        TVSettingsChoiceButtonLabel(
            title: title,
            isSelected: isSelected,
            isFocusedOverride: hasVisualFocus
        )
        .contentShape(Rectangle())
        .focusable(true, interactions: .activate)
        .focused($isFocusBindingFocused)
        .focused(focusedTarget, equals: target)
        .appTVDisableDefaultFocusEffect()
        .shadow(color: focusHaloColor, radius: hasVisualFocus ? 18 : 0, x: 0, y: 0)
        .scaleEffect(hasVisualFocus ? 1.025 : 1.0)
        .animation(.easeInOut(duration: 0.16), value: hasVisualFocus)
        .onTapGesture {
            action()
        }
        .onAppear {
            requestFocusIfSelected(after: PrivacyLanguageFocusTiming.appearanceDelaySeconds)
        }
        .onChange(of: isSelected) { _, newValue in
            guard newValue else { return }
            requestFocusIfSelected(after: PrivacyLanguageFocusTiming.selectionChangeDelaySeconds)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityValue(accessibilityValueText)
        .accessibilityAddTraits(.isButton)
        .accessibilityRespondsToUserInteraction(true)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var hasVisualFocus: Bool {
        isFocused || isFocusBindingFocused
    }

    private func requestFocusIfSelected(after delay: TimeInterval) {
        guard isSelected else { return }

        // When a language button is selected, move focus to the current language
        // after a delay, instead of always landing on the leftmost button.

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            focusedTarget.wrappedValue = target
        }
    }

    private var focusHaloColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.88, blue: 0.30).opacity(0.32)
            : Color.orange.opacity(0.20)
    }

    private var shouldExposeUITestFocusMarker: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_RESET_STATE"] == "1"
    }

    private var accessibilityValueText: Text {
        let selectionState = isSelected ? String(localized: "Selected") : String(localized: "Not Selected")

        guard shouldExposeUITestFocusMarker else {
            return Text(verbatim: selectionState)
        }

        var parts: [String] = []
        if hasVisualFocus {
            parts.append("focused")
        }
        parts.append(selectionState)
        return Text(verbatim: parts.joined(separator: " | "))
    }
}
