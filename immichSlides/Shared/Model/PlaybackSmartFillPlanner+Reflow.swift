import CoreGraphics
import Foundation

extension PlaybackSmartFillPlanner {
    /// A presentation projection: selection, retained recipes and the reducer's clocks stay unchanged.
    @MainActor static func reframe(
        _ scene: PlaybackScene,
        surface: PlaybackSmartFillSurface,
        protectionSnapshot: PlaybackProtectionSnapshot
    ) -> PlaybackScene {
        guard let readback = scene.smartFillReadback, !scene.photoSlots.isEmpty else { return scene }
        if scene.planningSurface?.pixelSize == surface.pixelSize,
            scene.planningSurface?.surfaceKey == surface.surfaceKey
        {
            return scene
        }
        let candidates = scene.photoSlots.map { slot in
            SmartFillPreparedPlanBuilder.candidateSummary(from: SmartFillPlanningRawAssetSnapshot(asset: slot.asset))
        }
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: surface)
        let input = PlaybackSmartFillPlannerInput(
            surface: surface, candidates: candidates, protectionSnapshot: protectionSnapshot, policy: policy,
            playbackSessionSeed: scene.playbackSessionId.uuidString, sceneOrdinal: scene.sequence)
        let retainedLayout = LayoutCandidate(
            variant: readback.layoutVariant,
            ratioPreset: PlaybackSmartFillRatioPreset(
                id: readback.ratioPreset,
                primaryShare: scene.photoSlots[0].planning.displayFrame.width
                    * scene.photoSlots[0].planning.displayFrame.height),
            frames: scene.photoSlots.map { $0.planning.displayFrame })
        var state = PlannerState()
        var chosenLayout = retainedLayout
        var acceptedEvaluation: LayoutEvaluation?
        let layouts: [LayoutCandidate]
        if scene.photoSlots.count == 1 {
            layouts = [retainedLayout]
        } else {
            var alternatives = layoutCandidates(for: readback.sceneType, policy: policy)
            if scene.photoSlots.count == 2 {
                alternatives += constructiveDoubleDirections(for: policy, surface: surface).flatMap { direction in
                    constructiveDoubleAttempts(
                        candidates: candidates, isCurrentPrimary: true, surface: surface, policy: policy,
                        direction: direction
                    ).map(\.layout)
                }
            }
            layouts =
                (policy.layoutAllowlist.contains(retainedLayout.variant) ? [retainedLayout] : [])
                + aspectAwareLayoutOrder(alternatives, candidates: candidates, surface: surface)
        }
        for layout in layouts {
            if let evaluation = evaluate(input: input, candidates: candidates, layout: layout, state: &state) {
                chosenLayout = layout
                acceptedEvaluation = evaluation
                break
            }
        }
        // An impossible fixed-asset reflow keeps its topology, with fresh protected crops, until normal navigation.
        let slots =
            acceptedEvaluation?.slots
            ?? zip(candidates, retainedLayout.frames).enumerated().map { index, pair in
                let (candidate, frame) = pair
                let protected = protectedRects(for: candidate, policy: policy)
                let crop = cropRect(for: candidate, frame: frame, surface: surface, protectedRects: protected)
                return PlaybackSmartFillSlot(
                    role: role(for: index), candidateReference: candidate.reference, frameInScene: frame,
                    cropRectInSource: crop, sourceImageSummary: candidate.sourceImage, rejectRisks: state.rejectReasons,
                    cropRetention: crop.width * crop.height,
                    protectionContained: protected.allSatisfy { crop.contains($0, margin: 0) },
                    slotAspectRatio: slotAspectRatio(frame: frame, surface: surface))
            }
        let baseReadback = PlaybackSmartFillSceneReadback(
            version: readback.version, sceneType: readback.sceneType, layoutPolicyId: policy.layoutPolicyId,
            surfaceKey: surface.surfaceKey, layoutVariant: chosenLayout.variant,
            ratioPreset: chosenLayout.ratioPreset.id,
            slotRoles: slots.map(\.role), fallbackReason: readback.fallbackReason,
            fallbackCategory: readback.fallbackCategory,
            candidateWindowUsed: readback.candidateWindowUsed, evaluationCount: state.evaluationCount,
            rotationStartLayoutVariant: readback.rotationStartLayoutVariant,
            rotationStartRatioPreset: readback.rotationStartRatioPreset, acceptedLayoutVariant: chosenLayout.variant,
            acceptedRatioPreset: chosenLayout.ratioPreset.id, rotationKeyHashPrefix: readback.rotationKeyHashPrefix,
            rejectedLayoutReasonTopList: state.topRejectedReasons(),
            reasonCodes: makeReasonCodes(
                sceneType: readback.sceneType, layoutPolicyId: policy.layoutPolicyId, surfaceKey: surface.surfaceKey,
                layoutVariant: chosenLayout.variant, ratioPreset: chosenLayout.ratioPreset.id,
                candidateWindowUsed: readback.candidateWindowUsed, rejectReasons: state.rejectReasons,
                fallbackReason: readback.fallbackReason, fallbackCategory: readback.fallbackCategory),
            actionTimestamp: readback.actionTimestamp, scenePublishTimestamp: readback.scenePublishTimestamp,
            actionToSceneLatencyMilliseconds: readback.actionToSceneLatencyMilliseconds)
        #if DEBUG
        let protection =
            acceptedEvaluation?.protectionSummary
            ?? protectionSummary(
                candidates: candidates, frames: chosenLayout.frames, surface: surface,
                protectionSnapshot: protectionSnapshot, policy: policy)
        let originalCurrentEvidence = readback.qaDebugSummary.split(separator: ";").filter {
            $0.hasPrefix("currentAsset")
        }
        let disposition = originalCurrentEvidence.first { $0.hasPrefix("currentAssetDisposition=") }?
            .split(separator: "=", maxSplits: 1).last.map(String.init)
        let currentSlotIndex: Int?
        switch disposition {
        case PlaybackSmartFillCurrentAssetDisposition.secondarySlot.rawValue: currentSlotIndex = 1
        case PlaybackSmartFillCurrentAssetDisposition.tertiarySlot.rawValue: currentSlotIndex = 2
        case PlaybackSmartFillCurrentAssetDisposition.primarySlot.rawValue,
            PlaybackSmartFillCurrentAssetDisposition.singleSlot.rawValue,
            PlaybackSmartFillCurrentAssetDisposition.fallbackCurrent.rawValue:
            currentSlotIndex = 0
        default: currentSlotIndex = originalCurrentEvidence.isEmpty ? 0 : nil
        }
        var evidenceCandidates = candidates
        if let currentSlotIndex, evidenceCandidates.indices.contains(currentSlotIndex) {
            let current = evidenceCandidates.remove(at: currentSlotIndex)
            evidenceCandidates.insert(current, at: 0)
        }
        let evidenceInput = PlaybackSmartFillPlannerInput(
            surface: surface, candidates: evidenceCandidates, protectionSnapshot: protectionSnapshot, policy: policy,
            playbackSessionSeed: input.playbackSessionSeed, sceneOrdinal: input.sceneOrdinal)
        let rotation = RotationInfo(
            startIndex: 0, startVariant: readback.rotationStartLayoutVariant,
            startRatioPreset: readback.rotationStartRatioPreset, hashPrefix: readback.rotationKeyHashPrefix)
        let summary = qaSummary(
            input: input, sceneType: readback.sceneType, layout: chosenLayout, slots: slots,
            protectionSummary: protection, fallbackReason: readback.fallbackReason,
            fallbackCategory: readback.fallbackCategory, candidateWindowUsed: readback.candidateWindowUsed,
            evaluationCount: state.evaluationCount, rotation: rotation, rejectReasons: state.rejectReasons,
            rejectedLayoutReasonTopList: state.topRejectedReasons(),
            rejectedLayoutDiagnostics: state.rejectedLayoutDiagnostics,
            currentEvidence: currentAssetEvidence(input: evidenceInput, sceneType: readback.sceneType, slots: slots))
        // Keep selection identity, but report live geometry for the original candidate's slot.
        let preservedEvidence = originalCurrentEvidence.filter {
            currentSlotIndex == nil || $0.hasPrefix("currentAssetDisposition=")
                || $0.hasPrefix("currentAssetAbsentReason=")
        }
        let preservedKeys = Set(preservedEvidence.map { $0.split(separator: "=", maxSplits: 1)[0] })
        let summaryParts = summary.split(separator: ";").filter {
            !preservedKeys.contains($0.split(separator: "=", maxSplits: 1)[0])
        }
        let qaReadback = baseReadback.recordingQADebugSummary(
            (summaryParts + preservedEvidence).joined(separator: ";")
                + ";surfaceReflow=\(acceptedEvaluation == nil ? "retained-layout-unrepresentable" : "accepted")")
        #else
        let qaReadback = baseReadback
        #endif
        let projectedReadback: PlaybackSmartFillSceneReadback
        if let actionTimestamp = readback.actionTimestamp, let publishTimestamp = readback.scenePublishTimestamp {
            projectedReadback = qaReadback.recordingPublishTiming(
                actionTimestamp: actionTimestamp, scenePublishTimestamp: publishTimestamp)
        } else {
            projectedReadback = qaReadback
        }
        let photoSlots = zip(scene.photoSlots, slots).enumerated().map { index, pair in
            let (original, slot) = pair
            let snapshot = PlaybackPlanningSnapshot(
                version: original.planning.version, sourceImage: slot.sourceImageSummary,
                displayFrame: slot.frameInScene, cropRect: slot.cropRectInSource,
                qualityDecision: original.planning.qualityDecision,
                faceProtection: candidates[index].faceRects.isEmpty
                    ? .notApplied
                    : (slot.protectionContained ? .accepted : .rejected),
                focalSummary: original.planning.focalSummary, fallbackReasons: original.planning.fallbackReasons)
            #if DEBUG
            let displaySummary = [
                slot.frameInScene.x, slot.frameInScene.y, slot.frameInScene.width, slot.frameInScene.height
            ]
            .map(format).joined(separator: ",")
            let cropSummary = [
                slot.cropRectInSource.x, slot.cropRectInSource.y, slot.cropRectInSource.width,
                slot.cropRectInSource.height
            ]
            .map(format).joined(separator: ",")
            let planning = snapshot.recordingQADebugSummary(
                "version=\(snapshot.version);surfaceKey=\(surface.surfaceKey);role=\(slot.role.rawValue)"
                    + ";display=\(displaySummary);crop=\(cropSummary)"
                    + ";cropRetention=\(format(slot.cropRetention));protectionContained=\(slot.protectionContained)")
            #else
            let planning = snapshot
            #endif
            return PhotoSlot(
                id: original.id, asset: original.asset, planning: planning,
                motionSeedCropRect: original.motionSeedCropRect)
        }
        return PlaybackScene(
            id: scene.id, playbackSessionId: scene.playbackSessionId, sequence: scene.sequence, photoSlots: photoSlots,
            fallbackReason: scene.fallbackReason, protectionSnapshot: protectionSnapshot,
            smartFillReadback: projectedReadback,
            planningSurface: surface)
    }
}
