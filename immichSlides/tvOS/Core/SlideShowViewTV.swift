#if os(tvOS)
//
//  SlideShowViewTV.swift
//  immichSlides
//
//  Created by Codex during platform separation.

import SwiftUI
import UIKit

enum PlaybackViewMetrics {
    static let controlBarProtectionHeightPoints: Double = 220
    static let controlBarAutoHideDelaySeconds: Int = 8
    static let controlBarAnimationDurationSeconds: Double = 0.3
    static let renderSamplingRateHertz: Double = 60.0
}

struct SlideShowViewTV: View {
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: SlideShowViewModel
    // Settings navigation is handled by the parent router.
    var onOpenSettings: (() -> Void)? = nil

    var shouldShowOnboardingPlaybackHint: Bool = false

    @State var isDebugOverlayVisible: Bool = false

    @State var isExifVisible: Bool = true

    @State var exifForegroundTone: ExifForegroundTone = .lightText
    // Record the EXIF panel's actual frame; text color sampling can't rely on a rough top-right position.

    @State var exifFrameInSurfaceSpace: CGRect = .zero
    // UI tests wait until text color sampling finishes before taking
    // screenshots, to avoid capturing the default white text.

    @State var isExifForegroundToneReady: Bool = false
    // Remember the last asset that can show EXIF, so SmartFill can
    // reuse the single-photo panel morph with or without EXIF.
    @State var retainedExifOverlayAsset: Asset? = nil
    @State var isRenderedExifOverlayVisible: Bool = false

    @State private var isPinEntrySheetPresented: Bool = false

    @State private var pinEntryErrorMessage: String = ""

    @State private var isAccessProtectionRecoveryAlertPresented: Bool = false
    #if DEBUG
    // Read-only probe for UI tests: caches shared renderer output and does not drive motion.
    @State var smartFillMotionFrameProbeRows: [String] = []
    // Read-only trace for UI tests: probe lines already emitted; it only writes evidence.
    @State var smartFillMotionTraceLines: [String] = []
    @State var smartFillMotionTraceBuffer = SmartFillMotionTraceBuffer()
    @State var smartFillMotionTraceStatus: String = "idle"
    @State var hasSmartFillMotionTraceStarted: Bool = false
    @State var smartFillMotionTraceFilePath: String = ""
    @State var smartFillMotionTraceLineCount: Int = 0
    @State var smartFillMotionTraceWaitStartedAt: TimeInterval = 0
    @State var smartFillMotionTraceCollectionStartedAt: TimeInterval = 0
    @State var smartFillMotionTraceNextSampleIndex: Int = 0
    #endif
    // Increment an Int to request focus back to playPause; setting a Bool twice in a row would not trigger onChange.

    @State private var controlBarFocusRequestToken: Int = 0

    @State private var isPlaybackEntryHintVisible: Bool = false
    private let playbackEntryHintStore = PlaybackEntryHintStore()

    @State var isControlBarVisible: Bool = true

    @State private var autoHideBarTask: Task<Void, Never>? = nil
    // When the control bar is hidden, a hidden focus receiver handles arrow keys and Play/Pause.

    @FocusState private var hiddenWakeReceiverFocused: Bool
    // For SmartFill multi-photo layouts, keep the subject readable first so EXIF doesn't cover faces.
    var visibleExifOverlayAsset: Asset? {
        exifOverlayAsset(in: viewModel.visibleOverlayScene)
    }
    func exifOverlayAsset(in scene: PlaybackScene?) -> Asset? {
        guard isExifVisible,
            let scene,
            scene.smartFillReadback?.sceneType.shouldPreserveExistingExifOverlay != false,
            let asset = scene.primaryAsset,
            asset.exifInfo != nil
        else {
            return nil
        }
        return asset
    }
    private var isExifOverlayVisible: Bool {
        visibleExifOverlayAsset != nil
    }
    private var exifOverlayPresentationKey: String {
        visibleExifOverlayAsset?.id ?? "hidden"
    }

    #if DEBUG
    private var visionAuditTriggerKey: String {
        let assetId = viewModel.safeCurrentAsset?.id ?? "no-asset"
        let auditMode = viewModel.shouldRunDebugVisionFaceAudit ? "vision-enabled" : "vision-disabled"
        let previewState =
            viewModel.safeCurrentAsset.map { asset in
                String(describing: viewModel.downloadManager.assetPreviewStates[asset.id] ?? .notStarted)
            } ?? "no-preview"
        let fullsizeState =
            viewModel.safeCurrentAsset.map { asset in
                String(describing: viewModel.downloadManager.assetStates[asset.id] ?? .notStarted)
            } ?? "no-fullsize"
        return "\(isDebugOverlayVisible)-\(auditMode)-\(assetId)-\(previewState)-\(fullsizeState)"
    }
    #endif

    private func exifForegroundTriggerKey(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> String {
        let assetId = viewModel.safeCurrentAsset?.id ?? "no-asset"
        let previewState =
            viewModel.safeCurrentAsset.map { asset in
                String(describing: viewModel.downloadManager.assetPreviewStates[asset.id] ?? .notStarted)
            } ?? "no-preview"
        let fullsizeState =
            viewModel.safeCurrentAsset.map { asset in
                String(describing: viewModel.downloadManager.assetStates[asset.id] ?? .notStarted)
            } ?? "no-fullsize"
        let sizeSignature = "\(roundedSamplingValue(surfaceSize.width))x\(roundedSamplingValue(surfaceSize.height))"
        let safeAreaSignature = [
            roundedSamplingValue(safeAreaInsets.top),
            roundedSamplingValue(safeAreaInsets.leading),
            roundedSamplingValue(safeAreaInsets.bottom),
            roundedSamplingValue(safeAreaInsets.trailing)
        ].map(String.init).joined(separator: ",")
        let frameSignature = [
            roundedSamplingValue(exifFrameInSurfaceSpace.minX),
            roundedSamplingValue(exifFrameInSurfaceSpace.minY),
            roundedSamplingValue(exifFrameInSurfaceSpace.width),
            roundedSamplingValue(exifFrameInSurfaceSpace.height)
        ].map(String.init).joined(separator: ",")

        return
            "\(isExifVisible)-\(assetId)-\(previewState)-\(fullsizeState)-\(sizeSignature)-\(safeAreaSignature)-\(frameSignature)"
    }

    private func smartFillSurfaceTriggerKey(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> String {
        guard surfaceSize.width > 0, surfaceSize.height > 0 else {
            return "invalid"
        }
        let surface = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(
                width: max(1, Int(surfaceSize.width.rounded())),
                height: max(1, Int(surfaceSize.height.rounded()))
            ),
            profile: .appleTV,
            orientation: surfaceSize.width >= surfaceSize.height ? .landscape : .portrait,
            safeAreaClass: "safeTV"
        )
        let safeAreaSignature = [
            roundedSamplingValue(safeAreaInsets.top),
            roundedSamplingValue(safeAreaInsets.leading),
            roundedSamplingValue(safeAreaInsets.bottom),
            roundedSamplingValue(safeAreaInsets.trailing)
        ].map(String.init).joined(separator: ",")
        return [
            surface.internalSurfaceFingerprint,
            isControlBarVisible ? "bar-visible" : "bar-hidden",
            safeAreaSignature,
            "appletv"
        ].joined(separator: "|")
    }

    private func updateSmartFillSurface(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) {
        guard surfaceSize.width > 0, surfaceSize.height > 0 else { return }
        let surface = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(
                width: max(1, Int(surfaceSize.width.rounded())),
                height: max(1, Int(surfaceSize.height.rounded()))
            ),
            profile: .appleTV,
            orientation: surfaceSize.width >= surfaceSize.height ? .landscape : .portrait,
            safeAreaClass: "safeTV"
        )
        viewModel.updateSmartFillSurface(
            surface,
            protectionSnapshot: smartFillProtectionSnapshot(
                surfaceSize: surfaceSize,
                safeAreaInsets: safeAreaInsets
            )
        )
    }

    private func smartFillProtectionSnapshot(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> PlaybackProtectionSnapshot {
        var regions = PlaybackProtectionSnapshot(
            safeAreaInsets: PlaybackProtectionInsets(
                top: Double(safeAreaInsets.top),
                leading: Double(safeAreaInsets.leading),
                bottom: Double(safeAreaInsets.bottom),
                trailing: Double(safeAreaInsets.trailing)
            ),
            systemTopObstructionHeight: 0,
            surfaceWidth: Double(surfaceSize.width),
            surfaceHeight: Double(surfaceSize.height)
        ).regions

        if isControlBarVisible,
            let rect = PlaybackProtectionRect.fromPointRect(
                x: 0,
                y: max(0, Double(surfaceSize.height) - PlaybackViewMetrics.controlBarProtectionHeightPoints),
                width: Double(surfaceSize.width),
                height: PlaybackViewMetrics.controlBarProtectionHeightPoints,
                surfaceWidth: Double(surfaceSize.width),
                surfaceHeight: Double(surfaceSize.height)
            ),
            let region = PlaybackProtectionRegion.controlBar(
                rect: rect,
                activeConditionSummary: "visible"
            )
        {
            regions.append(region)
        }
        return PlaybackProtectionSnapshot(regions: regions)
    }

    // UI tests can turn off the one-time tip so it doesn't pollute old screenshot baselines.

    private var isPlaybackEntryHintDisabledForUITests: Bool {
        PlatformCompat.shouldDisablePlaybackEntryHintForTesting
    }

    private var shouldExposeExifForegroundToneProbeForTesting: Bool {
        PlatformCompat.shouldExposeUITestProbes
    }

    private var shouldExposeSmartFillManifestProbeForTesting: Bool {
        #if DEBUG
        return PlatformCompat.shouldExposeUITestProbes
        #else
        return false
        #endif
    }

    var shouldExposeSmartFillMotionFrameProbeForTesting: Bool {
        #if DEBUG
        return PlatformCompat.shouldExposeUITestProbes
        #else
        return false
        #endif
    }

    private var shouldExposePlaybackRequestLifecycleProbeForTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment[PlaybackImageRequestLifecycleDiagnostics.environmentFlag] == "1"
        #else
        false
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {

                Group {
                    if viewModel.isLoading {

                        SlidePlaybackLoadingView()
                    } else if viewModel.assets.isEmpty {
                        // For an empty pool, show the reason given by the ViewModel; don't guess in the View.

                        Text(viewModel.emptyPlaybackMessage ?? String(localized: "No Photos Available"))
                            .accessibilityIdentifier("slideshow.emptyState.message")
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 80)

                    } else {

                        renderPhoto(in: geometry.size, safeAreaInsets: geometry.safeAreaInsets)

                        Group {
                            if let asset = retainedExifOverlayAsset {
                                VStack {
                                    HStack {
                                        Spacer()
                                        ExifInfoView(
                                            asset: asset,
                                            foregroundTone: exifForegroundTone
                                        )
                                        .onGeometryChange(for: CGRect.self) { proxy in

                                            proxy.frame(in: .global)
                                        } action: { newFrame in
                                            exifFrameInSurfaceSpace = newFrame
                                        }
                                        .animation(
                                            .easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration),
                                            value: retainedExifOverlayAsset?.id)
                                    }
                                    .padding(.top, exifTopPadding(for: geometry.safeAreaInsets))
                                    .padding(.trailing, exifHorizontalPadding)
                                    .overlay(alignment: .topTrailing) {
                                        // UI tests only: release builds keep the tone anchors out of VoiceOver.
                                        if shouldExposeExifForegroundToneProbeForTesting {
                                            Color.clear
                                                .frame(width: 1, height: 1)
                                                .accessibilityElement()
                                                .accessibilityIdentifier("slideshow.exifForegroundTone.flag")
                                                .accessibilityLabel(exifForegroundTone.debugAccessibilityLabel)

                                            if isExifForegroundToneReady {
                                                Color.clear
                                                    .frame(width: 1, height: 1)
                                                    .accessibilityElement()
                                                    .accessibilityIdentifier("slideshow.exifForegroundTone.ready")
                                                    // localization-audit: ui-test-probe
                                                    .accessibilityLabel(Text(verbatim: "ready"))
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .opacity(isRenderedExifOverlayVisible ? 1 : 0)
                                .focusable(false)
                                .allowsHitTesting(false)
                                .accessibilityHidden(!isRenderedExifOverlayVisible)
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onTapGesture {

                    wakeControlBar()
                }
                .allowsHitTesting(true)
                .task(
                    id: exifForegroundTriggerKey(
                        surfaceSize: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                ) {
                    await refreshExifForegroundTone(
                        surfaceSize: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                }
                #if DEBUG
                if PlatformCompat.isPlaybackDebugPanelEnabled && isDebugOverlayVisible {
                    DebugOverlayView(
                        viewModel: viewModel,
                        downloadManager: viewModel.downloadManager,
                        renderCount: viewModel.renderCount,
                        bottomPadding: isControlBarVisible ? 140 : 12
                    )
                    // UI test anchor for asserting the debug panel toggle.
                    Text("debug-overlay-on")
                        .font(.caption2)
                        .foregroundStyle(.clear)
                        .accessibilityIdentifier("slideshow.debugOverlay.flag")
                }
                #endif
                #if DEBUG
                if shouldExposeSmartFillManifestProbeForTesting,
                    let manifest = viewModel.currentSmartFillRuntimeQADebugSummary(
                        controlBarVisible: isControlBarVisible,
                        exifOverlayVisible: isExifOverlayVisible
                    )
                {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("slideshow.smartfill.currentManifest.flag")
                        .accessibilityLabel(manifest)
                }
                #endif
                #if DEBUG
                smartFillMotionFrameProbeOverlay()
                if shouldExposePlaybackRequestLifecycleProbeForTesting {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("slideshow.requestLifecycle.summary.flag")
                        .accessibilityLabel(viewModel.playbackImageRequestLifecycleSummaryJSON)
                    Button {
                        viewModel.flushPlaybackImageRequestLifecycleEvidenceForDiagnostics()
                    } label: {
                        // localization-audit: ui-test-probe
                        Text("flush")
                            .font(.caption2)
                            .frame(width: 44, height: 44)
                            .opacity(0.01)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -48)
                    .accessibilityIdentifier("slideshow.requestLifecycle.flush.button")
                    // localization-audit: ui-test-probe
                    .accessibilityLabel("flush")
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("slideshow.requestLifecycle.cachePersistence.status.flag")
                        .accessibilityLabel(viewModel.playbackImageCachePersistenceSnapshotJSON)
                    Button {
                        viewModel.checkPlaybackImageCachePersistenceForDiagnostics()
                    } label: {
                        // localization-audit: ui-test-probe
                        Text("cache-persistence-check")
                            .font(.caption2)
                            .frame(width: 44, height: 44)
                            .opacity(0.01)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 48)
                    .accessibilityIdentifier("slideshow.requestLifecycle.cachePersistence.check.button")
                    // localization-audit: ui-test-probe
                    .accessibilityLabel("cache-persistence-check")
                }
                #endif

                if let recoveryMessage = viewModel.autoPlayRecoveryMessage,
                    !recoveryMessage.isEmpty
                {
                    VStack {
                        Spacer()
                        Text(recoveryMessage)
                            .font(.system(size: 24, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 6)
                            .accessibilityIdentifier("slideshow.recovery.message")
                    }
                    // Raise the banner while the control bar is shown, so it doesn't cover the bottom controls.
                    .padding(
                        .bottom,
                        isControlBarVisible
                            ? max(geometry.safeAreaInsets.bottom, 178) : max(geometry.safeAreaInsets.bottom, 56)
                    )
                    .padding(.horizontal, 80)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                VStack {
                    Spacer()
                    if isControlBarVisible {
                        SlideshowControlBarViewTV(
                            currentIndex: .constant(viewModel.currentIndex),
                            isAutoPlay: $viewModel.isAutoPlay,
                            totalCount: viewModel.assets.count,
                            isPreviousEnabled: viewModel.canRequestPreviousScene,
                            focusRequestToken: controlBarFocusRequestToken,
                            onPrevious: onPrevious,
                            onNext: onNext,
                            onPlayPause: onPlayPause,
                            onSettings: onSettings,
                            shouldPreferSettingsFocusForEntryHint: isPlaybackEntryHintVisible,
                            shouldShowEntryHintBubble: isPlaybackEntryHintVisible,
                            entryHintContent: playbackEntryHintContent,
                            onMoveDownWhileEntryHintVisible: dismissPlaybackEntryHintAndHideControlBar
                        )
                        .padding(.horizontal, max(geometry.safeAreaInsets.leading, 80))
                        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 46))
                        .transition(.opacity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(true)
                .animation(
                    .easeInOut(duration: PlaybackViewMetrics.controlBarAnimationDurationSeconds),
                    value: isControlBarVisible)

                if isControlBarVisible == false {
                    Color.clear
                        .contentShape(Rectangle())
                        // The hidden receiver layer must be focusable for onMoveCommand to fire reliably.

                        .focusable(true, interactions: .activate)
                        .focused($hiddenWakeReceiverFocused)
                        .onAppear {
                            // Wait one frame after the receiver layer is
                            // inserted before focusing it, so focus isn't lost.

                            DispatchQueue.main.async {
                                hiddenWakeReceiverFocused = true
                            }
                        }
                        .onMoveCommand { _ in
                            wakeControlBar()
                        }
                        .onPlayPauseCommand {
                            onPlayPause()
                        }
                        .accessibilityIdentifier("slideshow.hiddenWakeReceiver")
                }
            }
            .onAppear {
                updateSmartFillSurface(
                    surfaceSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets
                )
            }
            .onChange(
                of: smartFillSurfaceTriggerKey(
                    surfaceSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets
                )
            ) { _, _ in
                updateSmartFillSurface(
                    surfaceSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets
                )
            }
            .onChange(of: exifOverlayPresentationKey) { _, _ in
                syncExifOverlayPresentation()
            }
        }
        .appStatusBarHidden(true)
        // Extend content to the very top so the navigation bar doesn't push the whole EXIF block down.
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            PlatformCompat.setIdleTimerDisabled(true)
            viewModel.updateSmartFillMotionReduceMotionEnabled(accessibilityReduceMotion)
            refreshPlaybackRelatedSettings()
            syncExifOverlayPresentation()
            maybePresentPlaybackEntryHintIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                viewModel.suspendScenePresentationForBackground()
            case .active:
                viewModel.resumeScenePresentationFromBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onDisappear {
            PlatformCompat.setIdleTimerDisabled(false)
            autoHideBarTask?.cancel()
            autoHideBarTask = nil
            isPlaybackEntryHintVisible = false
            #if DEBUG
            viewModel.clearVisionFaceAuditState()
            #endif
        }

        .task {

            await viewModel.firstPreload()
            // Inject the failure recovery message only in UI tests, for stable screenshots.
            #if DEBUG
            applyUITestFailureInjectionIfNeeded()
            #endif
            maybePresentPlaybackEntryHintIfNeeded()

            resetAutoHideTimer()
        }
        #if DEBUG
        .task(id: visionAuditTriggerKey) {
            guard PlatformCompat.isPlaybackDebugPanelEnabled, isDebugOverlayVisible,
                viewModel.shouldRunDebugVisionFaceAudit
            else {
                // Random playback can open the debug panel; the Vision probe only runs in soloOnly.

                #if DEBUG
                viewModel.clearVisionFaceAuditState()
                #endif
                return
            }
            await viewModel.refreshVisionFaceAuditForCurrentAsset()
        }
        #endif
        .onChange(of: viewModel.isLoading) { _, _ in
            maybePresentPlaybackEntryHintIfNeeded()
        }
        .onChange(of: accessibilityReduceMotion) { _, isEnabled in
            viewModel.updateSmartFillMotionReduceMotionEnabled(isEnabled)
        }
        .onMoveCommand { _ in
            // Arrow keys only wake the control bar and reset the countdown; they don't change the index directly.

            wakeControlBar()
        }
        .onPlayPauseCommand {
            onPlayPause()
        }
        .onChange(of: isControlBarVisible) { _, isVisible in
            if isVisible {
                hiddenWakeReceiverFocused = false
            } else {
                // Defer binding focus to the next frame, in case the receiver layer isn't inserted yet.

                DispatchQueue.main.async {
                    hiddenWakeReceiverFocused = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Refresh playback settings whenever UserDefaults posts a change notification.
            refreshPlaybackRelatedSettings()
        }
        .sheet(isPresented: $isPinEntrySheetPresented) {
            PinEntrySheetView(
                title: String(localized: "Enter PIN"),
                message: String(localized: "Enter the 6-digit PIN before opening Settings."),
                errorMessage: pinEntryErrorMessage.isEmpty ? nil : pinEntryErrorMessage,
                onCancel: {
                    pinEntryErrorMessage = ""
                    isPinEntrySheetPresented = false
                },
                onSubmit: { pin in
                    if AccessProtectionStore.shared.verifyPIN(pin) {
                        pinEntryErrorMessage = ""
                        isPinEntrySheetPresented = false
                        onOpenSettings?()
                    } else {
                        pinEntryErrorMessage = String(localized: "PIN is incorrect. Please try again.")
                    }
                }
            )
        }
        .alert("Access Protection Error", isPresented: $isAccessProtectionRecoveryAlertPresented) {
            Button("Reset Access Protection", role: .destructive) {
                AccessProtectionStore.shared.resetProtection()
                onOpenSettings?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Access Protection is on, but the PIN data is missing. Reset it to continue to Settings.")
        }
    }

    func playbackLayerZIndex(
        for role: PlaybackSessionEngine.ScenePresentationLayerRole
    ) -> Double {
        switch role {
        case .outgoing:
            return 0
        case .stable, .incoming:
            return 1
        }
    }

    func isScenePresentationTransitionActive(
        _ snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        snapshot.underlyingPhase == .transition || snapshot.underlyingPhase == .incomingFromLoading
    }

    func smartFillProductTransitionBlackBacking(
        in layers: [PlaybackSessionEngine.SceneRenderLayer],
        snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        isAcceptedSmartFillMotionTransitionActive(in: layers, snapshot: snapshot)
    }

    private func onPrevious() {
        guard viewModel.assets.count > 0 else { return }

        wakeControlBar()
        viewModel.requestPreviousScene()
    }
    private func onNext() {
        guard viewModel.assets.count > 0 else { return }

        wakeControlBar()
        viewModel.requestNextScene()
    }
    private func onPlayPause() {
        viewModel.toggleAutoPlayFromUserInteraction()
        wakeControlBar()
    }
    private func onSettings() {
        // Dismiss the one-time tip after Select opens Settings, so it isn't still showing on return.

        dismissPlaybackEntryHint()

        if AccessProtectionStore.shared.isEnabled {
            if AccessProtectionStore.shared.isRecoveryNeeded {
                isAccessProtectionRecoveryAlertPresented = true
                wakeControlBar()
                return
            }
            pinEntryErrorMessage = ""
            isPinEntrySheetPresented = true
        } else {
            onOpenSettings?()
        }
        wakeControlBar()
    }
    // Single wake entry point, so multiple interactions don't duplicate the logic.
    private func wakeControlBar() {
        if !isControlBarVisible {
            // Waking the bar while it fades out can leave focus on Settings, so ask for Play/Pause explicitly.
            controlBarFocusRequestToken += 1
        }
        isControlBarVisible = true
        resetAutoHideTimer()
    }

    private func resetAutoHideTimer() {
        autoHideBarTask?.cancel()  // Don't auto-hide the bar after 8 seconds while the tutorial bubble is shown.

        guard !isPlaybackEntryHintVisible else {
            autoHideBarTask = nil
            return
        }
        autoHideBarTask = Task {

            try? await Task.sleep(for: .seconds(PlaybackViewMetrics.controlBarAutoHideDelaySeconds))

            guard !Task.isCancelled else { return }
            await MainActor.run {
                isControlBarVisible = false
            }
        }
    }

    private var playbackEntryHintContent: TVSlideshowEntryHintContent {

        TVSlideshowEntryHintContent(
            // Bubble text uses String(localized:) so it follows the current app language.

            title: String(localized: "Adjust photo range and speed here"),
            actionTemplate: String(localized: "Press %@ to hide this tip"),
            actionKeyLabel: String(localized: "Down")
        )
    }

    private func maybePresentPlaybackEntryHintIfNeeded() {
        guard shouldShowOnboardingPlaybackHint else { return }
        guard !isPlaybackEntryHintDisabledForUITests else { return }
        guard !isPlaybackEntryHintVisible else { return }
        guard !playbackEntryHintStore.hasShownPlaybackEntryHint else { return }
        guard !viewModel.isLoading else { return }
        guard !viewModel.assets.isEmpty else { return }
        guard viewModel.emptyPlaybackMessage == nil else { return }
        guard viewModel.autoPlayRecoveryMessage == nil else { return }

        playbackEntryHintStore.markPlaybackEntryHintShown()
        withAnimation(.easeInOut(duration: 0.24)) {
            isPlaybackEntryHintVisible = true
            isControlBarVisible = true
        }
        autoHideBarTask?.cancel()
        autoHideBarTask = nil
    }

    private func dismissPlaybackEntryHint() {
        guard isPlaybackEntryHintVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isPlaybackEntryHintVisible = false
        }
    }

    private func dismissPlaybackEntryHintAndHideControlBar() {
        autoHideBarTask?.cancel()
        autoHideBarTask = nil
        withAnimation(.easeInOut(duration: 0.22)) {
            isPlaybackEntryHintVisible = false
            isControlBarVisible = false
        }
    }

    #if DEBUG
    // Inject the failure recovery branch only in UI tests; normal users never reach it.

    private func applyUITestFailureInjectionIfNeeded() {
        let forceRecoveryMessage =
            ProcessInfo.processInfo.environment["UI_TEST_FORCE_SLIDESHOW_RECOVERY_MESSAGE"] == "1"
        let forceCurrentFailurePlaceholder =
            ProcessInfo.processInfo.environment["UI_TEST_FORCE_SLIDEITEM_FAILURE_PLACEHOLDER"] == "1"

        guard forceRecoveryMessage || forceCurrentFailurePlaceholder else {
            return
        }

        // When the test server is unreachable, Preview falls back
        // to local data so it can still reach the failure branch.

        if viewModel.assets.isEmpty {
            viewModel.replacePlaybackAssetsForTesting(Asset.previewAssets)
            viewModel.setPlaybackLoadingForTesting(false)
        }

        guard viewModel.assets.count >= 2 else { return }

        if forceCurrentFailurePlaceholder {

            viewModel.isAutoPlay = false

            guard let currentId = viewModel.safeCurrentScene?.primaryAssetId else { return }
            viewModel.downloadManager.assetStates[currentId] = .failedToDownload
            viewModel.downloadManager.assetPreviewStates[currentId] = .readyToPlay
            return
        }

        // Tests only show the recovery message; they don't advance the real playback state machine.

        viewModel.isAutoPlay = false
        viewModel.forceNextPhotoRecoveryMessageForTesting(retryCount: 1)
    }
    #endif

    private var exifHorizontalPadding: CGFloat {
        return 30
    }

    private func exifTopPadding(for safeAreaInsets: EdgeInsets) -> CGFloat {
        return 30
    }

    private func roundedSamplingValue(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }

}

#if DEBUG
final class SmartFillMotionTraceBuffer {
    private(set) var lines: [String] = []

    func reset() {
        lines.removeAll(keepingCapacity: true)
    }

    func append(_ line: String) {
        lines.append(line)
    }

    func append(contentsOf newLines: [String]) {
        lines.append(contentsOf: newLines)
    }
}

#endif

/// The tvOS control bar isn't shared with iOS; clear focus states come first.

#Preview {
    if let testServer = ImmichServer.testServerFromInfoPlistForTesting() {
        testServer.save()
        ImmichAPIService.shared.reloadServerConfiguration()
    }
    return SlideShowViewTV(viewModel: SlideShowViewModel())
}

#endif
