import SwiftUI

struct SettingsViewTV: View {
    // The access protection subpage still uses this enum to manage focus.

    enum DetailFocusTarget: Hashable {
        case accessProtectionReset
        case accessProtectionDisablePin
        case accessProtectionEnablePin
    }

    // Focus targets for two-choice subpages; on custom-drawn buttons, the system's geometric focus sometimes stays put.

    enum PlaybackBinaryChoiceFocusTarget: Hashable {
        case primary
        case secondary
    }

    // The About page enumerates focus order by module, so the remote can scroll the long page down.

    enum AboutFocusTarget: Hashable {
        case appInfo
        case unofficialNotice
        case feedback
        case privacyPolicy
        case openSource
    }

    // Privacy policy page focus order: summary -> language buttons -> sections in the current language.

    enum PrivacyPolicyFocusTarget: Hashable {
        case summary
        case language(SettingsBundledPrivacyPolicy.Language)
        case section(Int)
    }

    @Environment(\.colorScheme) private var colorScheme

    @Binding var selectedSelection: SettingSelection?

    @Binding var serverURL: String
    @Binding var apiKey: String
    let isConnectionVerified: Bool
    let isTestingConnection: Bool
    let serverStatusMessage: String
    let serverErrorAlertTitle: String
    let serverErrorMessage: String
    @Binding var showServerErrorAlert: Bool
    let onTestConnection: () -> Void
    let onSaveServerConfig: () -> Void

    let playbackSettings: PlaybackSettings
    let filterSummaryText: String
    let isFilterSelectionEmpty: Bool
    let onToggleAutoPlay: () -> Void
    let onSelectInterval: (Double) -> Void
    let onSelectDefaultPlaybackMode: (DefaultPlaybackMode) -> Void
    let onSelectPlaybackDisplayMode: (PlaybackDisplayMode) -> Void
    let onOpenFilterEditor: () -> Void
    let onToggleShowExif: () -> Void
    let onToggleShowDebugOverlay: () -> Void
    @Binding var showFilterModeBlockedAlert: Bool
    let onCancelFilterModeBlockedAlert: () -> Void

    let accessProtectionEnabled: Bool
    let accessProtectionNeedsRecovery: Bool
    let enablePin: String
    let enablePinConfirm: String
    let disablePin: String
    let currentPinForChange: String
    let newPin: String
    let newPinConfirm: String
    let accessProtectionStatusMessage: String
    let accessProtectionErrorMessage: String
    let onOpenPinInput: (AccessPinInputTarget) -> Void
    let onResetProtection: () -> Void
    let onDisableProtection: () -> Void
    let onChangePIN: () -> Void
    let onEnableProtection: () -> Void

    let cacheSummary: AssetsDownloadManager.CacheSummary
    let cacheStatusMessage: String
    let isClearingCache: Bool
    @Binding var showClearDiskCacheAlert: Bool
    let onClearDiskCache: () -> Void
    let onConfirmClearDiskCache: () -> Void

    let settingsItemAccessibilityID: (SettingSelection) -> String
    let pinInputAccessibilityID: (AccessPinInputTarget) -> String

    @FocusState var focusedDetailItem: DetailFocusTarget?
    @FocusState var focusedPlaybackBinaryChoice: PlaybackBinaryChoiceFocusTarget?
    @FocusState var focusedPlaybackIntervalSeconds: Double?
    @FocusState var focusedAboutSection: AboutFocusTarget?
    @FocusState var focusedPrivacyPolicySection: PrivacyPolicyFocusTarget?
    @State var selectedPrivacyPolicyLanguage: SettingsBundledPrivacyPolicy.Language = .defaultForCurrentAppLocalization
    @State var hasInitializedPrivacyPolicyLanguage = false
    @Namespace var detailListFocusScope
    @Namespace var playbackBinaryChoiceFocusScope
    @Namespace var playbackIntervalFocusScope
    @Namespace var aboutFocusScope
    @Namespace var privacyPolicyFocusScope

    let intervalOptions: [Double] = [5, 8, 10, 15, 30]

    var body: some View {
        // The live path now uses a single column that leads into subpages,
        // so two columns don't steal geometric focus from each other.

        screenContainer {
            TVSettingsPageScaffold(
                eyebrow: "",
                title: "Settings",
                description: "Manage playback, access protection, server, and cache.",
                symbolName: "gearshape.2.fill",
                accent: Color.cyan,
                secondaryAccent: Color.blue,
                summary: ""
            ) {
                TVSettingsCard {
                    VStack(spacing: 16) {
                        ForEach(SettingSelection.allCases) { selection in
                            settingsEntryLink(for: selection)
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    func screenContainer<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { geometry in

            let horizontalPaddingLeading = max(80, geometry.safeAreaInsets.leading + 28)
            let horizontalPaddingTrailing = max(80, geometry.safeAreaInsets.trailing + 28)
            let verticalPaddingTop = max(60, geometry.safeAreaInsets.top + 10)
            let verticalPaddingBottom = max(60, geometry.safeAreaInsets.bottom + 10)

            ZStack {
                backgroundLayer

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        content()
                    }
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.leading, horizontalPaddingLeading)
                    .padding(.trailing, horizontalPaddingTrailing)
                    .padding(.top, verticalPaddingTop)
                    .padding(.bottom, verticalPaddingBottom)
                }
            }
        }
    }

    private func settingsEntryLink(for selection: SettingSelection) -> some View {
        // Home page entries draw their own focus instead of using the system
        // NavigationLink focus shell, to avoid a white edge overflowing.

        TVSettingsFocusableNavigationControl(
            accessibilityLabel: selection.title,
            accessibilityValue: settingsEntrySummary(for: selection),
            accessibilityIdentifier: settingsItemAccessibilityID(selection),
            onActivate: {
                // Sync selectedSelection before entering a subpage, so the
                // selected state is still consistent on return to the home page.

                selectedSelection = selection
            },
            destination: {
                settingsDestinationView(for: selection)
                    .onAppear {

                        selectedSelection = selection
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
        ) {
            TVSettingsNavigationRowLabel(
                title: selection.title,

                subtitle: settingsEntrySubtitle(for: selection),
                icon: selection.icon
            )
        }
    }

    @ViewBuilder
    private func settingsDestinationView(for selection: SettingSelection) -> some View {
        screenContainer {
            settingsPageContent(for: selection)
        }
    }

    @ViewBuilder
    private func settingsPageContent(for selection: SettingSelection) -> some View {
        switch selection {
        case .playback:
            playbackSettingsView
        case .accessProtection:
            accessProtectionSettingsView
        case .server:
            serverSettingsView
        case .cache:
            cacheSettingsView
        case .about:
            aboutSettingsView
        }
    }

    private func settingsEntrySummary(for selection: SettingSelection) -> String {
        switch selection {
        case .playback:
            return playbackHeroSummary
        case .accessProtection:
            return accessProtectionHeroSummary
        case .server:
            return serverHeroSummary
        case .cache:
            return cacheHeroSummary
        case .about:
            return aboutHeroSummary
        }
    }

    private func settingsEntrySubtitle(for selection: SettingSelection) -> String {

        switch selection {
        case .playback:
            return String(localized: "Autoplay, default mode, and display options")
        case .accessProtection:
            return String(localized: "Turn PIN protection on or off, change the PIN, or recover from errors")
        case .server:
            return String(localized: "Server URL, API Key, and connection verification")
        case .cache:
            return String(localized: "Cache usage, background tasks, and cleanup")
        case .about:
            return String(localized: "Version info, runtime environment, and feedback notes")
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: atmosphereGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(atmosphereGlowLeading)
                .frame(width: 520, height: 520)
                .blur(radius: 110)
                .offset(x: -380, y: -220)

            Circle()
                .fill(atmosphereGlowTrailing)
                .frame(width: 620, height: 620)
                .blur(radius: 140)
                .offset(x: 420, y: 180)

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.18),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.16 : 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Rectangle()
                .fill(.regularMaterial.opacity(colorScheme == .dark ? 0.20 : 0.38))
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black.opacity(0.22), location: 0.24),
                            .init(color: .black, location: 0.72),
                            .init(color: .black, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
        }
    }

    private var atmosphereGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.04, green: 0.05, blue: 0.09),
                Color(red: 0.06, green: 0.08, blue: 0.12),
                Color(red: 0.03, green: 0.04, blue: 0.07)
            ]
        }

        return [
            Color(red: 0.96, green: 0.98, blue: 1.00),
            Color(red: 0.92, green: 0.95, blue: 0.99),
            Color(red: 0.95, green: 0.95, blue: 0.99)
        ]
    }

    private var atmosphereGlowLeading: Color {
        colorScheme == .dark
            ? Color.cyan.opacity(0.14)
            : Color.cyan.opacity(0.10)
    }

    private var atmosphereGlowTrailing: Color {
        colorScheme == .dark
            ? Color.blue.opacity(0.12)
            : Color.indigo.opacity(0.08)
    }
}
