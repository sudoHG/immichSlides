import Foundation

extension PlaybackSmartFillPlanner {
    nonisolated static func evaluate(
        input: PlaybackSmartFillPlannerInput,
        candidates: [PlaybackSmartFillCandidateSummary],
        layout: LayoutCandidate,
        state: inout PlannerState
    ) -> LayoutEvaluation? {
        guard candidates.count == layout.frames.count else { return nil }
        guard state.reserveEvaluation(policy: input.policy) else { return nil }

        let geometry = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: layout.frames,
            photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor(surface: input.surface)
        )
        guard geometry.isFullCanvas else {
            state.record(.layoutCanvasNotFilled)
            return nil
        }

        if layout.variant != .single {
            for (index, frame) in layout.frames.enumerated() {
                let slotAspect = slotAspectRatio(frame: frame, surface: input.surface)
                guard input.policy.slotAspectRatioRange.contains(slotAspect) else {
                    state.record(.slotAspectRatioOutOfRange)
                    #if DEBUG
                    state.recordRejectedLayoutDiagnostic(
                        reason: .slotAspectRatioOutOfRange,
                        candidate: candidates[index],
                        layout: layout,
                        slotIndex: index,
                        frame: frame,
                        surface: input.surface,
                        policy: input.policy
                    )
                    #endif
                    return nil
                }
            }

            if let rejectedSecondaryIndex = layout.frames.indices.dropFirst().first(where: {
                area(of: layout.frames[$0]) < input.policy.minimumSecondaryArea
            }) {
                let reason: PlaybackSmartFillPlannerRejectReason =
                    layout.variant.isTriple ? .triplePhotoWallRejected : .auxiliaryUnreadable
                state.record(reason)
                #if DEBUG
                state.recordRejectedLayoutDiagnostic(
                    reason: reason,
                    candidate: candidates[rejectedSecondaryIndex],
                    layout: layout,
                    slotIndex: rejectedSecondaryIndex,
                    frame: layout.frames[rejectedSecondaryIndex],
                    surface: input.surface,
                    policy: input.policy
                )
                #endif
                return nil
            }
        }

        var slots: [PlaybackSmartFillSlot] = []
        for (index, candidate) in candidates.enumerated() {
            let frame = layout.frames[index]
            guard candidate.pixelSize != nil else {
                state.record(.missingImageSize)
                return nil
            }

            let protectedRects = protectedRects(for: candidate, policy: input.policy)
            let crop = cropRect(
                for: candidate,
                frame: frame,
                surface: input.surface,
                protectedRects: protectedRects
            )
            let cropRetention = crop.width * crop.height
            guard cropRetention >= input.policy.cropRetentionThreshold else {
                state.record(.cropRetentionTooLow)
                #if DEBUG
                state.recordRejectedLayoutDiagnostic(
                    reason: .cropRetentionTooLow,
                    candidate: candidate,
                    layout: layout,
                    slotIndex: index,
                    frame: frame,
                    surface: input.surface,
                    policy: input.policy,
                    cropRetention: cropRetention
                )
                #endif
                return nil
            }

            let protectionContained = protectedRects.allSatisfy { crop.contains($0, margin: 0) }
            guard protectionContained else {
                state.record(.faceCropDestroyed)
                #if DEBUG
                state.recordRejectedLayoutDiagnostic(
                    reason: .faceCropDestroyed,
                    candidate: candidate,
                    layout: layout,
                    slotIndex: index,
                    frame: frame,
                    surface: input.surface,
                    policy: input.policy,
                    cropRetention: cropRetention
                )
                #endif
                return nil
            }

            guard
                !effectivePixelsTooLow(
                    candidate: candidate,
                    frame: frame,
                    surface: input.surface,
                    policy: input.policy,
                    crop: crop
                )
            else {
                state.record(.effectivePixelsTooLow)
                #if DEBUG
                state.recordRejectedLayoutDiagnostic(
                    reason: .effectivePixelsTooLow,
                    candidate: candidate,
                    layout: layout,
                    slotIndex: index,
                    frame: frame,
                    surface: input.surface,
                    policy: input.policy,
                    cropRetention: cropRetention
                )
                #endif
                return nil
            }

            let slot = PlaybackSmartFillSlot(
                role: role(for: index),
                candidateReference: candidate.reference,
                frameInScene: frame,
                cropRectInSource: crop,
                sourceImageSummary: candidate.sourceImage,
                rejectRisks: [],
                cropRetention: cropRetention,
                protectionContained: protectionContained,
                slotAspectRatio: slotAspectRatio(frame: frame, surface: input.surface)
            )
            slots.append(slot)
        }

        let protection = protectionSummary(
            candidates: candidates,
            frames: layout.frames,
            surface: input.surface,
            protectionSnapshot: input.protectionSnapshot,
            policy: input.policy
        )
        guard protection.status != .rejected else {
            state.record(.protectionOverlap)
            #if DEBUG
            if let candidate = candidates.first,
                let frame = layout.frames.first
            {
                state.recordRejectedLayoutDiagnostic(
                    reason: .protectionOverlap,
                    candidate: candidate,
                    layout: layout,
                    slotIndex: 0,
                    frame: frame,
                    surface: input.surface,
                    policy: input.policy,
                    cropRetention: slots.first?.cropRetention
                )
            }
            #endif
            return nil
        }

        return LayoutEvaluation(slots: slots, protectionSummary: protection)
    }

    nonisolated static func acceptedResult(
        input: PlaybackSmartFillPlannerInput,
        sceneType: PlaybackSmartFillSceneType,
        layout: LayoutCandidate,
        slots: [PlaybackSmartFillSlot],
        state: PlannerState,
        faceStatus: PlaybackSmartFillFaceProtectionStatus,
        protectionSummary: PlaybackSmartFillProtectionSummary,
        readability: PlaybackSmartFillReadabilitySummary,
        candidateWindowUsed: Int,
        rotation: RotationInfo
    ) -> PlaybackSmartFillPlannerResult {
        let currentEvidence = currentAssetEvidence(
            input: input,
            sceneType: sceneType,
            slots: slots
        )
        let reasonCodes = makeReasonCodes(
            sceneType: sceneType,
            layoutPolicyId: input.policy.layoutPolicyId,
            surfaceKey: input.surface.surfaceKey,
            layoutVariant: layout.variant,
            ratioPreset: layout.ratioPreset.id,
            candidateWindowUsed: candidateWindowUsed,
            rejectReasons: state.rejectReasons,
            fallbackReason: nil,
            fallbackCategory: .none
        )
        let plannerResult = PlaybackSmartFillPlannerResult(
            sceneType: sceneType,
            layoutPolicyId: input.policy.layoutPolicyId,
            surfaceKey: input.surface.surfaceKey,
            layoutVariant: layout.variant,
            ratioPreset: layout.ratioPreset.id,
            slots: slots,
            fallbackReason: nil,
            fallbackCategory: .none,
            rejectReasonsTried: state.rejectReasons,
            rejectedLayoutReasonTopList: state.topRejectedReasons(),
            qualityDecision: .smartFillAccepted,
            faceProtectionSummary: faceStatus,
            protectionSummary: protectionSummary,
            readabilitySummary: readability,
            candidateWindowUsed: candidateWindowUsed,
            evaluationCount: state.evaluationCount,
            rotationStartLayoutVariant: rotation.startVariant,
            rotationStartRatioPreset: rotation.startRatioPreset,
            acceptedLayoutVariant: layout.variant,
            acceptedRatioPreset: layout.ratioPreset.id,
            rotationKeyHashPrefix: rotation.hashPrefix,
            reasonCodes: reasonCodes,
            acceptedSceneSearchTier: PlaybackSmartFillAcceptedSceneSearchTier(sceneType: sceneType),
            currentAssetDisposition: currentEvidence.disposition,
            currentAssetAbsentReason: currentEvidence.absentReason,
            currentAssetSlotAreaRatio: currentEvidence.slotAreaRatio,
            currentAssetCropRetention: currentEvidence.cropRetention,
            currentAssetProtectedRegionCoverage: currentEvidence.protectedRegionCoverage,
            currentAssetFaceProtectionPassed: currentEvidence.faceProtectionPassed,
            currentAssetSubjectProtectionPassed: currentEvidence.subjectProtectionPassed,
            currentAssetVisibleQualityClass: currentEvidence.visibleQuality,
            ledgerSceneAssets: currentEvidence.ledgerSceneAssets,
            slotRoles: currentEvidence.slotRoles,
            slotRefs: currentEvidence.slotRefs
        )
        #if DEBUG
        return plannerResult.recordingQADebugSummary(
            qaSummary(
                input: input,
                sceneType: sceneType,
                layout: layout,
                slots: slots,
                protectionSummary: protectionSummary,
                fallbackReason: nil,
                fallbackCategory: .none,
                candidateWindowUsed: candidateWindowUsed,
                evaluationCount: state.evaluationCount,
                rotation: rotation,
                rejectReasons: state.rejectReasons,
                rejectedLayoutReasonTopList: state.topRejectedReasons(),
                rejectedLayoutDiagnostics: state.rejectedLayoutDiagnostics,
                currentEvidence: currentEvidence
            ))
        #else
        return plannerResult
        #endif
    }

    nonisolated static func fallbackResult(
        input: PlaybackSmartFillPlannerInput,
        fallbackReason: PlaybackSmartFillFallbackReason,
        state: PlannerState,
        faceStatus: PlaybackSmartFillFaceProtectionStatus,
        protectionSummary: PlaybackSmartFillProtectionSummary
    ) -> PlaybackSmartFillPlannerResult {
        let fallbackCandidate = input.candidates.first
        let slots =
            fallbackCandidate.map {
                [
                    makeFallbackSlot(
                        candidate: $0,
                        surface: input.surface,
                        policy: input.policy
                    )
                ]
            } ?? []
        let rotation =
            fallbackCandidate.map {
                rotationInfo(input: input, primary: $0, sceneType: .fallback)
            }
            ?? RotationInfo(
                startIndex: 0,
                startVariant: .single,
                startRatioPreset: "fallback",
                hashPrefix: "none"
            )
        let fallbackCategory = PlaybackSmartFillFallbackCategory.classify(
            fallbackReason: fallbackReason,
            rejectReasons: state.rejectReasons,
            protectionSummary: protectionSummary
        )
        let currentEvidence = currentAssetEvidence(
            input: input,
            sceneType: .fallback,
            slots: slots
        )
        let reasonCodes = makeReasonCodes(
            sceneType: .fallback,
            layoutPolicyId: input.policy.layoutPolicyId,
            surfaceKey: input.surface.surfaceKey,
            layoutVariant: .single,
            ratioPreset: "fallback",
            candidateWindowUsed: state.candidateWindowUsed,
            rejectReasons: state.rejectReasons,
            fallbackReason: fallbackReason,
            fallbackCategory: fallbackCategory
        )
        let plannerResult = PlaybackSmartFillPlannerResult(
            sceneType: .fallback,
            layoutPolicyId: input.policy.layoutPolicyId,
            surfaceKey: input.surface.surfaceKey,
            layoutVariant: .single,
            ratioPreset: "fallback",
            slots: slots,
            fallbackReason: fallbackReason,
            fallbackCategory: fallbackCategory,
            rejectReasonsTried: state.rejectReasons,
            rejectedLayoutReasonTopList: state.topRejectedReasons(),
            qualityDecision: .smartFillFallback,
            faceProtectionSummary: faceStatus,
            protectionSummary: protectionSummary,
            readabilitySummary: readabilitySummary(policy: input.policy, frames: []),
            candidateWindowUsed: state.candidateWindowUsed,
            evaluationCount: state.evaluationCount,
            rotationStartLayoutVariant: rotation.startVariant,
            rotationStartRatioPreset: rotation.startRatioPreset,
            acceptedLayoutVariant: .single,
            acceptedRatioPreset: "fallback",
            rotationKeyHashPrefix: rotation.hashPrefix,
            reasonCodes: reasonCodes,
            acceptedSceneSearchTier: .fallback,
            currentAssetDisposition: currentEvidence.disposition,
            currentAssetAbsentReason: currentEvidence.absentReason,
            currentAssetSlotAreaRatio: currentEvidence.slotAreaRatio,
            currentAssetCropRetention: currentEvidence.cropRetention,
            currentAssetProtectedRegionCoverage: currentEvidence.protectedRegionCoverage,
            currentAssetFaceProtectionPassed: currentEvidence.faceProtectionPassed,
            currentAssetSubjectProtectionPassed: currentEvidence.subjectProtectionPassed,
            currentAssetVisibleQualityClass: currentEvidence.visibleQuality,
            ledgerSceneAssets: currentEvidence.ledgerSceneAssets,
            slotRoles: currentEvidence.slotRoles,
            slotRefs: currentEvidence.slotRefs
        )
        #if DEBUG
        return plannerResult.recordingQADebugSummary(
            qaSummary(
                input: input,
                sceneType: .fallback,
                layout: LayoutCandidate(
                    variant: .single,
                    ratioPreset: PlaybackSmartFillRatioPreset(id: "fallback", primaryShare: 1),
                    frames: [.fullUnitRect]
                ),
                slots: slots,
                protectionSummary: protectionSummary,
                fallbackReason: fallbackReason,
                fallbackCategory: fallbackCategory,
                candidateWindowUsed: state.candidateWindowUsed,
                evaluationCount: state.evaluationCount,
                rotation: rotation,
                rejectReasons: state.rejectReasons,
                rejectedLayoutReasonTopList: state.topRejectedReasons(),
                rejectedLayoutDiagnostics: state.rejectedLayoutDiagnostics,
                currentEvidence: currentEvidence
            ))
        #else
        return plannerResult
        #endif
    }

    private nonisolated static func makeFallbackSlot(
        candidate: PlaybackSmartFillCandidateSummary,
        surface: PlaybackSmartFillSurface,
        policy: PlaybackSmartFillLayoutPolicy
    ) -> PlaybackSmartFillSlot {
        let protected = protectedRects(for: candidate, policy: policy)
        let crop = cropRect(for: candidate, frame: .fullUnitRect, surface: surface, protectedRects: protected)
        return PlaybackSmartFillSlot(
            role: .primary,
            candidateReference: candidate.reference,
            frameInScene: .fullUnitRect,
            cropRectInSource: crop,
            sourceImageSummary: candidate.sourceImage,
            rejectRisks: [],
            cropRetention: crop.width * crop.height,
            protectionContained: protected.allSatisfy { crop.contains($0, margin: 0) },
            slotAspectRatio: surface.aspectRatio
        )
    }
}
