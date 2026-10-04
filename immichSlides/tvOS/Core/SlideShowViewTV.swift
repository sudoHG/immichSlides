#if os(tvOS)
//
//  SlideShowViewTV.swift
//  immichSlides
//
//  Created by Codex during platform separation.

import SwiftUI
import UIKit

struct SlideShowViewTV: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: SlideShowViewModel
    // Settings navigation is handled by the parent router.
    var onOpenSettings: (() -> Void)? = nil

    var showsOnboardingPlaybackHint: Bool = false

    @State private var showDebugOverlay: Bool = false

    @State private var showExif: Bool = true

    @State private var exifForegroundTone: ExifForegroundTone = .lightText
    // Record the EXIF panel's actual frame; text color sampling can't rely on a rough top-right position.

    @State private var exifFrameInSurfaceSpace: CGRect = .zero
    // UI tests wait until text color sampling finishes before taking
    // screenshots, to avoid capturing the default white text.

    @State private var isExifForegroundToneReady: Bool = false
    // Remember the last asset that can show EXIF, so SmartFill can
    // reuse the single-photo panel morph with or without EXIF.
    @State private var retainedExifOverlayAsset: Asset? = nil
    @State private var renderedExifOverlayVisible: Bool = false

    @State private var showPinEntrySheet: Bool = false

    @State private var pinEntryErrorMessage: String = ""

    @State private var showAccessProtectionRecoveryAlert: Bool = false
    #if DEBUG
    // Read-only probe for UI tests: caches shared renderer output and does not drive motion.
    @State private var smartFillMotionFrameProbeRows: [String] = []
    // Read-only trace for UI tests: probe lines already emitted; it only writes evidence.
    @State private var smartFillMotionTraceLines: [String] = []
    @State private var smartFillMotionTraceBuffer = SmartFillMotionTraceBuffer()
    @State private var smartFillMotionTraceStatus: String = "idle"
    @State private var smartFillMotionTraceStarted: Bool = false
    @State private var smartFillMotionTraceFilePath: String = ""
    @State private var smartFillMotionTraceLineCount: Int = 0
    @State private var smartFillMotionTraceWaitStartedAt: TimeInterval = 0
    @State private var smartFillMotionTraceCollectionStartedAt: TimeInterval = 0
    @State private var smartFillMotionTraceNextSampleIndex: Int = 0
    #endif
    // Increment an Int to request focus back to playPause; setting a Bool twice in a row would not trigger onChange.

    @State private var controlBarFocusRequestToken: Int = 0

    @State private var showPlaybackEntryHint: Bool = false
    private let playbackEntryHintStore = PlaybackEntryHintStore()

    @State var showControlBar: Bool = true

    @State private var autoHideBarTask: Task<Void, Never>? = nil
    // When the control bar is hidden, a hidden focus receiver handles arrow keys and Play/Pause.

    @FocusState private var hiddenWakeReceiverFocused: Bool
    // For SmartFill multi-photo layouts, keep the subject readable first so EXIF doesn't cover faces.
    private var visibleExifOverlayAsset: Asset? {
        exifOverlayAsset(in: viewModel.visibleOverlayScene)
    }
    private func exifOverlayAsset(in scene: PlaybackScene?) -> Asset? {
        guard showExif,
            let scene,
            scene.smartFillReadback?.sceneType.shouldPreserveExistingExifOverlay != false,
            let asset = scene.primaryAsset,
            asset.exifInfo != nil
        else {
            return nil
        }
        return asset
    }
    private var exifOverlayVisible: Bool {
        visibleExifOverlayAsset != nil
    }
    private var exifOverlayPresentationKey: String {
        visibleExifOverlayAsset?.id ?? "hidden"
    }

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
        return "\(showDebugOverlay)-\(auditMode)-\(assetId)-\(previewState)-\(fullsizeState)"
    }

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
            "\(showExif)-\(assetId)-\(previewState)-\(fullsizeState)-\(sizeSignature)-\(safeAreaSignature)-\(frameSignature)"
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
            showControlBar ? "bar-visible" : "bar-hidden",
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

        if showControlBar,
            let rect = PlaybackProtectionRect.fromPointRect(
                x: 0,
                y: max(0, Double(surfaceSize.height) - 220),
                width: Double(surfaceSize.width),
                height: 220,
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
        ProcessInfo.processInfo.environment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] == "1"
    }

    private var exposesExifForegroundToneProbeForUITests: Bool {
        PlatformCompat.shouldExposeUITestProbes
    }

    private var exposesSmartFillManifestProbeForUITests: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["UI_TEST_RESET_STATE"] == "1"
        #else
        return false
        #endif
    }

    private var exposesSmartFillMotionFrameProbeForUITests: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["UI_TEST_RESET_STATE"] == "1"
        #else
        return false
        #endif
    }

    private var exposesPlaybackRequestLifecycleProbeForUITests: Bool {
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
                                        if exposesExifForegroundToneProbeForUITests {
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
                                .opacity(renderedExifOverlayVisible ? 1 : 0)
                                .focusable(false)
                                .allowsHitTesting(false)
                                .accessibilityHidden(!renderedExifOverlayVisible)
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
                if PlatformCompat.playbackDebugPanelEnabled && showDebugOverlay {
                    DebugOverlayView(
                        viewModel: viewModel,
                        downloadManager: viewModel.downloadManager,
                        renderCount: viewModel.renderCount,
                        bottomPadding: showControlBar ? 140 : 12
                    )
                    // UI test anchor for asserting the debug panel toggle.
                    Text("debug-overlay-on")
                        .font(.caption2)
                        .foregroundStyle(.clear)
                        .accessibilityIdentifier("slideshow.debugOverlay.flag")
                }
                if exposesSmartFillManifestProbeForUITests,
                    let manifest = viewModel.currentSmartFillRuntimeQADebugSummary(
                        controlBarVisible: showControlBar,
                        exifOverlayVisible: exifOverlayVisible
                    )
                {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("slideshow.smartfill.currentManifest.flag")
                        .accessibilityLabel(manifest)
                }
                #if DEBUG
                smartFillMotionFrameProbeOverlay()
                if exposesPlaybackRequestLifecycleProbeForUITests {
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
                        showControlBar
                            ? max(geometry.safeAreaInsets.bottom, 178) : max(geometry.safeAreaInsets.bottom, 56)
                    )
                    .padding(.horizontal, 80)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                VStack {
                    Spacer()
                    if showControlBar {
                        TVSlideshowControlBarView(
                            currentIndex: .constant(viewModel.currentIndex),
                            isAutoPlay: $viewModel.isAutoPlay,
                            totalCount: viewModel.assets.count,
                            isPreviousEnabled: viewModel.canRequestPreviousScene,
                            focusRequestToken: controlBarFocusRequestToken,
                            onPrevious: onPrevious,
                            onNext: onNext,
                            onPlayPause: onPlayPause,
                            onSettings: onSettings,
                            prefersSettingsFocusForEntryHint: showPlaybackEntryHint,
                            showsEntryHintBubble: showPlaybackEntryHint,
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
                .animation(.easeInOut(duration: 0.3), value: showControlBar)

                if showControlBar == false {
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
            showPlaybackEntryHint = false
            viewModel.clearVisionFaceAuditState()
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
        .task(id: visionAuditTriggerKey) {
            guard PlatformCompat.playbackDebugPanelEnabled, showDebugOverlay, viewModel.shouldRunDebugVisionFaceAudit
            else {
                // Random playback can open the debug panel; the Vision probe only runs in soloOnly.

                viewModel.clearVisionFaceAuditState()
                return
            }
            await viewModel.refreshVisionFaceAuditForCurrentAsset()
        }
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
        .onChange(of: showControlBar) { _, isVisible in
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
        .sheet(isPresented: $showPinEntrySheet) {
            PinEntrySheetView(
                title: String(localized: "Enter PIN"),
                message: String(localized: "Enter the 6-digit PIN before opening Settings."),
                errorMessage: pinEntryErrorMessage.isEmpty ? nil : pinEntryErrorMessage,
                onCancel: {
                    pinEntryErrorMessage = ""
                    showPinEntrySheet = false
                },
                onSubmit: { pin in
                    if AccessProtectionStore.shared.verifyPIN(pin) {
                        pinEntryErrorMessage = ""
                        showPinEntrySheet = false
                        onOpenSettings?()
                    } else {
                        pinEntryErrorMessage = String(localized: "PIN is incorrect. Please try again.")
                    }
                }
            )
        }
        .alert("Access Protection Error", isPresented: $showAccessProtectionRecoveryAlert) {
            Button("Reset Access Protection", role: .destructive) {
                AccessProtectionStore.shared.resetProtection()
                onOpenSettings?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Access Protection is on, but the PIN data is missing. Reset it to continue to Settings.")
        }
    }

    private func playbackLayerZIndex(
        for role: PlaybackSessionEngine.ScenePresentationLayerRole
    ) -> Double {
        switch role {
        case .outgoing:
            return 0
        case .stable, .incoming:
            return 1
        }
    }

    private func isScenePresentationTransitionActive(
        _ snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        snapshot.underlyingPhase == .transition || snapshot.underlyingPhase == .incomingFromLoading
    }

    private func smartFillProductTransitionBlackBacking(
        in layers: [PlaybackSessionEngine.SceneRenderLayer],
        snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        isAcceptedSmartFillMotionTransitionActive(in: layers, snapshot: snapshot)
    }

    #if DEBUG
    @ViewBuilder
    private func smartFillMotionFrameProbeOverlay() -> some View {
        if exposesSmartFillMotionFrameProbeForUITests {
            ZStack {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.smartfill.motionFrame.summary")
                    .accessibilityLabel(smartFillMotionFrameProbeRows.joined(separator: "\n"))
                    .focusable(false)
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.smartfill.productTransition.summary")
                    .accessibilityLabel(smartFillProductTransitionProbeLabel())
                    .focusable(false)
                smartFillMotionTraceProbeOverlay()
            }
            .task {
                await collectSmartFillMotionTraceIfNeeded()
            }
            .allowsHitTesting(false)
        }
    }

    private func smartFillProductTransitionProbeLabel() -> String {
        let snapshot = viewModel.sceneRenderSnapshot
        let layers = snapshot.layers
        let transitionLayers = smartFillTransitionLayers(in: layers)
        let transitionScenes = transitionLayers.compactMap { viewModel.scene(for: $0) }
        let roles =
            transitionLayers
            .map { smartFillProductTransitionRoleProbeValue(for: $0.role) }
            .joined(separator: "|")
        let sceneTypes =
            transitionScenes
            .map { smartFillProductSceneTypeProbeValue(for: $0) }
            .joined(separator: "|")
        let scopes =
            transitionScenes
            .map { smartFillProductSceneScopeProbeValue(for: $0) }
            .joined(separator: "|")
        let acceptedTransitionActive = isAcceptedSmartFillMotionTransitionActive(
            in: layers,
            snapshot: snapshot
        )
        return [
            "eventType=productTransition",
            "activeTransition=\(isScenePresentationTransitionActive(snapshot))",
            "productTransitionActive=\(acceptedTransitionActive)",
            "acceptedMotionTransitionActive=\(acceptedTransitionActive)",
            "productBlackBackingActive=\(smartFillProductTransitionBlackBacking(in: layers, snapshot: snapshot))",
            "blackBackingActive=\(smartFillProductTransitionBlackBacking(in: layers, snapshot: snapshot))",
            "transitionLayerCount=\(transitionLayers.count)",
            "transitionLayerRoles=\(roles.isEmpty ? "none" : roles)",
            "transitionLayerSceneTypes=\(sceneTypes.isEmpty ? "none" : sceneTypes)",
            "transitionLayerScopes=\(scopes.isEmpty ? "none" : scopes)"
        ].joined(separator: ";")
    }

    private func smartFillProductTransitionRoleProbeValue(
        for role: PlaybackSessionEngine.ScenePresentationLayerRole
    ) -> String {
        switch role {
        case .outgoing:
            return "outgoing"
        case .incoming:
            return "incoming"
        case .stable:
            return "settled"
        }
    }

    private func smartFillProductSceneTypeProbeValue(for scene: PlaybackScene) -> String {
        switch scene.smartFillReadback?.sceneType {
        case .double:
            return "double"
        case .triple:
            return "triple"
        case .single:
            return "single"
        case .fallback:
            return "fallback"
        case nil:
            return "legacy"
        }
    }

    private func smartFillProductSceneScopeProbeValue(for scene: PlaybackScene) -> String {
        switch scene.smartFillReadback?.sceneType {
        case .double, .triple, .single:
            return "acceptedMotion"
        case .fallback:
            return "smartFillNoMotion"
        case nil:
            return viewModel.isSmartFillPresentationModeActive ? "smartFillLegacyNoMotion" : "legacy"
        }
    }

    @ViewBuilder
    private func smartFillMotionTraceProbeOverlay() -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("slideshow.smartfill.motionFrame.trace.status")
            .accessibilityLabel(smartFillMotionTraceStatusLabel)
            .focusable(false)

        ForEach(Array(smartFillMotionTraceChunks().enumerated()), id: \.offset) { index, chunk in
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("slideshow.smartfill.motionFrame.trace.chunk.\(index)")
                .accessibilityLabel(chunk)
                .focusable(false)
        }
    }

    private var collectsSmartFillMotionTraceForUITests: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_COLLECT_SMARTFILL_MOTION_TRACE"] == "1"
    }

    private var smartFillMotionTraceStatusLabel: String {
        [
            "eventType=motionTraceStatus",
            "status=\(smartFillMotionTraceStatus)",
            "lineCount=\(smartFillMotionTraceLineCount)",
            "chunkCount=\(smartFillMotionTraceChunks().count)",
            "tracePath=\(smartFillMotionTraceFilePath.isEmpty ? "missing" : smartFillMotionTraceFilePath)",
            "sampleIntervalSeconds=\(String(format: "%.6f", smartFillMotionTraceSampleIntervalSeconds()))",
            "startTimeoutSeconds=\(String(format: "%.6f", smartFillMotionTraceStartTimeoutSeconds()))",
            "durationSeconds=\(String(format: "%.6f", smartFillMotionTraceDurationSeconds()))",
            "collectionStartedUptimeSeconds=\(String(format: "%.6f", smartFillMotionTraceCollectionStartedAt))"
        ].joined(separator: ";")
    }

    private func smartFillMotionTraceChunks() -> [String] {
        let maxChunkLength = 12_000
        var chunks: [String] = []
        var current = ""
        for line in smartFillMotionTraceLines {
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.count > maxChunkLength, !current.isEmpty {
                chunks.append(current)
                current = line
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    @MainActor
    private func collectSmartFillMotionTraceIfNeeded() async {
        guard collectsSmartFillMotionTraceForUITests, !smartFillMotionTraceStarted else { return }
        smartFillMotionTraceStarted = true
        smartFillMotionTraceStatus = "waiting-for-accepted-motion-frame"
        smartFillMotionTraceLines = []
        smartFillMotionTraceBuffer.reset()
        smartFillMotionTraceFilePath = ""
        smartFillMotionTraceLineCount = 0
        smartFillMotionTraceWaitStartedAt = ProcessInfo.processInfo.systemUptime
        smartFillMotionTraceCollectionStartedAt = 0
        smartFillMotionTraceNextSampleIndex = 0

        let waitTimeout = smartFillMotionTraceStartTimeoutSeconds()
        let duration = smartFillMotionTraceDurationSeconds()
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            appendSmartFillMotionTraceSampleIfNeeded(rows: smartFillMotionFrameProbeRows, now: now)
            switch smartFillMotionTraceStatus {
            case "waiting-for-accepted-motion-frame":
                if now - smartFillMotionTraceWaitStartedAt >= waitTimeout {
                    smartFillMotionTraceStatus = "missing-accepted-motion-frame"
                    return
                }
            case "collecting":
                if now - smartFillMotionTraceCollectionStartedAt >= duration {
                    finishSmartFillMotionTraceCollection()
                    return
                }
            default:
                return
            }
            try? await Task.sleep(nanoseconds: smartFillMotionTraceMonitorSleepNanoseconds())
            guard !Task.isCancelled else {
                smartFillMotionTraceStatus = "cancelled"
                return
            }
        }
    }

    @MainActor
    private func appendSmartFillMotionTraceSampleIfNeeded(
        rows: [String],
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard collectsSmartFillMotionTraceForUITests,
            smartFillMotionTraceStarted,
            smartFillMotionTraceStatus == "waiting-for-accepted-motion-frame"
                || smartFillMotionTraceStatus == "collecting"
        else {
            return
        }
        let traceRows = smartFillMotionTraceRowsForCurrentOverlay(rows)
        let hasAcceptedAvailableMotionRow = traceRows.contains { row in
            row.contains("acceptedMotionScope=true") && row.contains("progressFrameStatus=available")
        }
        let hasCleanSettledMotionRow = traceRows.contains { row in
            row.contains("acceptedMotionScope=true") && row.contains("progressFrameStatus=available")
                && row.contains("appOverlayPollution=none") && row.contains("renderRole=settled")
        }
        let canSample =
            smartFillMotionTraceStatus == "collecting"
            ? hasAcceptedAvailableMotionRow
            : hasCleanSettledMotionRow
        guard canSample else {
            return
        }

        if smartFillMotionTraceStatus == "waiting-for-accepted-motion-frame" {
            smartFillMotionTraceStatus = "collecting"
            smartFillMotionTraceCollectionStartedAt = now
            smartFillMotionTraceLines = []
            smartFillMotionTraceBuffer.reset()
            smartFillMotionTraceNextSampleIndex = 0
        }

        let elapsed = now - smartFillMotionTraceCollectionStartedAt
        guard elapsed <= smartFillMotionTraceDurationSeconds() else {
            finishSmartFillMotionTraceCollection()
            return
        }
        let sampleInterval = smartFillMotionTraceSampleIntervalSeconds()
        while true {
            let nextSampleElapsed = TimeInterval(smartFillMotionTraceNextSampleIndex) * sampleInterval
            guard elapsed + 0.0005 >= nextSampleElapsed else { return }

            let prefix = [
                "sampleIndex=\(smartFillMotionTraceNextSampleIndex)",
                "elapsedSeconds=\(String(format: "%.6f", nextSampleElapsed))",
                "captureElapsedSeconds=\(String(format: "%.6f", elapsed))"
            ].joined(separator: ";")
            if let productSceneLabel = smartFillProductSceneSequenceTraceLabel() {
                smartFillMotionTraceBuffer.append("\(prefix);\(productSceneLabel)")
            }
            smartFillMotionTraceBuffer.append(contentsOf: traceRows.map { "\(prefix);\($0)" })
            smartFillMotionTraceNextSampleIndex += 1
        }
    }

    private func smartFillProductSceneSequenceTraceLabel() -> String? {
        let snapshot = viewModel.sceneRenderSnapshot
        guard
            let visibleLayer = snapshot.layers.last(where: {
                $0.opacity > 0 && ($0.role == .stable || $0.role == .incoming)
            }),
            let scene = viewModel.scene(for: visibleLayer)
        else {
            return nil
        }
        let sceneFields = [
            "sceneId=\(MotionTransformResolver.diagnosticIdentityToken(scene.id))",
            "sceneType=\(smartFillProductSceneTypeProbeValue(for: scene))",
            "slotCount=\(scene.photoSlots.count)",
            "slotRefs=\(scene.diagnosticSlotReferences(separator: "|"))"
        ]
        let transitionFields = smartFillTraceFields(from: smartFillProductTransitionProbeLabel())
            .filter { $0 != "eventType=productTransition" }
        return (["eventType=productSceneSequence"] + sceneFields + transitionFields)
            .joined(separator: ";")
    }

    private func smartFillTraceFields(from raw: String) -> [String] {
        raw.split(separator: ";", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func smartFillMotionTraceRowsForCurrentOverlay(_ rows: [String]) -> [String] {
        rows.map { row in
            let retainedFields = smartFillTraceFields(from: row).filter { field in
                !field.hasPrefix("controlBarVisible=") && !field.hasPrefix("appOverlayPollution=")
            }
            let hostOverlayFields = [
                "controlBarVisible=\(showControlBar ? "true" : "false")",
                "appOverlayPollution=\(showControlBar ? "controlBar" : "none")"
            ]
            return (retainedFields + hostOverlayFields).joined(separator: ";")
        }
    }

    @MainActor
    private func finishSmartFillMotionTraceCollection() {
        guard smartFillMotionTraceStatus == "collecting" else { return }
        let collected = smartFillMotionTraceBuffer.lines
        smartFillMotionTraceLineCount = collected.count
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartfill-motion-trace-\(UUID().uuidString).txt")
        do {
            try collected.joined(separator: "\n").write(to: traceURL, atomically: true, encoding: .utf8)
            smartFillMotionTraceFilePath = traceURL.path
            smartFillMotionTraceLines = []
            smartFillMotionTraceBuffer.reset()
        } catch {
            smartFillMotionTraceFilePath = "write-failed"
            smartFillMotionTraceLines = collected
        }
        smartFillMotionTraceStatus = "complete"
    }

    private func smartFillMotionTraceMonitorSleepNanoseconds() -> UInt64 {
        UInt64((min(smartFillMotionTraceSampleIntervalSeconds(), 0.025) * 1_000_000_000).rounded())
    }

    private func smartFillMotionTraceSampleIntervalSeconds() -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        let rawValue = env["UI_TEST_SMARTFILL_MOTION_TRACE_SAMPLE_INTERVAL_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 0.025
        }
        return min(value, 0.05)
    }

    private func smartFillMotionTraceDurationSeconds() -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        let rawValue = env["UI_TEST_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 18
        }
        return value
    }

    private func smartFillMotionTraceStartTimeoutSeconds() -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        let rawValue = env["UI_TEST_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 60
        }
        return value
    }
    #else
    @ViewBuilder
    private func smartFillMotionFrameProbeOverlay() -> some View {
        EmptyView()
    }
    #endif

    private func isAcceptedSmartFillMotionTransitionActive(
        in layers: [PlaybackSessionEngine.SceneRenderLayer],
        snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        guard isScenePresentationTransitionActive(snapshot) else { return false }
        let transitionLayers = smartFillTransitionLayers(in: layers)
        guard transitionLayers.contains(where: { $0.role == .outgoing }),
            transitionLayers.contains(where: { $0.role == .incoming })
        else {
            return false
        }
        let scenes = transitionLayers.compactMap { viewModel.scene(for: $0) }
        return scenes.count == transitionLayers.count
            && scenes.allSatisfy { scene in
                switch scene.smartFillReadback?.sceneType {
                case .double, .triple, .single:
                    return true
                case .fallback, nil:
                    return false
                }
            }
    }

    private func smartFillTransitionLayers(
        in layers: [PlaybackSessionEngine.SceneRenderLayer]
    ) -> [PlaybackSessionEngine.SceneRenderLayer] {
        layers.filter { layer in
            layer.role == .outgoing || layer.role == .incoming
        }
    }

    @ViewBuilder
    func renderPhoto(in size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { _ in
            let snapshot = viewModel.sceneRenderSnapshot
            let overlayAsset = exifOverlayAsset(in: viewModel.visibleOverlayScene(in: snapshot))
            ZStack {
                if smartFillProductTransitionBlackBacking(
                    in: snapshot.layers,
                    snapshot: snapshot
                ) {
                    Color.black
                        .ignoresSafeArea(.container, edges: .all)
                        .accessibilityHidden(true)
                        .zIndex(-10)
                }
                if !snapshot.layers.isEmpty {
                    ForEach(snapshot.layers) { layer in
                        if let scene = viewModel.scene(for: layer) {
                            let layerIdentity = viewModel.scenePresentationLayerIdentity(for: layer)
                            let visibleFrameCandidate = SceneVisibleFrameCandidate(
                                layerIdentity: layerIdentity,
                                role: layer.role,
                                opacity: layer.opacity,
                                isBarrierComplete: viewModel.isScenePresentationBarrierComplete(for: layer),
                                isSceneRoot: true
                            )
                            SmartFillSceneView(
                                downloadManager: viewModel.downloadManager,
                                scene: scene,
                                isCurrent: PlaybackSessionEngine.ScenePresentationLayerRole.isCurrentForRenderer(
                                    role: layer.role,
                                    opacity: layer.opacity,
                                    hasOutgoingLayer: snapshot.layers.contains { $0.role == .outgoing }
                                ),
                                size: size,
                                safeAreaInsets: safeAreaInsets,
                                renderLayerRole: layer.role,
                                navigationToken: layer.identity.generation,
                                rendererAttemptID: viewModel.scenePresentationRendererAttemptID(for: layer),
                                motionContext: viewModel.motionRuntimeContext(
                                    for: layer,
                                    platform: .tvOS,
                                    isReduceMotionEnabled: accessibilityReduceMotion
                                ),
                                motionProbeControlBarVisible: showControlBar,
                                onRendererDecoded: viewModel.rendererDecoded,
                                onRendererFailed: viewModel.rendererFailed
                            )
                            .opacity(layer.opacity)
                            .allowsHitTesting(layer.role == .stable && layer.opacity > 0)
                            .focusable(false)
                            .accessibilityHidden(layer.opacity <= 0 || layer.role == .outgoing)
                            .zIndex(playbackLayerZIndex(for: layer.role))
                            .modifier(
                                SceneVisibleFrameReporterModifier(
                                    candidate: visibleFrameCandidate,
                                    onIncomingBecameVisible: viewModel.incomingBecameVisible
                                )
                            )
                        }
                    }
                } else {
                    Text("The slideshow failed to load. Go back, then reopen the slideshow.")
                }
                #if DEBUG
                if ProcessInfo.processInfo.environment["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"] == "1" {
                    // The contract probe reuses the product's displayed-frame
                    // snapshot instead of creating its own clock.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("slideshow.scenePresentation.contract.summary")
                        .accessibilityLabel(viewModel.scenePresentationContractProbeLabel(for: snapshot))
                        .focusable(false)
                        .allowsHitTesting(false)
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: overlayAsset?.id, initial: true) { _, _ in
                syncExifOverlayPresentation(overlayAsset)
            }
            #if DEBUG
            .onPreferenceChange(SmartFillMotionFrameProbePreferenceKey.self) { rows in
                smartFillMotionFrameProbeRows = rows
            }
            #endif
        }
    }
    func onPrevious() {
        guard viewModel.assets.count > 0 else { return }

        wakeControlBar()
        viewModel.requestPreviousScene()
    }
    func onNext() {
        guard viewModel.assets.count > 0 else { return }

        wakeControlBar()
        viewModel.requestNextScene()
    }
    func onPlayPause() {
        viewModel.toggleAutoPlayFromUserInteraction()
        wakeControlBar()
    }
    func onSettings() {
        // Dismiss the one-time tip after Select opens Settings, so it isn't still showing on return.

        dismissPlaybackEntryHint()

        if AccessProtectionStore.shared.isEnabled {
            if AccessProtectionStore.shared.isRecoveryNeeded {
                showAccessProtectionRecoveryAlert = true
                wakeControlBar()
                return
            }
            pinEntryErrorMessage = ""
            showPinEntrySheet = true
        } else {
            onOpenSettings?()
        }
        wakeControlBar()
    }
    // Single wake entry point, so multiple interactions don't duplicate the logic.
    private func wakeControlBar() {
        if !showControlBar {
            // Waking the bar while it fades out can leave focus on Settings, so ask for Play/Pause explicitly.
            controlBarFocusRequestToken += 1
        }
        showControlBar = true
        resetAutoHideTimer()
    }

    private func resetAutoHideTimer() {
        autoHideBarTask?.cancel()  // Don't auto-hide the bar after 8 seconds while the tutorial bubble is shown.

        guard !showPlaybackEntryHint else {
            autoHideBarTask = nil
            return
        }
        autoHideBarTask = Task {

            try? await Task.sleep(for: .seconds(8))

            guard !Task.isCancelled else { return }
            await MainActor.run {
                showControlBar = false
            }
        }
    }

    private func refreshExifForegroundTone(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) async {
        guard let asset = visibleExifOverlayAsset else {
            exifForegroundTone = .lightText
            isExifForegroundToneReady = false
            return
        }
        isExifForegroundToneReady = false

        let backdropContext = ExifDisplayedBackdropContext(
            surfaceSize: surfaceSize,
            safeAreaInsets: UIEdgeInsets(
                top: safeAreaInsets.top,
                left: safeAreaInsets.leading,
                bottom: safeAreaInsets.bottom,
                right: safeAreaInsets.trailing
            ),
            exifFrameInSurfaceSpace: exifFrameInSurfaceSpace
        )

        guard backdropContext.isValid else {
            // While the EXIF frame is still zero, use white text and sample after the geometry is written back.

            exifForegroundTone = .lightText
            isExifForegroundToneReady = false
            return
        }

        guard
            ExifForegroundAnalyzer.hasCachedImage(
                assetId: asset.id,
                downloadManager: viewModel.downloadManager
            )
        else {
            // If the image isn't cached yet, don't guess the text color from empty data.

            exifForegroundTone = .lightText
            isExifForegroundToneReady = false
            return
        }

        exifForegroundTone = await ExifForegroundAnalyzer.resolveTone(
            assetId: asset.id,
            downloadManager: viewModel.downloadManager,
            backdropContext: backdropContext,
            profile: .tvOS
        )
        isExifForegroundToneReady = true
    }

    private func syncExifOverlayPresentation() {
        syncExifOverlayPresentation(visibleExifOverlayAsset)
    }
    private func syncExifOverlayPresentation(_ asset: Asset?) {
        if let asset {
            if renderedExifOverlayVisible {
                withAnimation(.easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration)) {
                    retainedExifOverlayAsset = asset
                }
            } else {
                retainedExifOverlayAsset = asset
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration)) {
                        renderedExifOverlayVisible = true
                    }
                }
            }
        } else if renderedExifOverlayVisible {
            withAnimation(.easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration)) {
                renderedExifOverlayVisible = false
            }
        }
    }

    private func refreshPlaybackRelatedSettings() {
        // Sync autoplay settings each time playback opens, so the long-lived ViewModel doesn't use stale values.
        viewModel.refreshAutoPlaySettingsFromStore()
        let settings = PlaybackSettingsStore().load() ?? PlaybackSettings()
        showExif = settings.showExif

        showDebugOverlay = PlatformCompat.playbackDebugPanelEnabled && settings.showDebugOverlay

        switch settings.defaultPlaybackMode {
        case .random:
            guard settings.defaultPlaybackMode != viewModel.currentPlaybackMode else { return }
            Task {
                await viewModel.switchPlaybackSource(to: .random)
            }
        case .filtered:
            let selection = FilterSelectionStore().load() ?? FilterSelection()
            // Don't switch to filtered playback without a usable filter, to avoid empty playback.
            guard !selection.isEmpty else { return }

            // If the selection changes during filtered playback, reload right away instead of waiting for a restart.

            let modeChanged = settings.defaultPlaybackMode != viewModel.currentPlaybackMode
            let filteredSelectionChanged = viewModel.shouldReloadFilteredSource(for: selection)
            guard modeChanged || filteredSelectionChanged else { return }

            Task {
                await viewModel.switchPlaybackSource(to: .filtered(selection))
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
        guard showsOnboardingPlaybackHint else { return }
        guard !isPlaybackEntryHintDisabledForUITests else { return }
        guard !showPlaybackEntryHint else { return }
        guard !playbackEntryHintStore.hasShownPlaybackEntryHint else { return }
        guard !viewModel.isLoading else { return }
        guard !viewModel.assets.isEmpty else { return }
        guard viewModel.emptyPlaybackMessage == nil else { return }
        guard viewModel.autoPlayRecoveryMessage == nil else { return }

        playbackEntryHintStore.markPlaybackEntryHintShown()
        withAnimation(.easeInOut(duration: 0.24)) {
            showPlaybackEntryHint = true
            showControlBar = true
        }
        autoHideBarTask?.cancel()
        autoHideBarTask = nil
    }

    private func dismissPlaybackEntryHint() {
        guard showPlaybackEntryHint else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showPlaybackEntryHint = false
        }
    }

    private func dismissPlaybackEntryHintAndHideControlBar() {
        autoHideBarTask?.cancel()
        autoHideBarTask = nil
        withAnimation(.easeInOut(duration: 0.22)) {
            showPlaybackEntryHint = false
            showControlBar = false
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
            viewModel.isLoading = false
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
        viewModel.forceNextPhotoRecoveryMessageForUITesting(retryCount: 1)
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

private final class SmartFillMotionTraceBuffer {
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

/// The tvOS control bar isn't shared with iOS; clear focus states come first.

#Preview {
    if let testServer = ImmichServer.testServerFromInfoPlistForTesting() {
        testServer.save()
        ImmichAPIService.shared.reloadServerConfiguration()
    }
    return SlideShowViewTV(viewModel: SlideShowViewModel())
}

#endif
