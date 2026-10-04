import SwiftUI

extension SettingsViewTV {
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
                aboutAppInformationSection

                Divider()

                aboutUnofficialNoticeSection

                Divider()

                aboutFeedbackSection

                Divider()

                aboutPrivacySection

                Divider()

                aboutOpenSourceSection
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

    private var aboutAppInformationSection: some View {
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
    }

    private var aboutUnofficialNoticeSection: some View {
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
    }

    private var aboutFeedbackSection: some View {
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
    }

    private var aboutPrivacySection: some View {
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
    }

    private var aboutOpenSourceSection: some View {
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
}
