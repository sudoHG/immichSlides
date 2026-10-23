import CoreGraphics
import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedPlaybackRuntimeIsolation)
struct SmartFillMotionRuntimeIntegrationTests {
    private let probeSlotSizePoints = CGSize(width: 400, height: 700)
    private let portraitProbeSlotSizePoints = CGSize(width: 393, height: 852)
    private let iPhonePortraitPlanningPixelSize = PlaybackPlanningPixelSize(width: 1179, height: 2556)

    enum RotationSceneKind: CaseIterable, Equatable, Sendable {
        case single, double, fallback

        var pixelSize: PlaybackPlanningPixelSize {
            switch self {
            case .single: PlaybackPlanningPixelSize(width: 2400, height: 4800)
            case .double: PlaybackPlanningPixelSize(width: 1800, height: 2000)
            case .fallback: PlaybackPlanningPixelSize(width: 3840, height: 2160)
            }
        }

        var sceneType: PlaybackSmartFillSceneType {
            switch self {
            case .single: .single
            case .double: .double
            case .fallback: .fallback
            }
        }
    }

    @Test(arguments: [false, true], RotationSceneKind.allCases)
    func `rotation reframes the visible assets without changing history or the playing or paused clock`(
        isPaused: Bool, kind: RotationSceneKind
    ) throws {
        var now = 100.0
        let vm = makeSmartFillViewModel(
            assetPixelSize: kind.pixelSize,
            timestamp: { now })
        vm.autoPlayInterval = 30
        func settleVisibleScene() throws {
            let layer = try #require(vm.sceneRenderSnapshot.layers.last)
            let scene = try #require(vm.scene(for: layer))
            decodeAllRenderers(in: scene, layer: layer, viewModel: vm)
            now += 0.1
            vm.incomingBecameVisible(
                ScenePresentationLayerIdentity(
                    generation: layer.identity.generation, sceneID: layer.identity.sceneID, layerID: "scene-root"))
            now = try #require(vm.fireScheduledScenePresentationWakeUpForTesting())
            #expect(vm.sceneRenderSnapshot.underlyingPhase == .stablePhoto)
        }
        try settleVisibleScene()
        vm.requestNextScene()
        try settleVisibleScene()
        let stableStartedAt = now
        now += 2
        if isPaused { vm.toggleAutoPlayFromUserInteraction() }
        let before = vm.sceneRenderSnapshot
        let layer = try #require(before.layers.first)
        let original = try #require(vm.scene(for: layer))
        #expect(original.photoSlots.count == (kind == .double ? 2 : 1))
        #expect(original.smartFillReadback?.sceneType == kind.sceneType)
        let history = vm.playbackHistoryLedgerDiagnosticsSummaryJSON
        let recipes = vm.retainedPlaybackHistoryRecipesForTesting
        #expect(recipes.count == 2)
        func assertRetainedRecipes() {
            let retained = vm.retainedPlaybackHistoryRecipesForTesting
            #expect(retained.map(\.id) == recipes.map(\.id))
            #expect(retained.map(\.planningSurface) == recipes.map(\.planningSurface))
            #expect(retained.map { $0.photoSlots.map(\.planning) } == recipes.map { $0.photoSlots.map(\.planning) })
        }
        let navigationToken = vm.targetTransitionToken
        let cursor = vm.smartFillCandidateCursorIndexForTesting
        let landscape = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2556, height: 1179), profile: .iPhone, orientation: .landscape)

        vm.smartFillMotionPreparedSlotPreloadHookForTesting = { _ in }
        vm.clearPreparedSmartFillRingForTesting()
        let preparedCursor = try #require(vm.currentPreparedSmartFillSourceCursorForTesting)
        let preparedRequest = try #require(vm.capturePreparedSmartFillPlanRequestForTesting(startingAt: preparedCursor))
        let preparedResult = try #require(SmartFillPreparedPlanBuilder.makeResult(for: preparedRequest))
        #expect(vm.applyPreparedSmartFillPlanResultForTesting(preparedResult, request: preparedRequest) == .applied)
        let preparedAssets = try #require(vm.preparedSmartFillNextAssetIdsForTesting)
        #expect(!preparedAssets.isEmpty)
        let protection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemTopObstruction(
                    rect: PlaybackProtectionRect(x: 0, y: 0, width: 1, height: 0.05),
                    activeConditionSummary: "orientation=landscape"))
        ])
        vm.updateSmartFillSurface(landscape, protectionSnapshot: protection)
        #expect(vm.preparedSmartFillNextAssetIdsForTesting == nil)
        #expect(vm.applyPreparedSmartFillPlanResultForTesting(preparedResult, request: preparedRequest) == .stale)

        let reframed = try #require(vm.scene(for: layer))
        #expect(reframed.id == original.id)
        #expect(reframed.playbackSessionId == original.playbackSessionId)
        #expect(reframed.sequence == original.sequence)
        #expect(reframed.assetIds == original.assetIds)
        #expect(reframed.photoSlots.map(\.id) == original.photoSlots.map(\.id))
        #expect(vm.playbackHistoryLedgerDiagnosticsSummaryJSON == history)
        #expect(vm.targetTransitionToken == navigationToken)
        #expect(vm.smartFillCandidateCursorIndexForTesting == cursor)
        #expect(vm.sceneRenderSnapshot == before)
        #expect(reframed.smartFillReadback?.surfaceKey == landscape.surfaceKey)
        #expect(reframed.smartFillReadback?.sceneType == original.smartFillReadback?.sceneType)
        #expect(reframed.smartFillReadback?.fallbackReason == original.smartFillReadback?.fallbackReason)
        #expect(reframed.photoSlots.allSatisfy { $0.planning.faceProtection == .notApplied })
        assertRetainedRecipes()
        let context = try #require(vm.motionRuntimeContext(for: layer, platform: .iOS, isReduceMotionEnabled: false))
        func motionFrame(_ slot: PhotoSlot, surface: PlaybackSmartFillSurface) throws
            -> SmartFillMotionRenderedSlotFrame
        {
            let frame = slot.planning.displayFrame
            let size = CGSize(
                width: Double(surface.pixelSize.width) * frame.width,
                height: Double(surface.pixelSize.height) * frame.height)
            let pixels = try #require(slot.planning.sourceImage.assetPixelSize)
            let placement = SmartFillSourceCropPlacement.resolve(
                slotSize: size, sourceAspectRatio: Double(pixels.width) / Double(pixels.height),
                cropRect: slot.planning.cropRect)
            return SmartFillMotionSlotFrameResolver.resolve(
                SmartFillMotionSlotFrameInput(
                    motionContext: context, slot: slot,
                    renderGeometry: MotionSlotRenderGeometry(slotSize: size, imageFrameInSlot: placement.imageFrame)))
        }
        let portrait = PlaybackSmartFillSurface(
            pixelSize: iPhonePortraitPlanningPixelSize,
            profile: .iPhone, orientation: .portrait)
        for (originalSlot, slot) in zip(original.photoSlots, reframed.photoSlots) {
            let frame = slot.planning.displayFrame
            let crop = slot.planning.cropRect
            let pixels = try #require(
                slot.planning.sourceImage.assetPixelSize ?? slot.planning.sourceImage.exifPixelSize)
            let sourceAspect = Double(pixels.width) / Double(pixels.height)
            assertApproximatelyEqual(
                sourceAspect * crop.width / crop.height, landscape.aspectRatio * frame.width / frame.height)
            let originalMotion = try motionFrame(originalSlot, surface: portrait)
            let reframedMotion = try motionFrame(slot, surface: landscape)
            #expect(reframedMotion.diagnostics?.stableSeedHash == originalMotion.diagnostics?.stableSeedHash)
            #expect(reframedMotion.diagnostics?.zoomDirection == originalMotion.diagnostics?.zoomDirection)
            assertApproximatelyEqual(reframedMotion.transform.scale, originalMotion.transform.scale)
        }
        #expect(reframed.photoSlots.map { $0.planning.cropRect } != original.photoSlots.map { $0.planning.cropRect })
        if kind == .double {
            #expect(
                reframed.photoSlots.map { $0.planning.displayFrame }
                    != original.photoSlots.map { $0.planning.displayFrame })
        }
        now += 1
        let laterLayer = try #require(vm.sceneRenderSnapshot.layers.first)
        assertApproximatelyEqual(laterLayer.motionActiveTime, layer.motionActiveTime + (isPaused ? 0 : 1))
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: iPhonePortraitPlanningPixelSize, profile: .iPhone, orientation: .portrait))
        let returned = try #require(vm.scene(for: layer))
        #expect(returned.assetIds == original.assetIds)
        #expect(returned.photoSlots.map { $0.planning.cropRect } == original.photoSlots.map { $0.planning.cropRect })
        let interval = try #require(before.frozenInterval)
        let expectedDeadline = isPaused ? now + interval - before.activeTime : stableStartedAt + interval
        if isPaused { vm.toggleAutoPlayFromUserInteraction() }
        let deadline = try #require(vm.scenePresentationWakeUpScheduler.scheduledDeadlineForTesting)
        assertApproximatelyEqual(deadline, expectedDeadline)

        vm.updateSmartFillSurface(landscape, protectionSnapshot: protection)
        vm.requestPreviousScene()
        try settleVisibleScene()
        let previousLayer = try #require(vm.sceneRenderSnapshot.layers.first)
        let previous = try #require(vm.scene(for: previousLayer))
        #expect(previous.id == recipes[0].id)
        #expect(previous.assetIds == recipes[0].assetIds)
        #expect(previous.smartFillReadback?.surfaceKey == landscape.surfaceKey)
        assertRetainedRecipes()

        vm.requestNextScene()
        let incoming = try #require(vm.sceneRenderSnapshot.layers.last)
        decodeAllRenderers(in: try #require(vm.scene(for: incoming)), layer: incoming, viewModel: vm)
        now += 0.1
        let crossfade = vm.sceneRenderSnapshot
        #expect(crossfade.phase == .transition)
        #expect(crossfade.layers.count == 2)
        for fadingLayer in crossfade.layers {
            let fadingScene = try #require(vm.scene(for: fadingLayer))
            #expect(fadingScene.smartFillReadback?.surfaceKey == landscape.surfaceKey)
            for slot in fadingScene.photoSlots {
                let pixels = try #require(slot.planning.sourceImage.assetPixelSize)
                let crop = slot.planning.cropRect
                let frame = slot.planning.displayFrame
                assertApproximatelyEqual(
                    Double(pixels.width) / Double(pixels.height) * crop.width / crop.height,
                    landscape.aspectRatio * frame.width / frame.height)
            }
        }
        vm.updateSmartFillSurfaceForTesting(portrait)
        for fadingLayer in crossfade.layers {
            #expect(vm.scene(for: fadingLayer)?.smartFillReadback?.surfaceKey == portrait.surfaceKey)
        }
        try settleVisibleScene()
        let replayed = try #require(vm.safeCurrentScene)
        #expect(replayed.id == original.id)
        #expect(replayed.assetIds == original.assetIds)
        #expect(replayed.photoSlots.map(\.planning) == original.photoSlots.map(\.planning))
        #expect(vm.playbackHistoryLedgerDiagnosticsSummaryJSON == history)
        assertRetainedRecipes()
    }

    enum ProjectionCacheUpdate: CaseIterable, Sendable {
        case publishTiming, displayContent, surface
    }

    @Test(arguments: ProjectionCacheUpdate.allCases)
    func `surface projections retain protection only updates until timing content or geometry invalidates the cache`(
        update: ProjectionCacheUpdate
    ) throws {
        let vm = makeSmartFillViewModel(timestamp: { 100 })
        let recipe = try #require(vm.safeCurrentScene)
        let owner = PlaybackSessionOwner()
        owner.resetPlayback(with: recipe.photoSlots.map(\.asset), initialScene: recipe, reason: .poolReloaded)
        let landscape = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2556, height: 1179), profile: .iPhone, orientation: .landscape)
        owner.updatePresentationSurface(landscape, protectionSnapshot: .empty)
        let initialProjection = try #require(owner.currentScene)
        let protection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemTopObstruction(
                    rect: PlaybackProtectionRect(x: 0, y: 0, width: 1, height: 0.05),
                    activeConditionSummary: "orientation=landscape"))
        ])

        owner.updatePresentationSurface(landscape, protectionSnapshot: protection)
        #expect(owner.currentScene?.protectionSnapshot == initialProjection.protectionSnapshot)
        #expect(owner.currentScene?.photoSlots.map(\.planning) == initialProjection.photoSlots.map(\.planning))
        switch update {
        case .publishTiming:
            owner.recordScenePublishTiming(
                sceneID: initialProjection.id, actionTimestamp: 101, scenePublishTimestamp: 101.5)
            let readback = try #require(owner.currentScene?.smartFillReadback)
            #expect(readback.actionTimestamp == 101)
            #expect(readback.scenePublishTimestamp == 101.5)
            #expect(readback.qaDebugSummary.contains("actionToSceneLatencyMs=500.000"))
        case .displayContent:
            let primaryAsset = try #require(recipe.primaryAsset)
            #expect(owner.replaceCurrentDisplayContent(with: PlaybackScene(primaryAsset: primaryAsset)))
            #expect(owner.currentScene?.smartFillReadback == nil)
            #expect(owner.replaceCurrentDisplayContent(with: recipe))
            #expect(owner.currentScene?.smartFillReadback?.surfaceKey == landscape.surfaceKey)
        case .surface:
            let wider = PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2700, height: 1179), profile: .iPhone,
                orientation: .landscape)
            owner.updatePresentationSurface(wider, protectionSnapshot: protection)
            #expect(owner.currentScene?.planningSurface?.pixelSize == wider.pixelSize)
            #expect(
                owner.currentScene?.photoSlots.map { $0.planning.cropRect }
                    != initialProjection.photoSlots.map { $0.planning.cropRect })
        }
        #expect(owner.currentScene?.protectionSnapshot == protection)
    }

    @Test
    func `a full scene snapshot active time is the only product motion progress source`() throws {
        var now = 100.0
        let vm = makeSmartFillViewModel(timestamp: { now })
        let initialLayer = try #require(vm.sceneRenderSnapshot.layers.first)
        let scene = try #require(vm.scene(for: initialLayer))

        #expect(vm.sceneRenderSnapshot.phase == .loading)
        #expect(initialLayer.role == .incoming)
        #expect(!initialLayer.isPresentationReady)
        assertApproximatelyEqual(initialLayer.motionActiveTime, 0)

        decodeAllRenderers(in: scene, layer: initialLayer, viewModel: vm)
        let readyLayer = try #require(vm.sceneRenderSnapshot.layers.first)
        #expect(vm.sceneRenderSnapshot.phase == .incomingFromLoading)
        #expect(readyLayer.isPresentationReady)

        now = 102.5
        let progressedLayer = try #require(
            vm.sceneRenderSnapshot.layers.first { $0.identity == readyLayer.identity }
        )
        let context = try #require(
            vm.motionRuntimeContext(
                for: progressedLayer,
                platform: .iOS,
                isReduceMotionEnabled: false
            ))
        let slot = try #require(scene.photoSlots.first)
        let progressFrame = context.progressFrame(
            slotId: slot.id,
            assetId: slot.asset.id
        )

        assertApproximatelyEqual(progressedLayer.motionActiveTime, 2.5)
        assertApproximatelyEqual(context.rawProgress, 0.5)
        #expect(progressFrame.source == .sceneActiveTime)
        assertApproximatelyEqual(progressFrame.progress, 0.5)

        vm.incomingBecameVisible(
            ScenePresentationLayerIdentity(
                generation: readyLayer.identity.generation,
                sceneID: readyLayer.identity.sceneID,
                layerID: "scene-root"
            )
        )
        let probeLabel = vm.scenePresentationContractProbeLabel(for: vm.sceneRenderSnapshot)
        #expect(probeLabel.contains("historyCount=1"))
        #expect(probeLabel.contains("visibleTickCommittedHistory=true"))
    }

    @Test
    func `a photo held while a manual target loads rests at the end of its coverage-safe motion`() throws {
        var now = 100.0
        let vm = makeSmartFillViewModel(timestamp: { now })
        let firstLayer = try #require(vm.sceneRenderSnapshot.layers.first)
        let firstScene = try #require(vm.scene(for: firstLayer))
        decodeAllRenderers(in: firstScene, layer: firstLayer, viewModel: vm)
        now = 101
        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        #expect(vm.sceneRenderSnapshot.underlyingPhase == .stablePhoto)

        vm.requestNextScene()
        #expect(vm.sceneRenderSnapshot.underlyingPhase == .grace)
        let withinWindow = try #require(vm.sceneRenderSnapshot.layers.first { $0.identity == firstLayer.identity })
        let withinContext = try #require(
            vm.motionRuntimeContext(for: withinWindow, platform: .iOS, isReduceMotionEnabled: false))
        assertApproximatelyEqual(withinContext.motionActiveTime, withinWindow.motionActiveTime)

        now = 1_000
        let held = try #require(vm.sceneRenderSnapshot.layers.first { $0.identity == firstLayer.identity })
        let context = try #require(vm.motionRuntimeContext(for: held, platform: .iOS, isReduceMotionEnabled: false))
        #expect(held.motionActiveTime > context.lifecycle.longestVisibleMotionDuration)
        assertApproximatelyEqual(context.rawProgress, context.maximumCoverageProgress)
    }

    @Test
    func `the contract probe records a manual crossfade as a steady blend of both photos`() throws {
        var now = 100.0
        let vm = makeSmartFillViewModel(timestamp: { now })
        let (firstLayer, secondLayer) = try holdSecondSceneBehindFirst(in: vm, advanceClock: { now += 1 })
        let secondScene = try #require(vm.scene(for: secondLayer))
        now = 101.2
        decodeAllRenderers(in: secondScene, layer: secondLayer, viewModel: vm)
        #expect(vm.sceneRenderSnapshot.underlyingPhase == .transition)
        for step in 0...6 {
            now = 101.2 + Double(step) * 0.05
            _ = vm.scenePresentationContractProbeLabel(for: vm.sceneRenderSnapshot)
        }

        let evidence = try #require(probeCrossfadeEvidence(in: vm))
        #expect(evidence.outgoingID == firstLayer.identity.privateIdentifier)
        #expect(evidence.peakBlendOpacity >= SceneTransitionDiagnostic.minimumBlendOpacity)
        #expect(!evidence.didOutgoingProgressRewind)
        #expect(evidence.lastOutgoingProgress > evidence.firstOutgoingProgress)
    }

    @Test
    func `the contract probe records a switch or an opaque cut without a blend and motion that goes backwards`()
        throws
    {
        var now = 100.0
        let vm = makeSmartFillViewModel(timestamp: { now })
        let (firstLayer, secondLayer) = try holdSecondSceneBehindFirst(in: vm, advanceClock: { now += 1 })
        let base = vm.sceneRenderSnapshot
        func frame(
            outgoing: PlaybackSessionEngine.SceneRenderLayer, opacity: Double, motionActiveTime: TimeInterval,
            incoming: PlaybackSessionEngine.SceneRenderLayer, incomingOpacity: Double? = nil
        ) -> PlaybackSessionEngine.SceneRenderSnapshot {
            let layers = [
                (outgoing, PlaybackSessionEngine.ScenePresentationLayerRole.outgoing, opacity, motionActiveTime),
                (incoming, .incoming, incomingOpacity ?? 1 - opacity, 0)
            ]
            .map { layer, role, opacity, activeTime in
                PlaybackSessionEngine.SceneRenderLayer(
                    identity: layer.identity, role: role, opacity: opacity, motionActiveTime: activeTime,
                    isMotionEnabled: true, fadeStartTime: nil, fadeDuration: 0, isPresentationReady: true)
            }
            return PlaybackSessionEngine.SceneRenderSnapshot(
                phase: .transition, underlyingPhase: .transition, layers: layers, currentTarget: base.currentTarget,
                frozenInterval: base.frozenInterval, activeTime: base.activeTime, suspensionReasons: [],
                isReduceMotionEnabled: false, isPendingTargetReady: true)
        }

        for _ in 0...2 {
            _ = vm.scenePresentationContractProbeLabel(
                for: frame(outgoing: firstLayer, opacity: 0, motionActiveTime: 1, incoming: secondLayer))
        }
        // The incoming photo cut in fully opaque on top hides the outgoing one, whatever that one's opacity.
        _ = vm.scenePresentationContractProbeLabel(
            for: frame(outgoing: firstLayer, opacity: 1, motionActiveTime: 1, incoming: secondLayer, incomingOpacity: 1)
        )
        let hardSwitch = try #require(probeCrossfadeEvidence(in: vm))
        #expect(hardSwitch.peakBlendOpacity < SceneTransitionDiagnostic.minimumBlendOpacity)

        for (opacity, activeTime) in [(0.8, 2.0), (0.6, 2.1), (0.4, 1.5)] {
            _ = vm.scenePresentationContractProbeLabel(
                for: frame(outgoing: secondLayer, opacity: opacity, motionActiveTime: activeTime, incoming: firstLayer))
        }
        let rewound = try #require(probeCrossfadeEvidence(in: vm))
        #expect(rewound.outgoingID == secondLayer.identity.privateIdentifier)
        #expect(rewound.didOutgoingProgressRewind)
        #expect(rewound.lowestOutgoingProgress < rewound.firstOutgoingProgress)
    }

    @Test
    func `suspension freezes the snapshot active time and resuming continues from the original sample`() throws {
        var now = 10.0
        let vm = makeSmartFillViewModel(timestamp: { now })
        let layer = try #require(vm.sceneRenderSnapshot.layers.first)
        let scene = try #require(vm.scene(for: layer))
        decodeAllRenderers(in: scene, layer: layer, viewModel: vm)

        now = 12
        vm.toggleAutoPlayFromUserInteraction()
        let pausedSample = try #require(vm.sceneRenderSnapshot.layers.first)
        #expect(vm.sceneRenderSnapshot.phase == .paused)
        assertApproximatelyEqual(pausedSample.motionActiveTime, 2)

        now = 20
        let stillPaused = try #require(vm.sceneRenderSnapshot.layers.first)
        assertApproximatelyEqual(stillPaused.motionActiveTime, 2)

        vm.toggleAutoPlayFromUserInteraction()
        now = 21
        let resumed = try #require(vm.sceneRenderSnapshot.layers.first)
        assertApproximatelyEqual(resumed.motionActiveTime, 3)
    }

    @Test
    func `reduce motion freezes the current sample and toggling it off does not restart the current motion`() throws {
        var now = 30.0
        let vm = makeSmartFillViewModel(timestamp: { now })
        let layer = try #require(vm.sceneRenderSnapshot.layers.first)
        let scene = try #require(vm.scene(for: layer))
        decodeAllRenderers(in: scene, layer: layer, viewModel: vm)

        now = 32
        vm.updateSmartFillMotionReduceMotionEnabled(true)
        let frozen = try #require(vm.sceneRenderSnapshot.layers.first)
        #expect(frozen.isMotionEnabled)
        assertApproximatelyEqual(frozen.motionActiveTime, 2)

        now = 40
        vm.updateSmartFillMotionReduceMotionEnabled(false)
        let unchanged = try #require(vm.sceneRenderSnapshot.layers.first)
        #expect(unchanged.isMotionEnabled)
        assertApproximatelyEqual(unchanged.motionActiveTime, 2)
    }

    @Test
    func
        `a delayed incoming during nested suspension under reduce motion makes SmartFill and single photo zoom-out appear from identity`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: "nested-reduce-current", assetID: "asset-current"),
            configuredInterval: 5
        )
        let incomingTarget = PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: "nested-reduce-incoming", assetID: "asset-incoming"),
            configuredInterval: 5
        )

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: incomingTarget, readiness: .ready), at: 6)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.2)
        engine.reduceScenePresentation(.suspend(.background), at: 6.3)
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 6.4)
        engine.reduceScenePresentation(.resume(.background), at: 9)
        engine.reduceScenePresentation(.resume(.userPaused), at: 10)

        let resumedIncoming = try #require(
            engine.sceneRenderSnapshot(at: 10).layers.first { $0.identity == incomingTarget.identity }
        )
        let fadeStart = try #require(resumedIncoming.fadeStartTime)
        let firstVisibleIncoming = try #require(
            engine.sceneRenderSnapshot(at: fadeStart + 0.0001).layers.first {
                $0.identity == incomingTarget.identity
            }
        )
        #expect(firstVisibleIncoming.opacity > 0)
        #expect(!firstVisibleIncoming.isMotionEnabled)

        let context = MotionRuntimeContext(
            sceneId: incomingTarget.identity.sceneID,
            renderRole: .incoming,
            lifecycle: incomingTarget.lifecycle,
            motionActiveTime: firstVisibleIncoming.motionActiveTime,
            isMotionEnabled: firstVisibleIncoming.isMotionEnabled,
            isReduceMotionEnabled: true
        )
        let geometry = MotionSlotRenderGeometry(
            slotSize: probeSlotSizePoints,
            imageFrameInSlot: CGRect(origin: .zero, size: probeSlotSizePoints)
        )
        let smartFillFrame = SmartFillMotionSlotFrameResolver.resolve(
            makeFrameInput(context: context, geometry: geometry)
        )
        let singlePhotoZoomOut = SceneAnimationProfile(lifecycle: incomingTarget.lifecycle).singlePhotoTransform(
            direction: .zoomOut,
            activeTime: firstVisibleIncoming.motionActiveTime,
            isMotionEnabled: firstVisibleIncoming.isMotionEnabled
        )

        #expect(smartFillFrame.transform.isIdentity)
        #expect(singlePhotoZoomOut.isIdentity)
    }

    @Test
    func
        `cancelling a manual hold across nested suspensions makes reduce motion show the returning incoming from identity`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: "manual-restore-current", assetID: "asset-current"),
            configuredInterval: 5
        )
        let automaticIncoming = PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: "manual-restore-automatic", assetID: "asset-automatic"),
            configuredInterval: 5
        )
        let manualPending = PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: "manual-restore-manual", assetID: "asset-manual"),
            configuredInterval: 5
        )

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: automaticIncoming, readiness: .ready), at: 6)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.2)
        engine.reduceScenePresentation(
            .request(target: manualPending, source: .manualNext, readiness: .pending),
            at: 6.3
        )
        engine.reduceScenePresentation(.suspend(.background), at: 6.35)
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 6.4)
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.5)
        engine.reduceScenePresentation(.resume(.background), at: 7)
        let resumeTimeSeconds: TimeInterval = 8
        engine.reduceScenePresentation(.resume(.userPaused), at: resumeTimeSeconds)
        // The automatic incoming decodes again behind the held photo, then the full automatic crossfade runs.
        let readyEffects = engine.reduceScenePresentation(
            .targetReady(automaticIncoming.identity), at: resumeTimeSeconds)

        let completionDeadline = readyEffects.compactMap { effect -> TimeInterval? in
            guard case let .scheduleWakeUp(_, deadline) = effect else { return nil }
            return deadline
        }
        let expectedCompletionDeadline = resumeTimeSeconds + ScenePresentationPacingPolicy.automatic.completionDuration
        #expect(completionDeadline.contains { abs($0 - expectedCompletionDeadline) < 0.0001 })

        let resumedIncoming = try #require(
            engine.sceneRenderSnapshot(at: resumeTimeSeconds).layers.first { $0.identity == automaticIncoming.identity }
        )
        let fadeStart = try #require(resumedIncoming.fadeStartTime)
        let firstVisibleIncoming = try #require(
            engine.sceneRenderSnapshot(at: fadeStart + 0.0001).layers.first {
                $0.identity == automaticIncoming.identity
            }
        )
        #expect(firstVisibleIncoming.opacity > 0)
        #expect(!firstVisibleIncoming.isMotionEnabled)
        #expect(firstVisibleIncoming.motionActiveTime < 0.001)

        let context = MotionRuntimeContext(
            sceneId: automaticIncoming.identity.sceneID,
            renderRole: .incoming,
            lifecycle: automaticIncoming.lifecycle,
            motionActiveTime: firstVisibleIncoming.motionActiveTime,
            isMotionEnabled: firstVisibleIncoming.isMotionEnabled,
            isReduceMotionEnabled: true
        )
        let geometry = MotionSlotRenderGeometry(
            slotSize: probeSlotSizePoints,
            imageFrameInSlot: CGRect(origin: .zero, size: probeSlotSizePoints)
        )
        let smartFillFrame = SmartFillMotionSlotFrameResolver.resolve(
            makeFrameInput(context: context, geometry: geometry)
        )
        let singlePhotoZoomOut = SceneAnimationProfile(lifecycle: automaticIncoming.lifecycle).singlePhotoTransform(
            direction: .zoomOut,
            activeTime: firstVisibleIncoming.motionActiveTime,
            isMotionEnabled: firstVisibleIncoming.isMotionEnabled
        )

        #expect(smartFillFrame.transform.isIdentity)
        #expect(singlePhotoZoomOut.isIdentity)
    }

    @Test
    func `raw progress keeps moving and covers the slot when the longest visible period exceeds the waypoint`() {
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let context = MotionRuntimeContext(
            sceneId: "scene-longest-visible",
            renderRole: .outgoing,
            lifecycle: lifecycle,
            motionActiveTime: lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true,
            isReduceMotionEnabled: false
        )
        let geometry = MotionSlotRenderGeometry(
            slotSize: portraitProbeSlotSizePoints,
            imageFrameInSlot: CGRect(
                x: -1.346,
                y: -18.560,
                width: 418.271,
                height: 904.952
            )
        )
        let frame = SmartFillMotionSlotFrameResolver.resolve(
            SmartFillMotionSlotFrameInput(
                motionContext: context,
                slotId: "slot-longest-visible",
                assetId: "asset-longest-visible",
                renderGeometry: geometry,
                cropRectInSource: MotionUnitRect(x: 0, y: 0, width: 1, height: 1),
                focalSource: .cropCenterFallback
            )
        )

        assertApproximatelyEqual(context.rawProgress, 1.6)
        assertApproximatelyEqual(frame.resolvedProgress, 1.6)
        #expect(frame.progressFrame?.source == .sceneActiveTime)
        #expect(!frame.transform.isIdentity)
        #expect(MotionTransformGeometry.coversSlot(frame.transform, renderGeometry: geometry))
    }

    @Test
    func `the full visible window plans SmartFill coverage endpoints from the frozen scene maximum progress`() {
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let context = MotionRuntimeContext(
            sceneId: "s66",
            renderRole: .outgoing,
            lifecycle: lifecycle,
            motionActiveTime: lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true,
            isReduceMotionEnabled: false
        )
        // Fractional crop coordinates reproduce the coverage endpoint regression across the full visible window.
        let boundaryGeometry = MotionSlotRenderGeometry(
            slotSize: CGSize(width: 200, height: 120),
            imageFrameInSlot: CGRect(
                x: -2.731_896_479_269_231_3,
                y: -7.399_767_760_667_032,
                width: 280.271_675_207_195_47,
                height: 179.235_087_130_880_77
            )
        )

        let frame = SmartFillMotionSlotFrameResolver.resolve(
            SmartFillMotionSlotFrameInput(
                motionContext: context,
                slotId: "q66",
                assetId: "a66",
                renderGeometry: boundaryGeometry,
                cropRectInSource: MotionUnitRect(x: 0, y: 0.05, width: 0.3, height: 0.8),
                focalSource: .cropCenterFallback
            )
        )

        assertApproximatelyEqual(context.rawProgress, 1.6)
        #expect(MotionTransformGeometry.coversSlot(frame.transform, renderGeometry: boundaryGeometry))
    }

    @Test
    func
        `resolver returns identity when the shared context is missing or the layer is newly created under reduce motion`()
    {
        let geometry = MotionSlotRenderGeometry(
            slotSize: probeSlotSizePoints,
            imageFrameInSlot: CGRect(origin: .zero, size: probeSlotSizePoints)
        )
        let missing = SmartFillMotionSlotFrameResolver.resolve(
            makeFrameInput(context: nil, geometry: geometry)
        )
        let reduced = SmartFillMotionSlotFrameResolver.resolve(
            makeFrameInput(
                context: MotionRuntimeContext(
                    sceneId: "scene-reduced",
                    renderRole: .settled,
                    lifecycle: SceneLifecycleContract(configuredInterval: 5),
                    motionActiveTime: 2,
                    isMotionEnabled: false,
                    isReduceMotionEnabled: true
                ),
                geometry: geometry
            )
        )

        #expect(missing.transform.isIdentity)
        #expect(missing.missingProgressReason == "motionContextMissing")
        #expect(reduced.transform.isIdentity)
        #expect(reduced.progressFrame?.source == .sceneActiveTime)
    }

    @Test
    func `an already started SmartFill motion keeps its frozen transform after reduce motion is toggled`() {
        let geometry = MotionSlotRenderGeometry(
            slotSize: probeSlotSizePoints,
            imageFrameInSlot: CGRect(origin: .zero, size: probeSlotSizePoints)
        )
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let active = SmartFillMotionSlotFrameResolver.resolve(
            makeFrameInput(
                context: MotionRuntimeContext(
                    sceneId: "scene-active",
                    renderRole: .settled,
                    lifecycle: lifecycle,
                    motionActiveTime: 2,
                    isMotionEnabled: true,
                    isReduceMotionEnabled: false
                ),
                geometry: geometry
            )
        )
        let frozenForReduceMotion = SmartFillMotionSlotFrameResolver.resolve(
            makeFrameInput(
                context: MotionRuntimeContext(
                    sceneId: "scene-active",
                    renderRole: .settled,
                    lifecycle: lifecycle,
                    motionActiveTime: 2,
                    isMotionEnabled: true,
                    isReduceMotionEnabled: true
                ),
                geometry: geometry
            )
        )

        #expect(!active.transform.isIdentity)
        #expect(frozenForReduceMotion.transform == active.transform)
    }

    @Test
    func `iOS and tvOS consuming the same layer get the same raw progress`() throws {
        var now = 50.0
        let vm = makeSmartFillViewModel(timestamp: { now })
        let layer = try #require(vm.sceneRenderSnapshot.layers.first)
        let scene = try #require(vm.scene(for: layer))
        decodeAllRenderers(in: scene, layer: layer, viewModel: vm)
        now = 52.25
        let progressedLayer = try #require(vm.sceneRenderSnapshot.layers.first)

        let iOS = try #require(
            vm.motionRuntimeContext(
                for: progressedLayer,
                platform: .iOS,
                isReduceMotionEnabled: false
            ))
        let tvOS = try #require(
            vm.motionRuntimeContext(
                for: progressedLayer,
                platform: .tvOS,
                isReduceMotionEnabled: false
            ))

        assertApproximatelyEqual(iOS.motionActiveTime, tvOS.motionActiveTime)
        assertApproximatelyEqual(iOS.rawProgress, tvOS.rawProgress)
        #expect(iOS.isMotionEnabled == tvOS.isMotionEnabled)
    }

    @Test
    func `every playback source keeps the shared motion transform in SmartFill`() throws {
        for sourceCase in smartFillMotionSourceMatrix() {
            let vm = makeSmartFillViewModel(source: sourceCase.source, timestamp: { 60 })
            let layer = try #require(vm.sceneRenderSnapshot.layers.first)
            let scene = try #require(vm.scene(for: layer))
            decodeAllRenderers(in: scene, layer: layer, viewModel: vm)
            let readyLayer = try #require(vm.sceneRenderSnapshot.layers.first)
            let context = try #require(
                vm.motionRuntimeContext(
                    for: readyLayer,
                    platform: .iOS,
                    isReduceMotionEnabled: false
                ))

            #expect(context.isMotionEnabled, "\(sourceCase.name) should keep SmartFill motion")
            let slot = try #require(scene.photoSlots.first)
            let frame = SmartFillMotionSlotFrameResolver.resolve(
                SmartFillMotionSlotFrameInput(
                    motionContext: context,
                    slotId: slot.id,
                    assetId: slot.asset.id,
                    renderGeometry: MotionSlotRenderGeometry(
                        slotSize: probeSlotSizePoints,
                        imageFrameInSlot: CGRect(origin: .zero, size: probeSlotSizePoints)
                    ),
                    cropRectInSource: MotionUnitRect(x: 0, y: 0, width: 1, height: 1),
                    focalSource: .slotCenterFallback
                )
            )
            #expect(!frame.transform.isIdentity, "\(sourceCase.name) should not fall back to the identity transform")
        }
    }

    @Test
    func `a prepared SmartFill scene prewarms its selected fullsize slots for every playback source`() throws {
        for sourceCase in smartFillMotionSourceMatrix() {
            let vm = makeSmartFillViewModel(source: sourceCase.source, timestamp: { 70 })
            vm.clearPreparedSmartFillRingForTesting()
            var preloadedAssetIds: [[String]] = []
            vm.smartFillMotionPreparedSlotPreloadHookForTesting = { assetIds in
                preloadedAssetIds.append(assetIds)
            }
            let sourceCursor = try #require(vm.currentPreparedSmartFillSourceCursorForTesting)
            let request = try #require(vm.capturePreparedSmartFillPlanRequestForTesting(startingAt: sourceCursor))
            let result = try #require(SmartFillPreparedPlanBuilder.makeResult(for: request))

            #expect(vm.applyPreparedSmartFillPlanResultForTesting(result, request: request) == .applied)
            #expect(
                preloadedAssetIds.last == result.selectedAssetIds,
                "\(sourceCase.name) should prewarm the prepared SmartFill scene")
        }
    }

    @Test
    func `a prepared SmartFill scene starts a one scene lookahead fullsize prewarm`() async throws {
        let vm = makeSmartFillViewModel(timestamp: { 80 })
        vm.clearPreparedSmartFillRingForTesting()
        var preloadedAssetIds: [[String]] = []
        vm.smartFillMotionPreparedSlotPreloadHookForTesting = { assetIds in
            preloadedAssetIds.append(assetIds)
        }
        let sourceCursor = try #require(vm.currentPreparedSmartFillSourceCursorForTesting)
        let request = try #require(vm.capturePreparedSmartFillPlanRequestForTesting(startingAt: sourceCursor))
        let result = try #require(SmartFillPreparedPlanBuilder.makeResult(for: request))

        #expect(vm.applyPreparedSmartFillPlanResultForTesting(result, request: request) == .applied)
        let didPrewarmLookahead = await waitUntilForTesting {
            preloadedAssetIds.count >= 2
        }

        #expect(didPrewarmLookahead)
        #expect(preloadedAssetIds.first == result.selectedAssetIds)
        #expect(preloadedAssetIds.dropFirst().contains { !$0.isEmpty })
        let lookaheadAssetIds = try #require(preloadedAssetIds.dropFirst().first)
        #expect(Set(lookaheadAssetIds).isDisjoint(with: result.selectedAssetIds))
        #expect(vm.preparedSmartFillNextAssetIdsForTesting == result.selectedAssetIds)

        vm.requestNextScene()

        // Promotion is synchronous with acceptance, before a new background refresh can finish.
        #expect(vm.safeCurrentScene?.assetIds == result.selectedAssetIds)
        #expect(vm.preparedSmartFillNextAssetIdsForTesting == lookaheadAssetIds)
        #expect(vm.preparedSmartFillNextSourceCursorForTesting == vm.currentPreparedSmartFillSourceCursorForTesting)
    }

    private func makeFrameInput(
        context: MotionRuntimeContext?,
        geometry: MotionSlotRenderGeometry
    ) -> SmartFillMotionSlotFrameInput {
        SmartFillMotionSlotFrameInput(
            motionContext: context,
            slotId: "slot-a",
            assetId: "asset-a",
            renderGeometry: geometry,
            cropRectInSource: MotionUnitRect(x: 0, y: 0, width: 1, height: 1),
            focalSource: .slotCenterFallback
        )
    }

    private func smartFillMotionSourceMatrix() -> [(name: String, source: PlaybackSource)] {
        [
            (name: "unfiltered", source: .random),
            (
                name: "person normal",
                source: .filtered(
                    FilterSelection(
                        personFilters: [PersonFilter(personId: "person-normal", matchMode: .normal)]
                    ))
            ),
            (
                name: "person soloOnly",
                source: .filtered(
                    FilterSelection(
                        personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
                    ))
            ),
            (name: "album", source: .filtered(FilterSelection(albumIds: ["album-a"]))),
            (name: "tag", source: .filtered(FilterSelection(tagIds: ["tag-a"]))),
            (name: "rating", source: .filtered(FilterSelection(rating: 4))),
            (name: "favorite", source: .filtered(FilterSelection(isFavorite: true))),
            (
                name: "mixed",
                source: .filtered(
                    FilterSelection(
                        albumIds: ["album-a"],
                        personFilters: [PersonFilter(personId: "person-mixed", matchMode: .normal)],
                        tagIds: ["tag-a"],
                        rating: 5,
                        isFavorite: true
                    ))
            )
        ]
    }

    /// Settles the first scene, then presses Next so the second waits hidden behind it.
    private func holdSecondSceneBehindFirst(
        in vm: SlideShowViewModel,
        advanceClock: () -> Void
    ) throws -> (PlaybackSessionEngine.SceneRenderLayer, PlaybackSessionEngine.SceneRenderLayer) {
        let firstLayer = try #require(vm.sceneRenderSnapshot.layers.first)
        let firstScene = try #require(vm.scene(for: firstLayer))
        decodeAllRenderers(in: firstScene, layer: firstLayer, viewModel: vm)
        advanceClock()
        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        vm.requestNextScene()
        #expect(vm.sceneRenderSnapshot.underlyingPhase == .grace)
        let secondLayer = try #require(vm.sceneRenderSnapshot.layers.first { $0.identity != firstLayer.identity })
        return (firstLayer, secondLayer)
    }

    private func probeCrossfadeEvidence(in vm: SlideShowViewModel) -> SceneTransitionDiagnostic.CrossfadeEvidence? {
        let prefix = "lastCrossfade="
        let label = vm.scenePresentationContractProbeLabel(for: vm.sceneRenderSnapshot)
        guard let field = label.split(separator: ";").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return SceneTransitionDiagnostic.crossfadeEvidence(
            lastCrossfade: String(field.dropFirst(prefix.count)), frameCount: 1)
    }

    private func makeSmartFillViewModel(
        source: PlaybackSource = .random,
        assetPixelSize: PlaybackPlanningPixelSize = PlaybackPlanningPixelSize(width: 1800, height: 2000),
        timestamp: @escaping () -> TimeInterval
    ) -> SlideShowViewModel {
        let vm = SlideShowViewModel(source: source)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = timestamp
        vm.autoPlayInterval = SceneLifecycleContract.minimumInterval
        vm.isAutoPlay = true
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: iPhonePortraitPlanningPixelSize,
                profile: .iPhone,
                orientation: .portrait
            )
        )
        let assets = (0..<6).map {
            makeAsset(id: "asset-\($0)", width: assetPixelSize.width, height: assetPixelSize.height)
        }
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        return vm
    }

    private func decodeAllRenderers(
        in scene: PlaybackScene,
        layer: PlaybackSessionEngine.SceneRenderLayer,
        viewModel: SlideShowViewModel
    ) {
        for slot in scene.photoSlots {
            viewModel.rendererDecoded(
                SceneRendererIdentity(
                    generation: layer.identity.generation,
                    attemptID: viewModel.scenePresentationRendererAttemptID(for: layer),
                    sceneID: layer.identity.sceneID,
                    slotID: slot.id,
                    assetID: slot.asset.id
                )
            )
        }
    }

    private func makeAsset(id: String, width: Int, height: Int) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil,
            width: width,
            height: height
        )
    }

    private func markReady(_ assets: [Asset], in manager: AssetsDownloadManager) {
        for asset in assets {
            manager.assetStates[asset.id] = .readyToPlay
            manager.assetPreviewStates[asset.id] = .readyToPlay
            manager.assetURLs[asset.id] = URL(string: "https://example.invalid/\(asset.id).jpg")!
        }
    }

    private func resetDownloadManagerState(_ manager: AssetsDownloadManager) {
        manager.assetStates = [:]
        manager.assetPreviewStates = [:]
        manager.assetThumbnailStates = [:]
        manager.assetURLs = [:]
        manager.assetPreviewURLs = [:]
        manager.assetThumbnailURLs = [:]
    }

    private func assertApproximatelyEqual(
        _ actual: TimeInterval,
        _ expected: TimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) < 0.000_1, sourceLocation: sourceLocation)
    }

    // Sleep-polling instead of a yield budget: 10k yields last ~0.3s and starve the detached planner.
    private func waitUntilForTesting(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        await waitUntil(pollInterval: .milliseconds(2), condition)
    }
}
