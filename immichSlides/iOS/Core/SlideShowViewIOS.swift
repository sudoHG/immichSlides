#if os(iOS)
//
//  SlideShowViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.

import SwiftUI
import UIKit

private enum PlaybackViewMetrics {
    static let controlBarProtectionHeightPoints: Double = 150
    static let controlBarAutoHideDelaySeconds: Int = 8
    static let largeSafeAreaThresholdPoints: CGFloat = 80
}

struct SlideShowViewIOS: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: SlideShowViewModel
    // Navigation to Settings is handled by the parent router.
    var onOpenSettings: (() -> Void)? = nil
    // Only marks whether we came from first launch; showing the tip also depends on local persisted state.

    var shouldShowOnboardingPlaybackHint: Bool = false

    @State var isDebugOverlayVisible: Bool = false

    @State var isExifVisible: Bool = true

    @State var exifForegroundTone: ExifForegroundTone = .lightText

    @State var exifFrameInSurfaceSpace: CGRect = .zero

    #if DEBUG
    @State var exifSamplingDebugSnapshot: ExifSamplingDebugSnapshot? = nil
    #endif
    // Keep the last EXIF-capable asset so SmartFill with or without EXIF can reuse the single-photo panel morph.
    @State var retainedExifOverlayAsset: Asset? = nil
    @State var isRenderedExifOverlayVisible: Bool = false

    @State private var isPinEntrySheetPresented: Bool = false

    @State private var pinEntryErrorMessage: String = ""

    @State private var isAccessProtectionRecoveryAlertPresented: Bool = false

    @State private var isPlaybackEntryHintVisible: Bool = false
    private let playbackEntryHintStore = PlaybackEntryHintStore()

    @State var isControlBarVisible: Bool = true

    @State private var autoHideBarTask: Task<Void, Never>? = nil
    @State var smartFillMotionTraceLines: [String] = []
    @State var smartFillMotionTraceBuffer = SmartFillMotionTraceBuffer()
    @State var smartFillMotionTraceStatus: String = "idle"
    @State var hasSmartFillMotionTraceStarted: Bool = false
    @State var smartFillMotionTraceFilePath: String = ""
    @State var smartFillMotionTraceLineCount: Int = 0
    @State var smartFillMotionTraceWaitStartedAt: TimeInterval = 0
    @State var smartFillMotionTraceCollectionStartedAt: TimeInterval = 0
    @State var smartFillMotionTraceNextSampleIndex: Int = 0
    @State var smartFillMotionFrameProbeRows: [String] = []
    var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    var smartFillMotionPlatform: MotionPlatform { isPhone ? .iOS : .iPadOS }
    var isCompactHeight: Bool { verticalSizeClass == .compact }
    // Multi-photo SmartFill keeps the subject readable first, so EXIF does not cover faces.
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
    // Preview and original cache states belong in the key so a later download still retriggers the audit.

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
            profile: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
            orientation: surfaceSize.width >= surfaceSize.height ? .landscape : .portrait,
            safeAreaClass: smartFillSafeAreaClass(safeAreaInsets)
        )
        return [
            surface.internalSurfaceFingerprint,
            isControlBarVisible ? "bar-visible" : "bar-hidden",
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
        if largestInset < PlaybackViewMetrics.largeSafeAreaThresholdPoints {
            return "safeA"
        }
        return "safeB"
    }

    // UI tests can turn off the one-time tip so it does not pollute the existing playback screenshot baselines.

    private var isPlaybackEntryHintDisabledForUITests: Bool {
        PlatformCompat.shouldDisablePlaybackEntryHintForTesting
    }

    // The diagnostic overlay is for UI tests and local diagnostics only;
    // normal playback never shows the red frame or the sample thumbnail.

    #if DEBUG
    var shouldShowExifSamplingDebugOverlay: Bool {
        PlatformCompat.shouldShowExifSamplingDebugOverlay
    }
    #endif

    private var shouldExposeExifForegroundToneProbeForTesting: Bool {
        PlatformCompat.shouldExposeUITestProbes
    }

    private var shouldExposeCurrentAssetIDProbeForTesting: Bool {
        #if DEBUG
        return PlatformCompat.shouldExposeUITestProbes
        #else
        return false
        #endif
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

    var shouldCollectSmartFillMotionTraceForTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["UI_TEST_COLLECT_SMARTFILL_MOTION_TRACE"] == "1"
        #else
        false
        #endif
    }

    private var shouldExposePlaybackRequestLifecycleProbeForTesting: Bool {
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
                                        #if DEBUG
                                        .overlay {
                                            if shouldShowExifSamplingDebugOverlay {

                                                Rectangle()
                                                .fill(Color.red.opacity(0.10))
                                                .overlay(
                                                    Rectangle()
                                                        .stroke(Color.red, lineWidth: 2)
                                                )
                                            }
                                        }
                                        #endif
                                        .animation(
                                            .easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration),
                                            value: retainedExifOverlayAsset?.id)
                                    }
                                    .padding(.top, exifTopPadding(for: geometry.safeAreaInsets))
                                    .padding(.trailing, exifHorizontalPadding)
                                    .overlay(alignment: .topTrailing) {
                                        // UI tests only: release builds keep the tone anchor out of VoiceOver.
                                        if shouldExposeExifForegroundToneProbeForTesting {
                                            Color.clear
                                                .frame(width: 1, height: 1)
                                                .accessibilityElement()
                                                .accessibilityIdentifier("slideshow.exifForegroundTone.flag")
                                                .accessibilityLabel(exifForegroundTone.debugAccessibilityLabel)
                                        }
                                    }
                                    Spacer()
                                }
                                .opacity(isRenderedExifOverlayVisible ? 1 : 0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(!isRenderedExifOverlayVisible)
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onTapGesture {

                    isControlBarVisible = true
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
                #if DEBUG
                if shouldShowExifSamplingDebugOverlay {
                    exifSamplingDebugOverlay(
                        surfaceSize: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
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
                smartFillMotionFrameProbeOverlay()
                #if DEBUG
                if shouldExposeCurrentAssetIDProbeForTesting {
                    // The history contract reads the published visible scene identity,
                    // so this probe cannot live only in the single-photo EXIF branch.

                    Button(action: {}) {
                        // localization-audit: Stable UI test probe contract.
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
                #endif
                #if DEBUG
                if PlatformCompat.shouldExposeScenePresentationContractProbeForTesting {
                    // The probe spans loading to the first frame; the no-op button is only a stable accessibility leaf.

                    Button(action: {}) {
                        // localization-audit: Stable UI test probe contract.
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
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("slideshow.historyLedger.summary.flag")
                        .accessibilityLabel(viewModel.playbackHistoryLedgerDiagnosticsSummaryJSON)
                }
                #endif
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

                VStack {
                    Spacer()
                    if isControlBarVisible {
                        SlideshowControlBarView(
                            isAutoPlay: $viewModel.isAutoPlay,
                            isPreviousEnabled: viewModel.canRequestPreviousScene,
                            onPrevious: onPrevious,
                            onNext: onNext,
                            onPlayPause: onPlayPause,
                            onSettings: onSettings,
                            shouldShowEntryHintBubble: isPlaybackEntryHintVisible,
                            entryHintContent: playbackEntryHintContent,
                            onEntryHintTap: dismissPlaybackEntryHintIfNeeded
                        )
                        .padding(.bottom, 40)
                        .transition(.opacity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(true)
                .animation(.easeInOut(duration: 0.3), value: isControlBarVisible)
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
            maybePresentPlaybackEntryHintIfNeeded()
            // Do not auto-hide the control bar while the tip bubble is showing.

            if isPlaybackEntryHintVisible {
                autoHideBarTask?.cancel()
                autoHideBarTask = nil
            } else {
                resetAutoHideTimer()
            }
        }
        #if DEBUG
        .task(id: visionAuditTriggerKey) {
            guard PlatformCompat.isPlaybackDebugPanelEnabled, isDebugOverlayVisible,
                viewModel.shouldRunDebugVisionFaceAudit
            else {
                // Shuffle playback can open the debug panel but does not run the Vision probe.

                viewModel.clearVisionFaceAuditState()
                return
            }
            await viewModel.refreshVisionFaceAuditForCurrentAsset()
        }
        #endif
        .onChange(of: accessibilityReduceMotion) { _, isEnabled in
            viewModel.updateSmartFillMotionReduceMotionEnabled(isEnabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Resync playback settings once after returning from Settings.
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

    private func onPrevious() {
        guard viewModel.assets.count > 0 else { return }

        resetAutoHideTimer()
        viewModel.requestPreviousScene()
    }
    private func onNext() {
        guard viewModel.assets.count > 0 else { return }

        resetAutoHideTimer()
        viewModel.requestNextScene()
    }
    private func onPlayPause() {
        viewModel.toggleAutoPlayFromUserInteraction()
        resetAutoHideTimer()
    }
    private func onSettings() {
        if AccessProtectionStore.shared.isEnabled {
            if AccessProtectionStore.shared.isRecoveryNeeded {
                isAccessProtectionRecoveryAlertPresented = true
                resetAutoHideTimer()
                return
            }
            pinEntryErrorMessage = ""
            isPinEntrySheetPresented = true
        } else {
            onOpenSettings?()
        }
        resetAutoHideTimer()
    }

    private func resetAutoHideTimer() {
        // The control bar must stay visible while the tip bubble is showing.

        guard !isPlaybackEntryHintVisible else { return }
        autoHideBarTask?.cancel()
        autoHideBarTask = Task {

            try? await Task.sleep(for: .seconds(PlaybackViewMetrics.controlBarAutoHideDelaySeconds))

            guard !Task.isCancelled else { return }
            await MainActor.run {
                isControlBarVisible = false
            }
        }
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
        autoHideBarTask?.cancel()
        autoHideBarTask = nil

        withAnimation(.easeInOut(duration: 0.24)) {
            isControlBarVisible = true
            isPlaybackEntryHintVisible = true
        }
    }

    // Single dismiss path; the product rule is that tapping the bubble itself closes it.

    private func dismissPlaybackEntryHintIfNeeded() {
        guard isPlaybackEntryHintVisible else {
            return
        }

        withAnimation(.easeInOut(duration: 0.20)) {
            isPlaybackEntryHintVisible = false
        }

        resetAutoHideTimer()
    }

}

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

#Preview {
    if let testServer = ImmichServer.testServerFromInfoPlistForTesting() {
        testServer.save()
        ImmichAPIService.shared.reloadServerConfiguration()
    }
    return SlideShowViewIOS(
        viewModel: SlideShowViewModel(),
        shouldShowOnboardingPlaybackHint: true
    )
}

#endif
