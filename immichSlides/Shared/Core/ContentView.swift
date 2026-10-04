//
//  ContentView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/7.
//

import SwiftUI

enum AppButtonRole {
    case primary
    case secondary
    case ghost
}

private struct AppButtonRoleModifier: ViewModifier {
    let role: AppButtonRole

    @ViewBuilder
    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content.buttonStyle(.borderedProminent)
        case .secondary:
            content.buttonStyle(.bordered)
        case .ghost:
            content.buttonStyle(.plain)
        }
    }
}

extension View {
    // Screens declare only a button role instead of scattering concrete buttonStyle calls.
    func appButtonRole(_ role: AppButtonRole) -> some View {
        modifier(AppButtonRoleModifier(role: role))
    }
}

enum AppRoute: Equatable {
    case firstBoot
    case modeSelection
    case filterSummary
    case slideshow
}

struct AppFlowStateMachine {
    var route: AppRoute = .firstBoot
    var isOnboardingSession: Bool = false
    var isAccessProtectionEnabled: Bool
    var slideshowBackRoute: AppRoute? = nil

    init(initialAccessProtectionEnabled: Bool = AccessProtectionStore.shared.isEnabled) {
        self.isAccessProtectionEnabled = initialAccessProtectionEnabled
    }

    mutating func handleFirstBootConfigured(serverIsConfigured: Bool) {
        guard serverIsConfigured else {
            finishOnboardingSession()
            route = .firstBoot
            return
        }
        startOnboardingSession()
    }

    mutating func handleOnboardingModeDone(_ mode: SlideMode) {
        switch mode {
        case .random:
            slideshowBackRoute = isOnboardingSession ? .modeSelection : nil
            route = .slideshow
        case .filtered:
            slideshowBackRoute = nil
            route = .filterSummary
        }
    }

    mutating func handleFilteredPlaybackStarted() {
        slideshowBackRoute = .filterSummary
        route = .slideshow
    }

    mutating func initializeRoute(serverIsConfigured: Bool) {
        finishOnboardingSession()
        route = serverIsConfigured ? .slideshow : .firstBoot
    }

    mutating func returnToOnboardingModeSelection() {
        guard isOnboardingSession else { return }
        route = .modeSelection
    }

    mutating func syncAccessProtection(enabled: Bool) {
        isAccessProtectionEnabled = enabled
        if enabled {
            finishOnboardingSession()
        }
    }

    func slideshowBackTarget() -> AppRoute? {
        guard !isAccessProtectionEnabled else { return nil }
        return slideshowBackRoute
    }

    func canShowOnboardingBackFromFilterSummary() -> Bool {
        isOnboardingSession && !isAccessProtectionEnabled
    }

    mutating func startOnboardingSession() {
        isOnboardingSession = true
        slideshowBackRoute = nil
        route = .modeSelection
    }

    mutating func finishOnboardingSession() {
        isOnboardingSession = false
        slideshowBackRoute = nil
    }
}

struct ContentView: View {

    @State private var server: ImmichServer? = ImmichServer.load()
    // The root flow owns the onboarding session and revokes it (and the back navigation) once a PIN is enabled;
    // slideshowBackTarget is for unit tests only and the playback screen does not read it.
    @State private var flow = AppFlowStateMachine()

    @State private var hasInitializedFlow: Bool = false

    @State private var showSettingsPage: Bool = false

    @StateObject private var slideShowVM: SlideShowViewModel
    @StateObject private var onboardingFilterVM = FilterViewModel()

    init() {
        // On cold launch, create the VM from the saved mode so default random and filtered loads do not compete.

        _slideShowVM = StateObject(
            wrappedValue: SlideShowViewModel(source: Self.initialPlaybackSourceForColdLaunch())
        )
    }

    static func initialPlaybackSourceForColdLaunch() -> PlaybackSource {
        let settings = PlaybackSettingsStore().load() ?? PlaybackSettings()

        guard settings.defaultPlaybackMode == .filtered else {
            return .random
        }

        let selection = FilterSelectionStore().load() ?? FilterSelection()
        guard !selection.isEmpty else {
            return .random
        }

        return .filtered(selection)
    }

    private var onboardingBackHandler: (() -> Void)? {
        flow.canShowOnboardingBackFromFilterSummary() ? { returnToOnboardingModeSelection() } : nil
    }

    #if os(tvOS)
    private var firstBootRouteView: some View {
        wrapTVOnboardingStep(.connectServer) {
            FirstBootView(onConfigure: handleFirstBootConfigured)
        }
    }

    private var modeSelectionRouteView: some View {
        // The tvOS mode screen overlays its own top-left capsule and does not use the large shell.

        ModeSelectionView(
            onboardingOnly: true,
            onOnboardingDone: { mode in
                handleOnboardingModeDone(mode)
            }
        )
    }

    private var filterSummaryRouteView: some View {

        FilterSummaryView(
            viewModel: onboardingFilterVM,
            onBackToModeSelection: onboardingBackHandler,
            onboardingOnly: flow.isOnboardingSession,
            onStartPlaybackRequested: { selection in
                // Do not await pool building on the summary screen; switch the playback source, then open playback.

                slideShowVM.preparePlaybackSourceForPresentation(to: .filtered(selection))
                flow.handleFilteredPlaybackStarted()
            }
        )
    }
    #else
    private var firstBootRouteView: some View {
        FirstBootView(onConfigure: handleFirstBootConfigured)
    }

    private var modeSelectionRouteView: some View {
        ModeSelectionView(
            onboardingOnly: true,
            onOnboardingDone: { mode in
                handleOnboardingModeDone(mode)
            }
        )
    }

    private var filterSummaryRouteView: some View {
        FilterSummaryView(
            viewModel: onboardingFilterVM,
            onBackToModeSelection: onboardingBackHandler,
            // iOS step 3 must pass onboardingOnly down so the filter summary can show the wizard header.

            onboardingOnly: flow.isOnboardingSession,
            onStartPlaybackRequested: { selection in
                slideShowVM.preparePlaybackSourceForPresentation(to: .filtered(selection))
                flow.handleFilteredPlaybackStarted()
            }
        )
    }
    #endif

    var body: some View {
        NavigationStack {
            Group {

                if flow.route == .firstBoot {
                    firstBootRouteView
                } else if let server = server, server.isConfigured {
                    switch flow.route {
                    case .firstBoot:

                        EmptyView()
                    case .modeSelection:
                        modeSelectionRouteView
                    case .filterSummary:
                        filterSummaryRouteView
                    case .slideshow:
                        SlideShowView(
                            viewModel: slideShowVM,
                            onOpenSettings: { showSettingsPage = true },
                            showsOnboardingPlaybackHint: flow.isOnboardingSession
                        )
                    }
                } else {
                    firstBootRouteView
                }
            }
            .navigationDestination(isPresented: $showSettingsPage) {
                SettingsView()
                    .onDisappear {
                        Task {
                            await slideShowVM.forceReloadCurrentAssetAfterCacheClear()
                        }
                    }
            }
            .toolbar {
                if shouldShowToolbarBackButton, let globalBackAction {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            globalBackAction()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .padding(.leading, 8)
                        .accessibilityIdentifier("global.back.button")
                    }
                }
            }
        }
        .onAppear {
            initializeFlowIfNeeded()
            syncAccessProtectionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessProtectionStateDidChange)) { _ in
            syncAccessProtectionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverConfigurationDidChange)) { _ in
            reloadServer()
            onboardingFilterVM.resetForServerConfigurationChange()
        }
    }

    private func handleFirstBootConfigured() {
        reloadServer()
        flow.handleFirstBootConfigured(serverIsConfigured: (server?.isConfigured ?? false))
    }

    private func handleOnboardingModeDone(_ mode: SlideMode) {
        flow.handleOnboardingModeDone(mode)
    }

    // Only an onboarding session may go back to mode selection.
    private func returnToOnboardingModeSelection() {
        flow.returnToOnboardingModeSelection()
    }

    private func initializeFlowIfNeeded() {
        guard !hasInitializedFlow else { return }
        hasInitializedFlow = true
        bootstrapDebugServerIfNeeded()
        reloadServer()
        if PlatformCompat.shouldForceModeSelectionForUITesting,
            server?.isConfigured == true
        {
            // A configured cold launch goes straight to playback; only the UI-test override turns it into an
            // onboarding session.

            flow.startOnboardingSession()
            return
        }
        flow.initializeRoute(serverIsConfigured: (server?.isConfigured ?? false))
    }

    private func reloadServer() {
        // Refresh the API singleton along with the screen state so the next screen does not use an empty config.

        ImmichAPIService.shared.reloadServerConfiguration()
        server = ImmichServer.load()
    }

    private func bootstrapDebugServerIfNeeded() {
        // With UI_TEST_RESET_STATE, skip the Info.plist bootstrap, otherwise it would bypass the first-boot screen.

        guard ProcessInfo.processInfo.environment["UI_TEST_RESET_STATE"] != "1" else { return }
        guard (server?.isConfigured ?? false) == false else { return }
        let enableDebugAutoServer =
            (Bundle.main.object(forInfoDictionaryKey: "ENABLE_DEBUG_AUTO_SERVER") as? String) == "1"
        guard enableDebugAutoServer else { return }
        guard let testServer = ImmichServer.debugTestServerFromInfoPlist() else { return }
        testServer.save()
    }

    private var globalBackAction: (() -> Void)? {
        switch flow.route {
        case .slideshow:
            // The playback screen never goes back; change the scope through Settings.

            return nil
        case .filterSummary:
            guard !flow.isAccessProtectionEnabled else { return nil }
            return onboardingBackHandler
        case .firstBoot, .modeSelection:
            return nil
        }
    }

    // The root toolbar back button is only for going from the filter summary back to mode selection.

    private var shouldShowToolbarBackButton: Bool {
        flow.route == .filterSummary
    }

    // The shared server screen overlays the same top-left progress capsule at the root.

    #if os(tvOS)
    @ViewBuilder
    private func wrapTVOnboardingStep<Content: View>(
        _ step: TVOnboardingWizardStep,
        @ViewBuilder content: () -> Content
    ) -> some View {
        OnboardingWizardShellViewTV(currentStep: step) {
            content()
        }
    }
    #endif

    private func syncAccessProtectionState() {
        flow.syncAccessProtection(enabled: AccessProtectionStore.shared.isEnabled)
    }
}

#Preview {
    ContentView()
}
