//
//  immichSlidesApp_iOS.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/6.
//

import SwiftUI

@main
struct ImmichSlidesApp: App {
    private let forcedColorScheme: ColorScheme?
    private let forcedDynamicTypeSize: DynamicTypeSize?

    init() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        let schemeValue = env["UI_TEST_COLOR_SCHEME"]?.lowercased()
        if schemeValue == "dark" {
            forcedColorScheme = .dark
        } else if schemeValue == "light" {
            forcedColorScheme = .light
        } else {
            forcedColorScheme = nil
        }

        forcedDynamicTypeSize = Self.uiTestDynamicTypeSize(from: env["UI_TEST_DYNAMIC_TYPE_SIZE"])

        if ProcessInfo.processInfo.environment["UI_TEST_RESET_STATE"] == "1" {
            ImmichServer.clearSavedConfiguration()
            FilterSelectionStore().clear()
            PlaybackSettingsStore().clear()
            PlaybackEntryHintStore().clear()
            AccessProtectionStore.shared.resetProtection()
            ImmichAPIService.shared.reloadServerConfiguration()
        }

        FilterSelectionStore().seedUITestSelectionIfRequested()

        let injectedServerURL =
            env["UI_TEST_SERVER_URL"] ?? env["IMMICH_TEST_SERVER_URL"] ?? env["IMMICH_TEST_URL"]
        let injectedAPIKey =
            env["UI_TEST_API_KEY"] ?? env["IMMICH_TEST_API_KEY"]
        if let injectedServerURL, let injectedAPIKey,
            !injectedServerURL.isEmpty, !injectedAPIKey.isEmpty
        {
            let server = ImmichServer(
                immichURL: ImmichServer.normalizeServerURL(injectedServerURL),
                immichApiKey: injectedAPIKey
            )
            server.save()
            ImmichAPIService.shared.reloadServerConfiguration()
        }

        if env["UI_TEST_FORCE_DEBUG_OVERLAY"] == "1" {
            var settings = PlaybackSettingsStore().load() ?? PlaybackSettings()
            settings.showDebugOverlay = true
            PlaybackSettingsStore().save(settings)
        }

        if env["UI_TEST_FORCE_AUTOPLAY_OFF"] == "1" {
            var settings = PlaybackSettingsStore().load() ?? PlaybackSettings()
            settings.autoPlayEnabled = false
            PlaybackSettingsStore().save(settings)
        }

        if let forcedDisplayMode = env["UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE"],
            let displayMode = PlaybackDisplayMode(rawValue: forcedDisplayMode)
        {
            var settings = PlaybackSettingsStore().load() ?? PlaybackSettings()
            settings.displayMode = displayMode
            PlaybackSettingsStore().save(settings)
        }
        #else
        // Release ignores UI_TEST_*; production builds never read these flags.

        forcedColorScheme = nil
        forcedDynamicTypeSize = nil
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if PlatformCompat.isHostingUnitTests {
                // Unit tests only need the process; a live ContentView would load and play the saved server.
                Color.clear
            } else {
                configuredRootView()
            }
        }
    }

    @ViewBuilder
    private func configuredRootView() -> some View {
        let rootView = ContentView()
            .preferredColorScheme(forcedColorScheme)

        if let forcedDynamicTypeSize {
            rootView.dynamicTypeSize(forcedDynamicTypeSize)
        } else {
            rootView
        }
    }

    private static func uiTestDynamicTypeSize(from rawValue: String?) -> DynamicTypeSize? {

        guard let rawValue else { return nil }

        switch rawValue.lowercased() {
        case "xsmall":
            return .xSmall
        case "small":
            return .small
        case "medium":
            return .medium
        case "large":
            return .large
        case "xlarge":
            return .xLarge
        case "xxlarge":
            return .xxLarge
        case "xxxlarge":
            return .xxxLarge
        case "accessibility1":
            return .accessibility1
        case "accessibility2":
            return .accessibility2
        case "accessibility3":
            return .accessibility3
        case "accessibility4":
            return .accessibility4
        case "accessibility5":
            return .accessibility5
        default:
            return nil
        }
    }
}
