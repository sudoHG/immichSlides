#if os(iOS)
//
//  SlideShowViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.

import SwiftUI
import UIKit

struct SlideShowViewIOS: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: SlideShowViewModel
    // Navigation to Settings is handled by the parent router.
    var onOpenSettings: (() -> Void)? = nil
    // Only marks whether we came from first launch; showing the tip also depends on local persisted state.

    var showsOnboardingPlaybackHint: Bool = false

    @State private var showDebugOverlay: Bool = false

    @State private var showExif: Bool = true

    @State private var exifForegroundTone: ExifForegroundTone = .lightText

    @State private var exifFrameInSurfaceSpace: CGRect = .zero

    @State private var exifSamplingDebugSnapshot: ExifSamplingDebugSnapshot? = nil
    // Keep the last EXIF-capable asset so SmartFill with or without EXIF can reuse the single-photo panel morph.
    @State private var retainedExifOverlayAsset: Asset? = nil
    @State private var renderedExifOverlayVisible: Bool = false

    @State private var showPinEntrySheet: Bool = false

    @State private var pinEntryErrorMessage: String = ""

    @State private var showAccessProtectionRecoveryAlert: Bool = false
    // Page-local mirror of the access protection toggle, used to update the back button immediately.
    @State private var isAccessProtectionEnabled: Bool = AccessProtectionStore.shared.isEnabled

    @State private var showPlaybackEntryHint: Bool = false
    private let playbackEntryHintStore = PlaybackEntryHintStore()

    @State var showControlBar: Bool = true

    @State private var autoHideBarTask: Task<Void, Never>? = nil
    @State private var smartFillMotionTraceLines: [String] = []
    @State private var smartFillMotionTraceBuffer = SmartFillMotionTraceBuffer()
    @State private var smartFillMotionTraceStatus: String = "idle"
    @State private var smartFillMotionTraceStarted: Bool = false
    @State private var smartFillMotionTraceFilePath: String = ""
    @State private var smartFillMotionTraceLineCount: Int = 0
    @State private var smartFillMotionTraceWaitStartedAt: TimeInterval = 0
    @State private var smartFillMotionTraceCollectionStartedAt: TimeInterval = 0
    @State private var smartFillMotionTraceNextSampleIndex: Int = 0
    @State private var smartFillMotionFrameProbeRows: [String] = []
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var smartFillMotionPlatform: MotionPlatform { isPhone ? .iOS : .iPadOS }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }
    // Multi-photo SmartFill keeps the subject readable first, so EXIF does not cover faces.
    private var visibleExifOverlayAsset: Asset? {
        exifOverlayAsset(in: viewModel.visibleOverlayScene)
    }
    private func exifOverlayAsset(in scene: PlaybackScene?) -> Asset? {
        guard showExif,
            let scene,
            scene.smartFillReadback?.sceneType.preservesExistingExifOverlay != false,
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
    // Preview and original cache states belong in the key so a later download still retriggers the audit.

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
            profile: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
            orientation: surfaceSize.width >= surfaceSize.height ? .landscape : .portrait,
            safeAreaClass: smartFillSafeAreaClass(safeAreaInsets)
        )
        return [
            surface.internalSurfaceFingerprint,
            showControlBar ? "bar-visible" : "bar-hidden",
            UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
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
            profile: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
            orientation: surfaceSize.width >= surfaceSize.height ? .landscape : .portrait,
            safeAreaClass: smartFillSafeAreaClass(safeAreaInsets)
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
                y: max(0, Double(surfaceSize.height) - 150),
                width: Double(surfaceSize.width),
                height: 150,
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

    private func smartFillSafeAreaClass(_ safeAreaInsets: EdgeInsets) -> String {
        let largestInset = max(
            safeAreaInsets.top,
            safeAreaInsets.leading,
            safeAreaInsets.bottom,
            safeAreaInsets.trailing
        )
        if largestInset < 1 {
            return "safe0"
        }
        if largestInset < 80 {
            return "safeA"
        }
        return "safeB"
    }

    // UI tests can turn off the one-time tip so it does not pollute the existing playback screenshot baselines.

    private var isPlaybackEntryHintDisabledForUITests: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] == "1"
    }

    // The diagnostic overlay is for UI tests and local diagnostics only;
    // normal playback never shows the red frame or the sample thumbnail.

    private var showsExifSamplingDebugOverlay: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_SHOW_EXIF_SAMPLING_DEBUG"] == "1"
    }

    private var exposesExifForegroundToneProbeForUITests: Bool {
        PlatformCompat.shouldExposeUITestProbes
    }

    private var exposesCurrentAssetIDProbeForUITests: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["UI_TEST_RESET_STATE"] == "1"
        #else
        return false
        #endif
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

    private var collectsSmartFillMotionTraceForUITests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["UI_TEST_COLLECT_SMARTFILL_MOTION_TRACE"] == "1"
        #else
        false
        #endif
    }

    private var exposesPlaybackRequestLifecycleProbeForUITests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment[PlaybackImageRequestLifecycleDiagnostics.environmentFlag] == "1"
        #else
        false
        #endif
    }

    // Main text matches tvOS; the action sentence says to tap the bubble to dismiss it.

    private var playbackEntryHintContent: IOSSlideshowEntryHintContent {
        IOSSlideshowEntryHintContent(
            title: String(localized: "Adjust photo range and speed here"),
            actionTemplate: String(localized: "Tap %@ to hide this tip"),
            actionKeyLabel: String(localized: "bubble")
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea(.container, edges: .all)
                    .accessibilityHidden(true)

                Group {
                    if viewModel.isLoading {

                        SlidePlaybackLoadingView()
                    } else if viewModel.assets.isEmpty {
                        // An empty pool shows the reason given by the ViewModel; the View does not guess.

                        Text(viewModel.emptyPlaybackMessage ?? String(localized: "No Photos Available"))
                            .accessibilityIdentifier("slideshow.emptyState.message")
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

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
                                        .overlay {
                                            if showsExifSamplingDebugOverlay {

                                                Rectangle()
                                                    .fill(Color.red.opacity(0.10))
                                                    .overlay(
                                                        Rectangle()
                                                            .stroke(Color.red, lineWidth: 2)
                                                    )
                                            }
                                        }
                                        .animation(
                                            .easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration),
                                            value: retainedExifOverlayAsset?.id)
                                    }
                                    .padding(.top, exifTopPadding(for: geometry.safeAreaInsets))
                                    .padding(.trailing, exifHorizontalPadding)
                                    .overlay(alignment: .topTrailing) {
                                        // UI tests only: release builds keep the tone anchor out of VoiceOver.
                                        if exposesExifForegroundToneProbeForUITests {
                                            Color.clear
                                                .frame(width: 1, height: 1)
                                                .accessibilityElement()
                                                .accessibilityIdentifier("slideshow.exifForegroundTone.flag")
                                                .accessibilityLabel(exifForegroundTone.debugAccessibilityLabel)
                                        }
                                    }
                                    Spacer()
                                }
                                .opacity(renderedExifOverlayVisible ? 1 : 0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(!renderedExifOverlayVisible)
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onTapGesture {

                    showControlBar = true
                    resetAutoHideTimer()
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
                if showsExifSamplingDebugOverlay {
                    exifSamplingDebugOverlay(
                        surfaceSize: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
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
                smartFillMotionFrameProbeOverlay(
                    surfaceSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets
                )
                if exposesCurrentAssetIDProbeForUITests {
                    // The history contract reads the published visible scene identity,
                    // so this probe cannot live only in the single-photo EXIF branch.

                    Button(action: {}) {
                        Text(verbatim: "current-asset-id-probe")
                            .font(.system(size: 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(0.01)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.currentAssetId.flag")
                    .accessibilityLabel(viewModel.visibleImageAssetIdProbeLabel)
                    .allowsHitTesting(false)
                }
                #if DEBUG
                if ProcessInfo.processInfo.environment["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"] == "1" {
                    // The probe spans loading to the first frame; the no-op button is only a stable accessibility leaf.

                    Button(action: {}) {
                        Text(verbatim: "scene-presentation-contract-probe")
                            .font(.system(size: 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(0.01)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.scenePresentation.contract.summary")
                    .accessibilityLabel(
                        viewModel.scenePresentationContractProbeLabel(for: viewModel.sceneRenderSnapshot)
                    )
                    .allowsHitTesting(false)
                }
                #endif
                #if DEBUG
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
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("slideshow.historyLedger.summary.flag")
                        .accessibilityLabel(viewModel.playbackHistoryLedgerDiagnosticsSummaryJSON)
                }
                #endif
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

                VStack {
                    Spacer()
                    if showControlBar {
                        SlideshowControlBarView(
                            currentIndex: .constant(viewModel.currentIndex),
                            isAutoPlay: $viewModel.isAutoPlay,
                            totalCount: viewModel.assets.count,
                            isPreviousEnabled: viewModel.canRequestPreviousScene,
                            onPrevious: onPrevious,
                            onNext: onNext,
                            onPlayPause: onPlayPause,
                            onSettings: onSettings,
                            showsEntryHintBubble: showPlaybackEntryHint,
                            entryHintContent: playbackEntryHintContent,
                            onEntryHintTap: dismissPlaybackEntryHintIfNeeded
                        )
                        .padding(.bottom, 40)
                        .transition(.opacity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(true)
                .animation(.easeInOut(duration: 0.3), value: showControlBar)
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
        .background(
            Color.black
                .ignoresSafeArea(.container, edges: .all)
        )
        .appStatusBarHidden(true)
        // Extend content to the very top so the navigation bar does not push EXIF down.
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            PlatformCompat.setIdleTimerDisabled(true)
            viewModel.updateSmartFillMotionReduceMotionEnabled(accessibilityReduceMotion)
            syncAccessProtectionState()
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
            maybePresentPlaybackEntryHintIfNeeded()
            // Do not auto-hide the control bar while the tip bubble is showing.

            if showPlaybackEntryHint {
                autoHideBarTask?.cancel()
                autoHideBarTask = nil
            } else {
                resetAutoHideTimer()
            }
        }
        .task(id: visionAuditTriggerKey) {
            guard PlatformCompat.playbackDebugPanelEnabled, showDebugOverlay, viewModel.shouldRunDebugVisionFaceAudit
            else {
                // Shuffle playback can open the debug panel but does not run the Vision probe.

                viewModel.clearVisionFaceAuditState()
                return
            }
            await viewModel.refreshVisionFaceAuditForCurrentAsset()
        }
        .onChange(of: accessibilityReduceMotion) { _, isEnabled in
            viewModel.updateSmartFillMotionReduceMotionEnabled(isEnabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessProtectionStateDidChange)) { _ in
            syncAccessProtectionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Resync playback settings once after returning from Settings.
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

    @ViewBuilder
    private func smartFillMotionFrameProbeOverlay(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        #if DEBUG
        if exposesSmartFillMotionFrameProbeForUITests {
            ZStack {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.smartfill.motionFrame.summary")
                    .accessibilityLabel(smartFillMotionFrameSummaryLabel())
                smartFillMotionTraceProbeOverlay()
                smartFillProductTransitionProbeOverlay()
            }
            .task {
                await collectSmartFillMotionTraceIfNeeded()
            }
            .allowsHitTesting(false)
        }
        #else
        EmptyView()
        #endif
    }

    #if DEBUG
    @ViewBuilder
    private func smartFillProductTransitionProbeOverlay() -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("slideshow.smartfill.productTransition.summary")
            .accessibilityLabel(smartFillProductTransitionProbeLabel())
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
        return [
            "eventType=productTransition",
            "activeTransition=\(isScenePresentationTransitionActive(snapshot))",
            "productTransitionActive=\(isSmartFillProductTransitionActive(in: layers, snapshot: snapshot))",
            "acceptedMotionTransitionActive=\(isAcceptedSmartFillMotionTransitionActive(in: layers, snapshot: snapshot))",
            "productBlackBackingActive=\(smartFillProductTransitionBlackBacking(in: layers, snapshot: snapshot))",
            "blackBackingActive=\(smartFillProductTransitionBlackBacking(in: layers, snapshot: snapshot))",
            "transitionLayerCount=\(transitionLayers.count)",
            "transitionLayerRoles=\(roles.isEmpty ? "none" : roles)",
            "transitionLayerSceneTypes=\(sceneTypes.isEmpty ? "none" : sceneTypes)",
            "transitionLayerScopes=\(scopes.isEmpty ? "none" : scopes)"
        ].joined(separator: ";")
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

    @ViewBuilder
    private func smartFillMotionTraceProbeOverlay() -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("slideshow.smartfill.motionFrame.trace.status")
            .accessibilityLabel(smartFillMotionTraceStatusLabel)

        ForEach(Array(smartFillMotionTraceChunks().enumerated()), id: \.offset) { index, chunk in
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("slideshow.smartfill.motionFrame.trace.chunk.\(index)")
                .accessibilityLabel(chunk)
        }
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
        let hasCleanAcceptedMotionRow = traceRows.contains { row in
            row.contains("acceptedMotionScope=true") && row.contains("progressFrameStatus=available")
                && row.contains("appOverlayPollution=none")
        }
        let canSample =
            smartFillMotionTraceStatus == "collecting"
            ? hasAcceptedAvailableMotionRow
            : hasCleanAcceptedMotionRow
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
    #endif

    private func smartFillMotionFrameSummaryLabel() -> String {
        #if DEBUG
        let debugFields = viewModel.smartFillMotionProbeDebugFieldsForTesting
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        #else
        let debugFields: [String] = []
        #endif
        guard !debugFields.isEmpty else {
            return smartFillMotionFrameProbeRows.joined(separator: "\n")
        }
        let suffix = debugFields.joined(separator: ";")
        return
            smartFillMotionFrameProbeRows
            .map { row in "\(row);\(suffix)" }
            .joined(separator: "\n")
    }

    // Diagnostic overlay: the red frame marks the EXIF panel; the top-left thumbnail checks the crop mapping.

    @ViewBuilder
    private func exifSamplingDebugOverlay(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if exifFrameInSurfaceSpace.width > 1,
                exifFrameInSurfaceSpace.height > 1
            {
                Rectangle()
                    .fill(Color.red.opacity(0.10))
                    .overlay(
                        Rectangle()
                            .stroke(Color.red, lineWidth: 2)
                    )
                    .frame(
                        width: exifFrameInSurfaceSpace.width,
                        height: exifFrameInSurfaceSpace.height
                    )
                    .offset(
                        x: exifFrameInSurfaceSpace.minX,
                        y: exifFrameInSurfaceSpace.minY
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("EXIF Sampling Diagnostics")
                    .font(.caption.bold())

                if let exifSamplingDebugSnapshot {
                    Image(uiImage: exifSamplingDebugSnapshot.reconstructedPanelImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 168, height: 92)
                        .border(Color.yellow, width: 1)

                    Text(exifSamplingDebugSummaryText(snapshot: exifSamplingDebugSnapshot))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Generating sample image...")
                        .font(.caption2)

                    Text(exifSamplingDebugPendingText())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .foregroundStyle(Color.yellow)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .padding(.top, safeAreaInsets.top + 8)
            .padding(.leading, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("slideshow.exifSamplingDebugOverlay.status")
            // localization-audit: ui-test-probe
            .accessibilityLabel(Text(verbatim: exifSamplingDebugSnapshot == nil ? "loading" : "ready"))

            if exifSamplingDebugSnapshot != nil {
                // Transparent ready marker that lets XCTest wait for the sample image; invisible in screenshots.

                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.exifSamplingDebugOverlay.ready")
                    // localization-audit: ui-test-probe
                    .accessibilityLabel(Text(verbatim: "ready"))
            }
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func exifSamplingDebugSummaryText(snapshot: ExifSamplingDebugSnapshot) -> String {
        [
            "tone=\(exifForegroundTone.debugAccessibilityLabel)",
            "surface=\(rectDebugText(snapshot.panelRectInSurfaceSpace))",
            "backdrop=\(rectDebugText(snapshot.panelRectInBackdropSpace))",
            "expanded=\(rectDebugText(snapshot.expandedPanelRectInBackdropSpace))"
        ].joined(separator: "\n")
    }

    private func exifSamplingDebugPendingText() -> String {
        [
            "tone=\(exifForegroundTone.debugAccessibilityLabel)",
            "surface=\(rectDebugText(exifFrameInSurfaceSpace))",
            "snapshot=missing"
        ].joined(separator: "\n")
    }

    private func rectDebugText(_ rect: CGRect) -> String {
        "x\(Int(rect.minX.rounded())) y\(Int(rect.minY.rounded())) w\(Int(rect.width.rounded())) h\(Int(rect.height.rounded()))"
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
        return scenes.count == transitionLayers.count && scenes.allSatisfy(isAcceptedSmartFillMotionScene)
    }

    private func smartFillProductTransitionBlackBacking(
        in layers: [PlaybackSessionEngine.SceneRenderLayer],
        snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        isSmartFillProductTransitionActive(in: layers, snapshot: snapshot)
    }

    private func isSmartFillProductTransitionActive(
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
        return
            transitionLayers
            .compactMap { viewModel.scene(for: $0) }
            .contains(where: isSmartFillProductScene)
    }

    private func smartFillTransitionLayers(
        in layers: [PlaybackSessionEngine.SceneRenderLayer]
    ) -> [PlaybackSessionEngine.SceneRenderLayer] {
        layers.filter { layer in
            layer.role == .outgoing || layer.role == .incoming
        }
    }

    private func isAcceptedSmartFillMotionScene(_ scene: PlaybackScene) -> Bool {
        switch scene.smartFillReadback?.sceneType {
        case .double, .triple, .single:
            return true
        case .fallback, nil:
            return false
        }
    }

    private func isSmartFillProductScene(_ scene: PlaybackScene) -> Bool {
        scene.smartFillReadback != nil || viewModel.isSmartFillPresentationModeActive
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
        if isAcceptedSmartFillMotionScene(scene) {
            return "acceptedMotion"
        }
        if scene.smartFillReadback == nil, viewModel.isSmartFillPresentationModeActive {
            return "smartFillLegacyNoMotion"
        }
        if isSmartFillProductScene(scene) {
            return "smartFillNoMotion"
        }
        return "legacy"
    }

    private func singleFilledScopeProbeValue(for scene: PlaybackScene) -> String {
        switch scene.smartFillReadback?.sceneType {
        case .single:
            return "smartFillSingle"
        case .fallback:
            return "smartFillFallback"
        case .double, .triple:
            return "none"
        case nil:
            return scene.photoSlots.count == 1 ? "legacySingle" : "legacyNonSmartFill"
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
                                    platform: smartFillMotionPlatform,
                                    reduceMotionEnabled: accessibilityReduceMotion
                                ),
                                motionProbeControlBarVisible: showControlBar,
                                onRendererDecoded: viewModel.rendererDecoded,
                                onRendererFailed: viewModel.rendererFailed
                            )
                            .opacity(layer.opacity)
                            .allowsHitTesting(layer.role == .stable && layer.opacity > 0)
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
                    // The read-only probe must use the same clock as the autoplay TimelineView,
                    // so root accessibility does not report stale progress.

                    Button(action: {}) {
                        Text(verbatim: "scene-presentation-frame-synchronized-probe")
                            .font(.system(size: 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(0.01)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.scenePresentation.frameSynchronized.summary")
                    .accessibilityLabel(viewModel.scenePresentationContractProbeLabel(for: snapshot))
                    .allowsHitTesting(false)
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: overlayAsset?.id, initial: true) { _, _ in
                syncExifOverlayPresentation(overlayAsset)
            }
            .onPreferenceChange(SmartFillMotionFrameProbePreferenceKey.self) { rows in
                smartFillMotionFrameProbeRows = rows
                #if DEBUG
                appendSmartFillMotionTraceSampleIfNeeded(rows: rows)
                #endif
            }
        }
    }
    func onPrevious() {
        guard viewModel.assets.count > 0 else { return }

        resetAutoHideTimer()
        viewModel.requestPreviousScene()
    }
    func onNext() {
        guard viewModel.assets.count > 0 else { return }

        resetAutoHideTimer()
        viewModel.requestNextScene()
    }
    func onPlayPause() {
        viewModel.toggleAutoPlayFromUserInteraction()
        resetAutoHideTimer()
    }
    func onSettings() {
        if AccessProtectionStore.shared.isEnabled {
            if AccessProtectionStore.shared.needsRecovery {
                showAccessProtectionRecoveryAlert = true
                resetAutoHideTimer()
                return
            }
            pinEntryErrorMessage = ""
            showPinEntrySheet = true
        } else {
            onOpenSettings?()
        }
        resetAutoHideTimer()
    }

    private func resetAutoHideTimer() {
        // The control bar must stay visible while the tip bubble is showing.

        guard !showPlaybackEntryHint else { return }
        autoHideBarTask?.cancel()
        autoHideBarTask = Task {

            try? await Task.sleep(for: .seconds(8))

            guard !Task.isCancelled else { return }
            await MainActor.run {
                showControlBar = false
            }
        }
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
        autoHideBarTask?.cancel()
        autoHideBarTask = nil

        withAnimation(.easeInOut(duration: 0.24)) {
            showControlBar = true
            showPlaybackEntryHint = true
        }
    }

    // Single dismiss path; the product rule is that tapping the bubble itself closes it.

    private func dismissPlaybackEntryHintIfNeeded() {
        guard showPlaybackEntryHint else {
            return
        }

        withAnimation(.easeInOut(duration: 0.20)) {
            showPlaybackEntryHint = false
        }

        resetAutoHideTimer()
    }

    private func refreshExifForegroundTone(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) async {
        guard let asset = visibleExifOverlayAsset else {
            exifForegroundTone = .lightText
            exifSamplingDebugSnapshot = nil
            return
        }

        if showsExifSamplingDebugOverlay {
            exifSamplingDebugSnapshot = nil
        }

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

            exifForegroundTone = .lightText
            exifSamplingDebugSnapshot = nil
            return
        }

        guard
            ExifForegroundAnalyzer.hasCachedImage(
                assetId: asset.id,
                downloadManager: viewModel.downloadManager
            )
        else {
            // Image not cached yet: do not guess the text color from empty data; rerun when the download state changes.

            exifForegroundTone = .lightText
            exifSamplingDebugSnapshot = nil
            return
        }

        exifForegroundTone = await ExifForegroundAnalyzer.resolveTone(
            assetId: asset.id,
            downloadManager: viewModel.downloadManager,
            backdropContext: backdropContext,
            profile: .iOS
        )

        if showsExifSamplingDebugOverlay {
            exifSamplingDebugSnapshot = await ExifForegroundAnalyzer.debugSnapshot(
                assetId: asset.id,
                downloadManager: viewModel.downloadManager,
                backdropContext: backdropContext
            )
        } else {
            exifSamplingDebugSnapshot = nil
        }
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
        // Sync autoplay settings on every playback entry so the long-lived ViewModel does not use stale values.
        viewModel.refreshAutoPlaySettingsFromStore()
        let settings = PlaybackSettingsStore().load() ?? PlaybackSettings()
        showExif = settings.showExif

        showDebugOverlay = PlatformCompat.playbackDebugPanelEnabled && settings.showDebugOverlay

        switch settings.defaultPlaybackMode {
        case .random:
            // When the default becomes shuffle, switch source only if not already shuffling.
            guard settings.defaultPlaybackMode != viewModel.currentPlaybackMode else { return }
            Task {
                await viewModel.switchPlaybackSource(to: .random)
            }
        case .filtered:
            let selection = FilterSelectionStore().load() ?? FilterSelection()
            // Without a usable filter, do not switch to filtered playback, to avoid an empty slideshow.
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

    private func syncAccessProtectionState() {
        isAccessProtectionEnabled = AccessProtectionStore.shared.isEnabled
    }

    private var exifHorizontalPadding: CGFloat {
        if isPhone { return isCompactHeight ? 10 : 14 }
        return 30
    }

    private func exifTopPadding(for safeAreaInsets: EdgeInsets) -> CGFloat {
        if isPhone {
            // Add an offset to the top safe area so the Dynamic Island does not cover EXIF.
            let minimumTopInset: CGFloat = isCompactHeight ? 24 : 52
            return max(safeAreaInsets.top, minimumTopInset) + (isCompactHeight ? 6 : 10)
        }
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

#Preview {
    if let testServer = ImmichServer.debugTestServerFromInfoPlist() {
        testServer.save()
        ImmichAPIService.shared.reloadServerConfiguration()
    }
    return SlideShowViewIOS(
        viewModel: SlideShowViewModel(),
        showsOnboardingPlaybackHint: true
    )
}

#endif
