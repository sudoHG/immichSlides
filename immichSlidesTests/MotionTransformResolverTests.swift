import CoreGraphics
import Testing
@testable import immichSlides

@MainActor
@Suite
struct MotionTransformResolverTests {

    @Test
    func `normal motion policy locks scale between 1.15 and 1.25 with pan capped at 2.5 percent of the slot`() {
        #expect(MotionTransformPolicy.v1Default.minimumScale == 1.15)
        #expect(MotionTransformPolicy.v1Default.maximumScale == 1.25)
        #expect(MotionTransformPolicy.v1Default.panFractionOfSlot == 0.025)
    }

    @Test
    func `motion transform uses deterministic scale, pan, and focal anchor with no runtime randomness`() {
        let input = makeInput(progress: 0.5)

        let first = MotionTransformResolver.resolve(input)
        let repeated = MotionTransformResolver.resolve(input)

        #expect(first == repeated)
        #expect(first.scale >= MotionTransformPolicy.v1Default.minimumScale)
        #expect(first.scale <= MotionTransformPolicy.v1Default.maximumScale)
        #expect(first.focalSource == .face)
        #expect(first.applicationSpace == .slotSizedClippedContainer)
        #expect(first.anchorUnitPointInSlot.x < 0.5)
        #expect(
            abs(first.translationInSlot.width) <= input.renderGeometry.slotSize.width
                * MotionTransformPolicy.v1Default.panFractionOfSlot + 0.000_1)
        #expect(MotionTransformGeometry.coversSlot(first, renderGeometry: input.renderGeometry))

        let centerInput = makeInput(focalSource: .slotCenterFallback, progress: 0.5)
        let centerRepeated = MotionTransformResolver.resolve(centerInput)
        let centerDifferentAsset = MotionTransformResolver.resolve(
            makeInput(
                assetId: "asset-b",
                focalSource: .slotCenterFallback,
                progress: 0.5
            ))
        #expect(centerRepeated == MotionTransformResolver.resolve(centerInput))
        #expect(centerRepeated != centerDifferentAsset)
    }

    @Test
    func `render roles resolve prerender identity and shared active time motion semantics`() {
        let prerender = MotionTransformResolver.resolve(makeInput(renderRole: .prerender, progress: 0.8))
        #expect(prerender.isIdentity)
        #expect(prerender.phaseAction == .identity)

        let incomingStart = MotionTransformResolver.resolve(makeInput(renderRole: .incoming, progress: 0))
        #expect(!incomingStart.isIdentity)
        #expect(incomingStart.phaseAction == .showStartWithoutAnimation)

        let settled = MotionTransformResolver.resolve(makeInput(renderRole: .settled, progress: 0.6))
        #expect(!settled.isIdentity)
        #expect(settled.phaseAction == .animateForwardAndHold)

        let outgoing = MotionTransformResolver.resolve(makeInput(renderRole: .outgoing, progress: 0.6))
        #expect(!outgoing.isIdentity)
        #expect(outgoing.phaseAction == .animateForwardAndHold)
        #expect(outgoing.scale == settled.scale)
        #expect(outgoing.translationInSlot == settled.translationInSlot)
    }

    @Test
    func `transform input carries typed progress identity and explicit focal provenance`() {
        let identity = MotionFrameIdentity(
            sceneId: "scene-a",
            slotId: "slot-a",
            assetId: "asset-a",
            renderRole: .settled,
            clockGeneration: 7
        )
        let input = makeInput(
            focalSource: .face(
                centerInSource: CGPoint(x: 0.25, y: 0.5),
                rectInSource: MotionUnitRect(x: 0.18, y: 0.40, width: 0.14, height: 0.2),
                provenance: .runtimeFaceSummary
            ),
            progressFrame: MotionRenderProgressFrame.fromPresentationClock(
                identity: identity,
                clock: MotionPacingPolicy(configuredPlaybackIntervalSeconds: 5)
                    .makePresentationClock(timelineStartTime: 0, stableVisibleStartTime: 0),
                at: 3.5125
            )
        )

        let transform = MotionTransformResolver.resolve(input)

        #expect(input.progressFrame.identity.clockGeneration == 7)
        #expect(input.progressFrame.identity.renderRole == .settled)
        #expect(transform.focalSource == .face)
        #expect(input.focalSource.rectInSource != nil)
        #expect(input.focalSource.provenance == .runtimeFaceSummary)
    }

    @Test
    func `motion seed uses the raw focal rect and falls back cleanly when there is no focal point`() {
        let focalRect = MotionUnitRect(x: 0.18, y: 0.40, width: 0.14, height: 0.2)
        let firstCenter = makeInput(
            focalSource: .face(
                centerInSource: CGPoint(x: 0.25, y: 0.5),
                rectInSource: focalRect
            )
        )
        let secondCenter = makeInput(
            focalSource: .face(
                centerInSource: CGPoint(x: 0.75, y: 0.2),
                rectInSource: focalRect
            )
        )

        let firstDiagnostics = MotionTransformResolver.diagnostics(firstCenter)
        let secondDiagnostics = MotionTransformResolver.diagnostics(secondCenter)

        #expect(firstDiagnostics.stableSeedHash == secondDiagnostics.stableSeedHash)
        #expect(firstDiagnostics.zoomDirection == secondDiagnostics.zoomDirection)
        #expect(
            firstDiagnostics.seedInputSummary.contains(
                "seedContractVersion=ambient-v1-scene-slot-asset-crop-raw-focal-rect"))
        #expect(firstDiagnostics.seedInputSummary.contains("seedHashIncludesSceneId=true"))
        #expect(firstDiagnostics.seedInputSummary.contains("seedFocalKeySource=face"))
        #expect(!firstDiagnostics.seedInputSummary.contains("sceneId=scene-a|"))
        #expect(!firstDiagnostics.seedInputSummary.contains("slotId=slot-a|"))
        #expect(!firstDiagnostics.seedInputSummary.contains("assetId=asset-a|"))
        #expect(
            firstDiagnostics.seedInputSummary.contains(
                "assetId=\(MotionTransformResolver.diagnosticIdentityToken("asset-a"))|"))
        #expect(
            MotionTransformResolver.diagnosticIdentityToken("asset-a")
                != MotionTransformResolver.diagnosticIdentityToken("asset-b"))
        #expect(firstDiagnostics.seedInputSummary == secondDiagnostics.seedInputSummary)
        #expect(
            firstDiagnostics.seedInputSummary
                != MotionTransformResolver.diagnostics(
                    makeInput(assetId: "asset-b")
                ).seedInputSummary)
        #expect(!firstDiagnostics.seedInputSummary.contains("0.25|0.5"))

        let fallbackDiagnostics = MotionTransformResolver.diagnostics(
            makeInput(focalSource: .cropCenterFallback)
        )
        #expect(fallbackDiagnostics.seedInputSummary.contains("seedFocalKeySource=no-focal"))
        #expect(fallbackDiagnostics.seedInputSummary.contains("focalKey=no-focal"))
    }

    @Test
    func `centered fallback preserves the center anchor and bounded pan`() {
        let fullSlotGeometry = MotionSlotRenderGeometry(
            slotSize: CGSize(width: 400, height: 700),
            imageFrameInSlot: CGRect(x: 0, y: 0, width: 400, height: 700)
        )
        let input = makeInput(
            focalSource: .cropCenterFallback,
            progress: 1,
            renderGeometry: fullSlotGeometry,
            cropRectInSource: MotionUnitRect(x: 0, y: 0, width: 1, height: 1)
        )

        let transform = MotionTransformResolver.resolve(input)
        let repeated = MotionTransformResolver.resolve(input)

        #expect(transform == repeated)
        #expect(transform.focalSource == .cropCenterFallback)
        #expect(abs(transform.anchorUnitPointInSlot.x - 0.5) < 0.000_1)
        #expect(abs(transform.anchorUnitPointInSlot.y - 0.5) < 0.000_1)
        #expect(
            abs(transform.translationInSlot.width) <= fullSlotGeometry.slotSize.width
                * MotionTransformPolicy.v1Default.panFractionOfSlot + 0.000_1)
        #expect(
            abs(transform.translationInSlot.height) <= fullSlotGeometry.slotSize.height
                * MotionTransformPolicy.v1Default.panFractionOfSlot + 0.000_1)
        #expect(abs(transform.translationInSlot.width) > 0.000_1 || abs(transform.translationInSlot.height) > 0.000_1)
        #expect(MotionTransformGeometry.coversSlot(transform, renderGeometry: input.renderGeometry))
    }

    @Test
    func `fallback full slot motion stays within pan bounds and keeps covering the slot`() {
        let fullSlotGeometry = MotionSlotRenderGeometry(
            slotSize: CGSize(width: 393, height: 852),
            imageFrameInSlot: CGRect(
                x: -1.346,
                y: -18.560,
                width: 418.271,
                height: 904.952
            )
        )
        let early = MotionTransformResolver.resolve(
            makeInput(
                sceneId: "scene-157112d2-db9d-4cf7-a518-013a131ca1c7-10",
                slotId: "slot-primary-asset_5ae20bb8db9ce6bf",
                assetId: "157112d2-db9d-4cf7-a518-013a131ca1c7",
                focalSource: .cropCenterFallback,
                progress: 0.225587,
                renderGeometry: fullSlotGeometry,
                cropRectInSource: MotionUnitRect(x: 0, y: 0, width: 1, height: 1)
            ))
        let late = MotionTransformResolver.resolve(
            makeInput(
                sceneId: "scene-157112d2-db9d-4cf7-a518-013a131ca1c7-10",
                slotId: "slot-primary-asset_5ae20bb8db9ce6bf",
                assetId: "157112d2-db9d-4cf7-a518-013a131ca1c7",
                focalSource: .cropCenterFallback,
                progress: 0.662051,
                renderGeometry: fullSlotGeometry,
                cropRectInSource: MotionUnitRect(x: 0, y: 0, width: 1, height: 1)
            ))
        let earlyCenter = MotionTransformGeometry.transformedImageFrameInSlot(
            early,
            renderGeometry: fullSlotGeometry
        ).testCenter
        let lateCenter = MotionTransformGeometry.transformedImageFrameInSlot(
            late,
            renderGeometry: fullSlotGeometry
        ).testCenter
        let centerDelta = hypot(lateCenter.x - earlyCenter.x, lateCenter.y - earlyCenter.y)
        let maxCenterDelta = fullSlotGeometry.slotSize.height * MotionTransformPolicy.v1Default.panFractionOfSlot
        let expectedCropAnchor = CGPoint(
            x: fullSlotGeometry.imageFrameInSlot.midX / fullSlotGeometry.slotSize.width,
            y: fullSlotGeometry.imageFrameInSlot.midY / fullSlotGeometry.slotSize.height
        )

        #expect(early != late)
        #expect(centerDelta <= maxCenterDelta + 0.000_1)
        #expect(abs(early.anchorUnitPointInSlot.x - expectedCropAnchor.x) < 0.000_1)
        #expect(abs(early.anchorUnitPointInSlot.y - expectedCropAnchor.y) < 0.000_1)
        #expect(abs(late.anchorUnitPointInSlot.x - expectedCropAnchor.x) < 0.000_1)
        #expect(abs(late.anchorUnitPointInSlot.y - expectedCropAnchor.y) < 0.000_1)
        #expect(MotionTransformGeometry.coversSlot(early, renderGeometry: fullSlotGeometry))
        #expect(MotionTransformGeometry.coversSlot(late, renderGeometry: fullSlotGeometry))
    }

    @Test
    func `transform output declares the slot sized clipped container coordinate contract`() {
        let input = makeInput(progress: 0.5)
        let transform = MotionTransformResolver.resolve(input)
        let frame = MotionTransformGeometry.transformedImageFrameInSlot(transform, renderGeometry: input.renderGeometry)

        #expect(transform.applicationSpace == .slotSizedClippedContainer)
        #expect(transform.anchorUnitPointInSlot.x >= 0)
        #expect(transform.anchorUnitPointInSlot.x <= 1)
        #expect(transform.anchorUnitPointInSlot.y >= 0)
        #expect(transform.anchorUnitPointInSlot.y <= 1)
        #expect(MotionTransformGeometry.coversSlot(transform, renderGeometry: input.renderGeometry))
        #expect(frame.width >= input.renderGeometry.slotSize.width)
        #expect(frame.height >= input.renderGeometry.slotSize.height)
    }

    @Test
    func `future focal source adapters stay pure inputs without adding person or solo runtime behavior`() {
        let personInput = makeInput(
            focalSource: .person(centerInSource: CGPoint(x: 0.45, y: 0.35)),
            progress: 0.4,
            isMotionEnabled: false
        )
        let soloOnlyInput = makeInput(
            focalSource: .soloOnly(centerInSource: CGPoint(x: 0.52, y: 0.42)),
            progress: 0.4,
            isMotionEnabled: false
        )

        #expect(MotionTransformResolver.resolve(personInput).isIdentity)
        #expect(MotionTransformResolver.resolve(soloOnlyInput).isIdentity)
        #expect(personInput.focalSource.kind == .person)
        #expect(soloOnlyInput.focalSource.kind == .soloOnly)
    }

    @Test
    func `candidate single photo policy uses a center only transform that stays continuous across the waypoint`() {
        let policy = SinglePhotoGeometryPolicy()
        let before = policy.transform(
            direction: .zoomIn,
            rawProgress: 0.99,
            isMotionEnabled: true
        )
        let waypoint = policy.transform(
            direction: .zoomIn,
            rawProgress: 1,
            isMotionEnabled: true
        )
        let after = policy.transform(
            direction: .zoomIn,
            rawProgress: 1.01,
            isMotionEnabled: true
        )

        #expect(before.translationInSlot == .zero)
        #expect(waypoint.translationInSlot == .zero)
        #expect(after.translationInSlot == .zero)
        #expect(before.anchorUnitPointInSlot == CGPoint(x: 0.5, y: 0.5))
        #expect(waypoint.scale > before.scale)
        #expect(after.scale > waypoint.scale)
    }

    private func makeInput(
        sceneId: String = "scene-a",
        slotId: String = "slot-a",
        assetId: String = "asset-a",
        renderRole: MotionRenderRole = .settled,
        focalSource: MotionFocalSource = .face(
            centerInSource: CGPoint(x: 0.25, y: 0.5),
            rectInSource: MotionUnitRect(x: 0.18, y: 0.40, width: 0.14, height: 0.2)
        ),
        progress: Double = 0,
        progressFrame: MotionRenderProgressFrame? = nil,
        isMotionEnabled: Bool = true,
        renderGeometry: MotionSlotRenderGeometry = MotionSlotRenderGeometry(
            slotSize: CGSize(width: 200, height: 120),
            imageFrameInSlot: CGRect(x: -20, y: 0, width: 240, height: 120)
        ),
        cropRectInSource: MotionUnitRect = MotionUnitRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
    ) -> MotionTransformInput {
        let identity = MotionFrameIdentity(
            sceneId: sceneId,
            slotId: slotId,
            assetId: assetId,
            renderRole: renderRole,
            clockGeneration: 0
        )
        let frameClock = clockForProgressFrame()
        return MotionTransformInput(
            progressFrame: progressFrame
                ?? MotionRenderProgressFrame.fromPresentationClock(
                    identity: identity,
                    clock: frameClock,
                    at: progress * frameClock.motionDurationSeconds
                ),
            maximumCoverageProgress: 4.0 / 3.0,
            renderGeometry: renderGeometry,
            cropRectInSource: cropRectInSource,
            focalSource: focalSource,
            isMotionEnabled: isMotionEnabled,
            reduceMotionEnabled: false
        )
    }

    private func clockForProgressFrame() -> MotionPresentationClock {
        MotionPacingPolicy(configuredPlaybackIntervalSeconds: 5)
            .makePresentationClock(timelineStartTime: 0, stableVisibleStartTime: 0)
    }
}

private extension CGRect {
    var testCenter: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
