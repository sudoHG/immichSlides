//
//  SettingsView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/7.
//

import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

@MainActor
final class SettingsPromptState: ObservableObject {
    // Prompts shared across detail pages use an ObservableObject, because after an iPhone push the parent's
    // @State alert would not receive them.

    @Published var showFilterModeBlockedAlert = false
    @Published var pendingSwitchToFilteredAfterConfig = false
    @Published var showClearDiskCacheAlert = false
}

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) var openURL

    @State private var selectedSelection: SettingSelection? = .playback

    // State is read by the +Sections/+Actions/+Helpers extensions, so it cannot be private.

    @StateObject var serverVM = SettingsServerViewModel()
    @StateObject var playbackVM = PlaybackSettingsViewModel()
    @StateObject var accessProtectionVM = AccessProtectionViewModel()
    // Not observed on purpose: see "Settings ignore download activity" in docs/ARCHITECTURE.md.
    let downloadManager = AssetsDownloadManager.shared
    @StateObject var filterVM = FilterViewModel()
    @StateObject var promptState = SettingsPromptState()

    @State var showFullScreenFilterEditor = false

    @State var enablePin = ""
    @State var enablePinConfirm = ""
    @State var disablePin = ""
    @State var currentPinForChange = ""
    @State var newPin = ""
    @State var newPinConfirm = ""
    @State var accessProtectionStatusMessage = ""
    @State var accessProtectionErrorMessage = ""
    @State var showAccessPinInputSheet = false
    @State var activePinInputTarget: AccessPinInputTarget?
    // Open-source licenses subpage: on iPhone this is the presented state, on iPad it is an open request.

    @State var isShowingOpenSourceLicenses = false

    @State var cacheSummary: AssetsDownloadManager.CacheSummary = .init(
        diskBytes: 0,
        trackedAssetURLCount: 0,
        trackedStateCount: 0,
        runningTaskCount: 0
    )
    @State var cacheStatusMessage = ""
    @State var isClearingCache = false

    var body: some View {
        platformContent
            .background(PlatformCompat.systemGroupedBackground)
            #if !os(tvOS)
        .navigationTitle("Settings")
            #endif
            .onAppear {

                serverVM.loadExistingServerConfigIfNeeded()
                #if os(tvOS)
                refreshCacheSummary()
                #endif
                enforcePlaybackModeInvariant()
            }
            .onChange(of: filterVM.selection.isEmpty) { _, isEmpty in

                if promptState.pendingSwitchToFilteredAfterConfig && !isEmpty {
                    promptState.pendingSwitchToFilteredAfterConfig = false
                    playbackVM.settings.defaultPlaybackMode = .filtered
                    return
                }

                enforcePlaybackModeInvariant()
            }
            .onChange(of: serverVM.serverURL) { _, _ in
                serverVM.invalidateVerification()
            }
            .onChange(of: serverVM.apiKey) { _, _ in
                serverVM.invalidateVerification()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    serverVM.resumePendingConnectionTestIfNeeded()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .serverConfigurationDidChange)) { _ in

                filterVM.resetForServerConfigurationChange()
            }
            .sheet(isPresented: $showAccessPinInputSheet) {
                PinEntrySheetView(
                    title: pinInputTitle,
                    message: String(localized: "Please enter a 6-digit PIN."),
                    errorMessage: nil,
                    onCancel: dismissPinInputSheet,
                    onSubmit: { pin in
                        applyPinInput(pin)
                        dismissPinInputSheet()
                    }
                )
            }
            .fullScreenCover(
                isPresented: $showFullScreenFilterEditor,
                onDismiss: { enforcePlaybackModeInvariant() }
            ) {
                NavigationStack {
                    FilterView(
                        viewModel: filterVM,
                        showsStartPlaybackButton: false,
                        onDismissRequested: {
                            showFullScreenFilterEditor = false
                        }
                    )
                    #if !os(tvOS)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showFullScreenFilterEditor = false
                            }
                            .accessibilityIdentifier("filter.editor.done.button")
                        }
                    }
                    #endif
                }
            }
    }

    @ViewBuilder
    private var platformContent: some View {
        #if os(tvOS)
        SettingsViewTV(
            selectedSelection: $selectedSelection,
            serverURL: $serverVM.serverURL,
            apiKey: $serverVM.apiKey,
            isConnectionVerified: serverVM.isConnectionVerified,
            isTestingConnection: serverVM.isTestingConnection,
            serverStatusMessage: serverVM.statusMessage,
            serverErrorAlertTitle: serverVM.errorAlertTitle,
            serverErrorMessage: serverVM.errorMessage,
            showServerErrorAlert: $serverVM.showErrorAlert,
            onTestConnection: testServerConnection,
            onSaveServerConfig: saveServerConfiguration,
            // Pass the same filterVM so the summary and the editor work on the same filter state.

            filterViewModel: filterVM,
            playbackSettings: playbackVM.settings,
            filterSummaryText: filterSummaryText,
            isFilterSelectionEmpty: filterVM.selection.isEmpty,
            onToggleAutoPlay: toggleAutoPlay,
            onSelectInterval: selectPlaybackInterval,
            onSelectDefaultPlaybackMode: selectDefaultPlaybackMode,
            onSelectPlaybackDisplayMode: selectPlaybackDisplayMode,
            onOpenFilterEditor: openFilterEditor,
            onToggleShowExif: toggleShowExif,
            onToggleShowDebugOverlay: toggleShowDebugOverlay,
            showFilterModeBlockedAlert: filterModeBlockedAlertBinding,
            onCancelFilterModeBlockedAlert: cancelFilterModeBlockedAlert,
            accessProtectionEnabled: accessProtectionVM.isEnabled,
            accessProtectionNeedsRecovery: accessProtectionVM.needsRecovery,
            enablePin: enablePin,
            enablePinConfirm: enablePinConfirm,
            disablePin: disablePin,
            currentPinForChange: currentPinForChange,
            newPin: newPin,
            newPinConfirm: newPinConfirm,
            accessProtectionStatusMessage: accessProtectionStatusMessage,
            accessProtectionErrorMessage: accessProtectionErrorMessage,
            onOpenPinInput: openPinInput,
            onResetProtection: resetAccessProtectionForRecovery,
            onDisableProtection: disableAccessProtection,
            onChangePIN: changeAccessProtectionPIN,
            onEnableProtection: enableAccessProtection,
            cacheSummary: cacheSummary,
            cacheStatusMessage: cacheStatusMessage,
            isClearingCache: isClearingCache,
            showClearDiskCacheAlert: clearDiskCacheAlertBinding,
            onClearDiskCache: requestClearDiskCache,
            onConfirmClearDiskCache: confirmClearDiskCache,
            settingsItemAccessibilityID: settingsItemAccessibilityID,
            pinInputAccessibilityID: pinInputAccessibilityID
        )
        // The tvOS settings root reads the cache size too; iOS refreshes it on the cache page only.
        .onReceive(downloadManager.activeTaskCountChanges) { _ in
            refreshCacheSummary()
        }
        #else
        SettingsViewIOS(
            isPhoneLayout: isPhoneLayout,
            selectedSelection: $selectedSelection,
            isShowingOpenSourceLicenses: $isShowingOpenSourceLicenses,
            detailView: { selection in
                AnyView(settingsDetail(selection))
            },
            openSourceLicensesView: {
                AnyView(
                    openSourceLicensesSettings()
                        .navigationTitle("Open Source Licenses")
                        .appNavigationBarTitleDisplayModeInline()
                )
            },
            settingsItemAccessibilityID: settingsItemAccessibilityID
        )
        #endif
    }

    private var isPhoneLayout: Bool {
        #if os(iOS)
        // Detect iPhone via userInterfaceIdiom so sizeClass flicker does not rebuild the navigation stack.

        UIDevice.current.userInterfaceIdiom == .phone
        #else
        horizontalSizeClass == .compact
        #endif
    }

    var filterModeBlockedAlertBinding: Binding<Bool> {
        Binding(
            get: { promptState.showFilterModeBlockedAlert },
            set: { promptState.showFilterModeBlockedAlert = $0 }
        )
    }

    var clearDiskCacheAlertBinding: Binding<Bool> {
        Binding(
            get: { promptState.showClearDiskCacheAlert },
            set: { promptState.showClearDiskCacheAlert = $0 }
        )
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
