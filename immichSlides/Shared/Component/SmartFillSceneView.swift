#if os(iOS) || os(tvOS)
//
//  SmartFillSceneView.swift
//  immichSlides
//

import SwiftUI
import SDWebImageSwiftUI

struct SmartFillSceneView: View {
    @ObservedObject var downloadManager: AssetsDownloadManager
    let scene: PlaybackScene
    let isCurrent: Bool
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let renderLayerRole: PlaybackSessionEngine.ScenePresentationLayerRole
    let navigationToken: UUID
    let rendererAttemptID: UUID?
    let motionContext: MotionRuntimeContext?
    var motionProbeControlBarVisible: Bool = false
    let onRendererDecoded: (SceneRendererIdentity) -> Void
    let onRendererFailed: (SceneRendererIdentity) -> Void

    var body: some View {
        if shouldUseLegacyRenderer, let asset = scene.primaryAsset {
            SlideItemView(
                downloadManager: downloadManager,
                asset: asset,
                isCurrent: isCurrent,
                size: size,
                safeAreaInsets: safeAreaInsets,
                sceneId: scene.id,
                renderLayerRole: renderLayerRole,
                navigationToken: navigationToken,
                diagnosticsModeRawValue: diagnosticsModeRawValue,
                motionContext: motionContext,
                rendererIdentity: SceneRendererIdentity(
                    generation: navigationToken,
                    attemptID: rendererAttemptID,
                    sceneID: scene.id,
                    slotID: scene.photoSlots.first?.id,
                    assetID: asset.id
                ),
                onRendererDecoded: onRendererDecoded,
                onRendererFailed: onRendererFailed
            )
            .overlay(alignment: .topLeading) {
                manifestProbe
            }
        } else {
            smartFillLayout
        }
    }

    private var shouldUseLegacyRenderer: Bool {
        guard let readback = scene.smartFillReadback else { return true }
        return readback.sceneType == .fallback && motionContext == nil
    }

    private var smartFillLayout: some View {
        let fullWidth = size.width + safeAreaInsets.leading + safeAreaInsets.trailing
        let fullHeight = size.height + safeAreaInsets.top + safeAreaInsets.bottom
        let backgroundOffsetX = (safeAreaInsets.trailing - safeAreaInsets.leading) / 2
        let backgroundOffsetY = (safeAreaInsets.bottom - safeAreaInsets.top) / 2

        return ZStack(alignment: .topLeading) {
            Color.black
            ForEach(scene.photoSlots) { slot in
                let frame = slot.planning.displayFrame.cgRect(in: CGSize(width: fullWidth, height: fullHeight))
                SmartFillSlotImageView(
                    downloadManager: downloadManager,
                    slot: slot,
                    isCurrent: isCurrent,
                    sceneId: scene.id,
                    renderLayerRole: renderLayerRole,
                    navigationToken: navigationToken,
                    motionContext: motionContext,
                    sceneType: scene.smartFillReadback?.sceneType,
                    manifestSlotRefs: scene.diagnosticSlotReferences(separator: "|"),
                    motionProbeControlBarVisible: motionProbeControlBarVisible,
                    rendererIdentity: SceneRendererIdentity(
                        generation: navigationToken,
                        attemptID: rendererAttemptID,
                        sceneID: scene.id,
                        slotID: slot.id,
                        assetID: slot.asset.id
                    ),
                    onRendererDecoded: onRendererDecoded,
                    onRendererFailed: onRendererFailed
                )
                .frame(width: frame.width, height: frame.height)
                .clipped()
                .position(x: frame.midX, y: frame.midY)
            }
            manifestProbe
        }
        .frame(width: fullWidth, height: fullHeight)
        .offset(x: backgroundOffsetX, y: backgroundOffsetY)
        .allowsHitTesting(isCurrent)
        .zIndex(isCurrent ? 1 : 0)
        .accessibilityIdentifier("slideshow.smartfill.scene")
    }

    private var diagnosticsModeRawValue: String {
        guard let readback = scene.smartFillReadback,
            readback.sceneType != .fallback
        else {
            return "single"
        }
        return "smartfill"
    }

    @ViewBuilder
    private var manifestProbe: some View {
        #if DEBUG
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("slideshow.smartfill.manifest.flag")
            .accessibilityLabel(
                scene.smartFillReadback?.qaDebugSummary ?? "sceneType=legacy;slotCount=1;fallback=legacy")
        #else
        EmptyView()
        #endif
    }
}

private struct SmartFillSlotImageView: View {
    @ObservedObject var downloadManager: AssetsDownloadManager
    let slot: PhotoSlot
    let isCurrent: Bool
    let sceneId: String
    let renderLayerRole: PlaybackSessionEngine.ScenePresentationLayerRole
    let navigationToken: UUID
    let motionContext: MotionRuntimeContext?
    let sceneType: PlaybackSmartFillSceneType?
    let manifestSlotRefs: String
    let motionProbeControlBarVisible: Bool
    let rendererIdentity: SceneRendererIdentity
    let onRendererDecoded: (SceneRendererIdentity) -> Void
    let onRendererFailed: (SceneRendererIdentity) -> Void

    #if DEBUG
    @State private var slotLifecycleRequestId: String?
    @State private var rendererImageConsumptionState = SmartFillRendererImageConsumptionState()
    #endif

    var body: some View {
        ZStack {
            switch slotReadiness {
            case let .ready(_, fullsizeURL):
                if let modifier = ImmichRequestModifier.create() {
                    let requestContext: [SDWebImageContextOption: Any] = [
                        .downloadRequestModifier: modifier
                    ]
                    GeometryReader { proxy in
                        let placement = SmartFillSourceCropPlacement.resolve(
                            slotSize: proxy.size,
                            sourceAspectRatio: slot.planning.sourceImage.smartFillAspectRatio,
                            cropRect: slot.planning.cropRect
                        )
                        WebImage(url: fullsizeURL, context: requestContext) { phase in
                            switch phase {
                            case let .success(image):
                                motionRenderedImage(
                                    image,
                                    slotSize: proxy.size,
                                    placement: placement
                                )
                            case .empty:
                                loadingPlaceholder()
                            case .failure:
                                failurePlaceholder(text: String(localized: "Failed to Load"))
                                    .onAppear {
                                        onRendererFailed(rendererIdentity)
                                    }
                            }
                        }
                        .onSuccess { image, _, cacheType in
                            #if DEBUG
                            downloadManager.recordRendererImageSuccessForDiagnostics(
                                requestId: slotLifecycleRequestId,
                                source: .rendererSmartFillSlot,
                                assetId: slot.asset.id,
                                size: .fullsize,
                                mode: .smartfill,
                                role: PlaybackImageRequestLifecycleRole.smartFillRendererRole(
                                    isCurrent: isCurrent,
                                    renderLayerRole: renderLayerRole
                                ),
                                navigationToken: navigationToken,
                                sceneId: sceneId,
                                url: fullsizeURL,
                                context: requestContext,
                                cacheType: cacheType,
                                imagePixelWidth: image.cgImage?.width,
                                imagePixelHeight: image.cgImage?.height
                            )
                            #endif
                            #if DEBUG
                            rendererImageConsumptionState.markFinished()
                            recordRendererImageConsumedIfNeeded()
                            #endif
                            onRendererDecoded(rendererIdentity)
                        }
                        #if DEBUG
                        .onChange(of: isCurrent, initial: true) { _, _ in
                            recordRendererImageConsumedIfNeeded()
                        }
                        #endif
                        .onAppear {
                            #if DEBUG
                            slotLifecycleRequestId = downloadManager.recordRendererImageRequestForDiagnostics(
                                source: .rendererSmartFillSlot,
                                assetId: slot.asset.id,
                                size: .fullsize,
                                mode: .smartfill,
                                role: PlaybackImageRequestLifecycleRole.smartFillRendererRole(
                                    isCurrent: isCurrent,
                                    renderLayerRole: renderLayerRole
                                ),
                                navigationToken: navigationToken,
                                sceneId: sceneId,
                                url: fullsizeURL,
                                context: requestContext,
                                contextHash: "SmartFillSlotImageView|downloadRequestModifier"
                            )
                            #endif
                        }
                    }
                    .clipped()
                } else if isCurrent {
                    loadingPlaceholder()
                } else {
                    Color.clear
                }
            case .pending:
                if isCurrent {
                    loadingPlaceholder()
                } else {
                    Color.clear
                }
            case .failed:
                if isCurrent {
                    failurePlaceholder(text: String(localized: "Failed to Load"))
                        .onAppear { onRendererFailed(rendererIdentity) }
                } else {
                    Color.clear
                        .onAppear { onRendererFailed(rendererIdentity) }
                }
            }
        }
    }

    private var slotReadiness: PlaybackSmartFillSlotReadiness {
        return PlaybackSmartFillSlotReadiness.resolve(
            assetId: slot.asset.id,
            fullsizeState: downloadManager.assetStates[slot.asset.id] ?? .notStarted,
            fullsizeURL: downloadManager.findURL(assetId: slot.asset.id, size: .fullsize)
        )
    }

    #if DEBUG
    /// A hidden incoming slot first records decode completion, then idempotently records consumed once it becomes
    /// current; takes no part in history/barrier.

    private func recordRendererImageConsumedIfNeeded() {
        guard rendererImageConsumptionState.consumeIfNeeded(isCurrent: isCurrent) else { return }
        downloadManager.recordRendererImageConsumedForDiagnostics(
            requestId: slotLifecycleRequestId
        )
    }
    #endif

    @ViewBuilder
    private func motionRenderedImage(
        _ image: Image,
        slotSize: CGSize,
        placement: SmartFillSourceCropPlacement
    ) -> some View {
        let resolvedFrame = resolvedMotionFrame(slotSize: slotSize, placement: placement)
        let imageFrame = resolvedFrame.imageFrame
        image
            .resizable()
            .frame(width: imageFrame.width, height: imageFrame.height)
            .offset(x: imageFrame.minX, y: imageFrame.minY)
            .overlay(alignment: .topLeading) {
                motionFrameProbe(
                    resolvedFrame: resolvedFrame,
                    presentationSampleTime: ProcessInfo.processInfo.systemUptime
                )
            }
    }

    private func resolvedMotionFrame(
        slotSize: CGSize,
        placement: SmartFillSourceCropPlacement
    ) -> SmartFillMotionRenderedSlotFrame {
        let geometry = MotionSlotRenderGeometry(
            slotSize: slotSize,
            imageFrameInSlot: placement.imageFrame
        )
        return SmartFillMotionSlotFrameResolver.resolve(
            SmartFillMotionSlotFrameInput(
                motionContext: motionContext,
                slotId: slot.id,
                assetId: slot.asset.id,
                renderGeometry: geometry,
                cropRectInSource: slot.planning.cropRect.motionUnitRect,
                focalSource: slot.planning.focalSummary?.motionFocalSource ?? .cropCenterFallback
            )
        )
    }

    @ViewBuilder
    private func motionFrameProbe(
        resolvedFrame: SmartFillMotionRenderedSlotFrame,
        presentationSampleTime: TimeInterval
    ) -> some View {
        #if DEBUG
        let label = motionFrameProbeLabel(
            resolvedFrame: resolvedFrame,
            presentationSampleTime: presentationSampleTime
        )
        Color.clear
            .frame(width: 1, height: 1)
            .preference(key: SmartFillMotionFrameProbePreferenceKey.self, value: [label])
            .accessibilityElement()
            .accessibilityIdentifier(
                "slideshow.smartfill.motionFrame.\(renderLayerRole.smartFillMotionProbeValue).\(MotionTransformResolver.diagnosticIdentityToken(slot.id))"
            )
            .accessibilityLabel(label)
        #else
        EmptyView()
        #endif
    }

    private func motionFrameProbeLabel(
        resolvedFrame: SmartFillMotionRenderedSlotFrame,
        presentationSampleTime: TimeInterval
    ) -> String {
        let transform = resolvedFrame.transform
        let progressFrame = resolvedFrame.progressFrame
        let focalSource = slot.planning.focalSummary?.motionFocalSource ?? MotionFocalSource.cropCenterFallback
        var fields = [
            "eventType=motionFrame",
            "sceneId=\(MotionTransformResolver.diagnosticIdentityToken(sceneId))",
            "slotId=\(MotionTransformResolver.diagnosticIdentityToken(slot.id))",
            "assetId=\(MotionTransformResolver.diagnosticIdentityToken(slot.asset.id))",
            "renderRole=\(renderLayerRole.smartFillMotionProbeValue)",
            "manifestSceneType=\(sceneType?.rawValue ?? "legacy")",
            "manifestSlotRefs=\(manifestSlotRefs)",
            "controlBarVisible=\(motionProbeControlBarVisible ? "true" : "false")",
            "appOverlayPollution=\(motionProbeControlBarVisible ? "controlBar" : "none")",
            "acceptedMotionScope=\(sceneType.isAcceptedSmartFillMotionProbeScene ? "true" : "false")",
            "singleFilledScope=\(sceneType.smartFillSingleFilledScopeProbeValue)",
            "visualFrameSource=slotPresentationFrame",
            "presentationModelDivergenceStatus=notRecomputed",
            "presentationSampleTime=\(String(format: "%.6f", presentationSampleTime))",
            "isDiscontinuous=false",
            "scale=\(String(format: "%.6f", transform.scale))",
            "translationX=\(String(format: "%.3f", transform.translationInSlot.width))",
            "translationY=\(String(format: "%.3f", transform.translationInSlot.height))",
            "renderedFrameMinX=\(String(format: "%.3f", resolvedFrame.imageFrame.minX))",
            "renderedFrameMinY=\(String(format: "%.3f", resolvedFrame.imageFrame.minY))",
            "renderedFrameWidth=\(String(format: "%.3f", resolvedFrame.imageFrame.width))",
            "renderedFrameHeight=\(String(format: "%.3f", resolvedFrame.imageFrame.height))",
            "presentationFrameMinX=\(String(format: "%.3f", resolvedFrame.imageFrame.minX))",
            "presentationFrameMinY=\(String(format: "%.3f", resolvedFrame.imageFrame.minY))",
            "presentationFrameWidth=\(String(format: "%.3f", resolvedFrame.imageFrame.width))",
            "presentationFrameHeight=\(String(format: "%.3f", resolvedFrame.imageFrame.height))",
            "modelFrameMinX=notRecomputed",
            "modelFrameMinY=notRecomputed",
            "modelFrameWidth=notRecomputed",
            "modelFrameHeight=notRecomputed",
            "anchorX=\(String(format: "%.6f", transform.anchorUnitPointInSlot.x))",
            "anchorY=\(String(format: "%.6f", transform.anchorUnitPointInSlot.y))",
            "focalSourceKind=\(focalSource.kind.smartFillMotionProbeValue)",
            "focalProvenance=\(focalSource.provenance.smartFillMotionProbeValue)",
            "zoomDirection=\(resolvedFrame.diagnostics?.zoomDirection.rawValue ?? "missing")",
            "stableSeedHash=\(resolvedFrame.diagnostics.map { String($0.stableSeedHash, radix: 16) } ?? "missing")",
            "seedInputSummary=\(resolvedFrame.diagnostics?.seedInputSummary ?? "missing")",
            "requestedTranslationX=\(resolvedFrame.diagnostics.map { String(format: "%.3f", $0.requestedTranslationInSlot.width) } ?? "missing")",
            "requestedTranslationY=\(resolvedFrame.diagnostics.map { String(format: "%.3f", $0.requestedTranslationInSlot.height) } ?? "missing")",
            "clampedTranslationX=\(resolvedFrame.diagnostics.map { String(format: "%.3f", $0.clampedTranslationInSlot.width) } ?? "missing")",
            "clampedTranslationY=\(resolvedFrame.diagnostics.map { String(format: "%.3f", $0.clampedTranslationInSlot.height) } ?? "missing")",
            "endTranslationX=\(resolvedFrame.diagnostics.map { String(format: "%.3f", $0.endTranslationInSlot.width) } ?? "missing")",
            "endTranslationY=\(resolvedFrame.diagnostics.map { String(format: "%.3f", $0.endTranslationInSlot.height) } ?? "missing")",
            "phaseAction=\(transform.phaseAction.smartFillMotionProbeValue)",
            "isIdentity=\(transform.isIdentity ? "true" : "false")"
        ]
        if let motionContext, let progressFrame {
            let stableVisibleStartTime = presentationSampleTime - motionContext.motionActiveTime
            let diagnosticsClock = MotionPacingPolicy(
                configuredPlaybackIntervalSeconds: motionContext.lifecycle.configuredInterval
            ).makePresentationClock(
                timelineStartTime: stableVisibleStartTime,
                stableVisibleStartTime: stableVisibleStartTime
            )
            fields.append(contentsOf: [
                "progressFrameStatus=available",
                "clockGeneration=\(progressFrame.identity.clockGeneration)",
                "progress=\(String(format: "%.6f", progressFrame.progress))",
                "progressSource=\(progressFrame.source.smartFillMotionProbeValue)",
                "presentationProgressSource=\(progressFrame.source.smartFillMotionProbeValue)",
                "extensionReason=none",
                "timelineStartTime=\(String(format: "%.6f", diagnosticsClock.timelineStartTime))",
                "stableVisibleStartTime=\(String(format: "%.6f", diagnosticsClock.stableVisibleStartTime))",
                "handoffStartDeadlineTime=\(String(format: "%.6f", diagnosticsClock.handoffStartDeadlineTime))",
                "removalDeadlineTime=\(String(format: "%.6f", diagnosticsClock.removalDeadlineTime))",
                "stableVisibleDuration=\(String(format: "%.6f", diagnosticsClock.stableVisibleDurationSeconds))",
                "transitionCompletionDelay=\(String(format: "%.6f", diagnosticsClock.removalDeadlineTime - diagnosticsClock.handoffStartDeadlineTime))"
            ])
        } else {
            fields.append(contentsOf: [
                "progressFrameStatus=missing",
                "progressFrameReason=\(motionContext == nil ? "motionContextMissing" : resolvedFrame.missingProgressReason ?? "progressFrameMissing")",
                "clockGeneration=missing",
                "progress=missing",
                "progressSource=missing",
                "presentationProgressSource=missing",
                "extensionReason=missing",
                "timelineStartTime=missing",
                "stableVisibleStartTime=missing",
                "handoffStartDeadlineTime=missing",
                "removalDeadlineTime=missing",
                "stableVisibleDuration=missing",
                "transitionCompletionDelay=missing"
            ])
        }
        return fields.joined(separator: ";")
    }

    @ViewBuilder
    private func loadingPlaceholder() -> some View {
        SlidePlaybackLoadingView(
            style: .slot,
            accessibilityIdentifier: "playback.loading.slot.indicator"
        )
    }

    @ViewBuilder
    private func failurePlaceholder(text: String) -> some View {
        ZStack {
            Color.black
            ProgressView(text)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        }
    }
}

struct SmartFillMotionFrameProbePreferenceKey: PreferenceKey {
    static var defaultValue: [String] { [] }

    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value.append(contentsOf: nextValue())
    }
}

struct SmartFillSourceCropPlacement: Equatable {
    let imageFrame: CGRect

    static func resolve(
        slotSize: CGSize,
        sourceAspectRatio: Double?,
        cropRect: PlaybackPlanningRect
    ) -> SmartFillSourceCropPlacement {
        let slotWidth = max(slotSize.width, .leastNonzeroMagnitude)
        let slotHeight = max(slotSize.height, .leastNonzeroMagnitude)
        let sourceAspectRatio = max(sourceAspectRatio ?? 1, .leastNonzeroMagnitude)
        let cropWidth = max(min(cropRect.width, 1), .leastNonzeroMagnitude)
        let cropHeight = max(min(cropRect.height, 1), .leastNonzeroMagnitude)
        let cropX = max(0, min(1 - cropWidth, cropRect.x))
        let cropY = max(0, min(1 - cropHeight, cropRect.y))

        let scale = max(
            slotWidth / (sourceAspectRatio * cropWidth),
            slotHeight / cropHeight
        )
        let imageWidth = sourceAspectRatio * scale
        let imageHeight = scale
        return SmartFillSourceCropPlacement(
            imageFrame: CGRect(
                x: -cropX * imageWidth,
                y: -cropY * imageHeight,
                width: imageWidth,
                height: imageHeight
            )
        )
    }
}

private extension PlaybackPlanningSourceImageSummary {
    var smartFillAspectRatio: Double? {
        let pixelSize = assetPixelSize ?? exifPixelSize
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return nil
        }
        return Double(pixelSize.width) / Double(pixelSize.height)
    }
}

private struct SmartFillRendererImageConsumptionState: Equatable {
    private var hasFinished = false
    private var didConsume = false

    mutating func markFinished() {
        hasFinished = true
    }

    mutating func consumeIfNeeded(isCurrent: Bool) -> Bool {
        guard hasFinished, isCurrent, !didConsume else { return false }
        didConsume = true
        return true
    }
}

private extension PlaybackPlanningRect {
    func cgRect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}

private extension PlaybackSessionEngine.ScenePresentationLayerRole {
    var motionProbeValue: String {
        switch self {
        case .stable:
            return "settled"
        case .outgoing:
            return "outgoing"
        case .incoming:
            return "incoming"
        }
    }
}

private extension MotionProgressSource {
    var motionProbeValue: String {
        switch self {
        case .sceneActiveTime:
            return "sceneActiveTime"
        case .presentationClock:
            return "presentationClock"
        }
    }
}

private extension MotionPhaseAction {
    var motionProbeValue: String {
        switch self {
        case .identity:
            return "identity"
        case .showStartWithoutAnimation:
            return "showStartWithoutAnimation"
        case .animateForwardAndHold:
            return "animateForwardAndHold"
        }
    }
}

private extension Optional where Wrapped == PlaybackSmartFillSceneType {
    var isAcceptedSmartFillMotionProbeScene: Bool {
        switch self {
        case .some(.double), .some(.triple), .some(.single):
            return true
        case .some(.fallback), .none:
            return false
        }
    }

    var smartFillSingleFilledScopeProbeValue: String {
        switch self {
        case .some(.single):
            return "smartFillSingle"
        case .some(.fallback):
            return "smartFillFallback"
        case .some(.double), .some(.triple):
            return "none"
        case .none:
            return "legacy"
        }
    }
}

private extension PlaybackSessionEngine.ScenePresentationLayerRole {
    var smartFillMotionProbeValue: String {
        motionProbeValue
    }
}

private extension MotionProgressSource {
    var smartFillMotionProbeValue: String {
        motionProbeValue
    }
}

private extension MotionFocalSourceKind {
    var smartFillMotionProbeValue: String {
        switch self {
        case .face:
            return "face"
        case .subject:
            return "subject"
        case .person:
            return "person"
        case .soloOnly:
            return "soloOnly"
        case .cropCenterFallback:
            return "cropCenterFallback"
        case .slotCenterFallback:
            return "slotCenterFallback"
        }
    }
}

private extension MotionFocalProvenance {
    var smartFillMotionProbeValue: String {
        switch self {
        case .runtimeFaceSummary:
            return "runtimeFaceSummary"
        case .runtimeSubjectSummary:
            return "runtimeSubjectSummary"
        case .cropRectFallback:
            return "cropRectFallback"
        case .slotCenterFallback:
            return "slotCenterFallback"
        case .futurePersonAdapter:
            return "futurePersonAdapter"
        case .futureSoloOnlyAdapter:
            return "futureSoloOnlyAdapter"
        }
    }
}

private extension MotionPhaseAction {
    var smartFillMotionProbeValue: String {
        motionProbeValue
    }
}
#endif
