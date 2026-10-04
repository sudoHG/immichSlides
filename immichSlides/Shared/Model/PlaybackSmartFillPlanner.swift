//
//  PlaybackSmartFillPlanner.swift
//  immichSlides
//
//  Smart Fill pure planner: synchronous computation only; no network, disk cache, or SwiftUI access.
//

import Foundation

enum PlaybackSmartFillPlanner {

    nonisolated static func plan(_ input: PlaybackSmartFillPlannerInput) -> PlaybackSmartFillPlannerResult {
        var state = PlannerState()
        appendStaticPolicyRejects(input.policy, into: &state)

        guard !input.candidates.isEmpty else {
            state.record(.missingCandidates)
            return fallbackResult(
                input: input,
                fallbackReason: .missingCandidates,
                state: state,
                faceStatus: .notApplied,
                protectionSummary: .accepted
            )
        }

        let primary = input.candidates[0]

        for searchStep in input.policy.sceneSearchOrder {
            guard !state.isEvaluationBudgetExhausted else { break }
            switch searchStep {
            case .single:
                if let single = makeSingleResult(input: input, state: &state) {
                    return single
                }
            case .double:
                if let double = makeMultiSlotResult(
                    input: input,
                    primary: primary,
                    sceneType: .double,
                    requiredSecondaryCount: 1,
                    state: &state
                ) {
                    return double
                }
            case .triple:
                if let triple = makeMultiSlotResult(
                    input: input,
                    primary: primary,
                    sceneType: .triple,
                    requiredSecondaryCount: 2,
                    state: &state
                ) {
                    return triple
                }
            case .fallback:
                continue
            }
        }

        state.record(.allLayoutsRejected)
        return fallbackResult(
            input: input,
            fallbackReason: .allLayoutsRejected,
            state: state,
            faceStatus: state.rejectReasons.contains(.faceCropDestroyed) ? .rejected : .notApplied,
            protectionSummary: protectionSummary(
                candidates: [primary],
                frames: [.fullUnitRect],
                surface: input.surface,
                protectionSnapshot: input.protectionSnapshot,
                policy: input.policy
            )
        )
    }

    private nonisolated static func makeSingleResult(
        input: PlaybackSmartFillPlannerInput,
        state: inout PlannerState
    ) -> PlaybackSmartFillPlannerResult? {
        let layout = LayoutCandidate(
            variant: .single,
            ratioPreset: PlaybackSmartFillRatioPreset(id: "full", primaryShare: 1),
            frames: [.fullUnitRect]
        )

        if !input.policy.allowsSingleCandidateLookahead {
            let primary = input.candidates[0]
            let rotation = rotationInfo(input: input, primary: primary, sceneType: .single)
            guard
                let evaluation = evaluate(
                    input: input,
                    candidates: [primary],
                    layout: layout,
                    state: &state
                )
            else {
                return nil
            }

            return acceptedResult(
                input: input,
                sceneType: .single,
                layout: layout,
                slots: evaluation.slots,
                state: state,
                faceStatus: primary.faceRects.isEmpty ? .notApplied : .accepted,
                protectionSummary: evaluation.protectionSummary,
                readability: readabilitySummary(policy: input.policy, frames: []),
                candidateWindowUsed: 1,
                rotation: rotation
            )
        }

        var evaluatedCount = 0
        for window in input.policy.candidateWindowPresets {
            guard !state.isEvaluationBudgetExhausted else { return nil }
            state.candidateWindowUsed = window
            let upperBound = min(window, input.candidates.count)
            guard upperBound > evaluatedCount else { continue }

            for candidateOffset in evaluatedCount..<upperBound {
                guard !state.isEvaluationBudgetExhausted else { return nil }
                let primary = input.candidates[candidateOffset]
                let rotation = rotationInfo(input: input, primary: primary, sceneType: .single)
                guard
                    let evaluation = evaluate(
                        input: input,
                        candidates: [primary],
                        layout: layout,
                        state: &state
                    )
                else {
                    if state.isEvaluationBudgetExhausted { return nil }
                    continue
                }

                return acceptedResult(
                    input: input,
                    sceneType: .single,
                    layout: layout,
                    slots: evaluation.slots,
                    state: state,
                    faceStatus: primary.faceRects.isEmpty ? .notApplied : .accepted,
                    protectionSummary: evaluation.protectionSummary,
                    readability: readabilitySummary(policy: input.policy, frames: []),
                    candidateWindowUsed: candidateOffset + 1,
                    rotation: rotation
                )
            }
            evaluatedCount = upperBound
        }

        state.record(.candidateWindowExhausted)
        return nil
    }

    private nonisolated static func makeMultiSlotResult(
        input: PlaybackSmartFillPlannerInput,
        primary: PlaybackSmartFillCandidateSummary,
        sceneType: PlaybackSmartFillSceneType,
        requiredSecondaryCount: Int,
        state: inout PlannerState
    ) -> PlaybackSmartFillPlannerResult? {
        if sceneType == .double {
            return makeConstructiveDoubleResult(
                input: input,
                current: primary,
                state: &state
            )
        }

        let rotation = rotationInfo(input: input, primary: primary, sceneType: sceneType)
        let layouts = rotated(
            layoutCandidates(for: sceneType, policy: input.policy),
            by: rotation.startIndex
        )
        guard !layouts.isEmpty else {
            if sceneType == .triple {
                state.record(.tripleDisallowedOnSurface)
            } else {
                state.record(.horizontalDoubleDisallowedOnSurface)
                state.record(.verticalDoubleDisallowedOnSurface)
            }
            return nil
        }

        var previousSecondaryPoolCount = 0
        // Using current as an auxiliary slot is the fallback path for restoring big-screen triple quality, so the
        // normal primary search must not use up the whole budget.
        let auxiliaryEvaluationReserve =
            input.policy.allowsCurrentCandidateAsAuxiliaryLookahead ? input.policy.currentAuxiliaryEvaluationReserve : 0
        let primaryPhaseEvaluationLimit = max(0, input.policy.evaluationBudget - auxiliaryEvaluationReserve)
        var primaryPhaseStoppedForAuxiliaryBudget = false

        primarySearch: for window in input.policy.candidateWindowPresets {
            guard !state.isEvaluationBudgetExhausted else { return nil }
            // Once the primary phase budget is reached, yield early to the auxiliary lookahead so an acceptable triple
            // is not starved.
            if auxiliaryEvaluationReserve > 0,
                state.evaluationCount >= primaryPhaseEvaluationLimit
            {
                primaryPhaseStoppedForAuxiliaryBudget = true
                state.record(.candidateWindowExhausted)
                break primarySearch
            }
            state.candidateWindowUsed = window
            let windowCandidates = Array(input.candidates.prefix(min(window, input.candidates.count)))
            guard windowCandidates.count > requiredSecondaryCount else {
                state.record(sceneType == .double ? .insufficientCandidatesForDouble : .insufficientCandidatesForTriple)
                continue
            }

            let secondaryPool = Array(windowCandidates.dropFirst().prefix(input.policy.multiSlotCandidatePoolLimit))
            guard secondaryPool.count >= requiredSecondaryCount else {
                state.record(sceneType == .double ? .insufficientCandidatesForDouble : .insufficientCandidatesForTriple)
                continue
            }

            // Window expansion only tests combinations that newly entered the window; combinations that already failed
            // in the old window do not spend budget again.
            for selectedSecondaries in combinations(
                from: secondaryPool,
                count: requiredSecondaryCount,
                requiringIndexAtLeast: previousSecondaryPoolCount
            ) {
                guard !state.isEvaluationBudgetExhausted else { return nil }
                if auxiliaryEvaluationReserve > 0,
                    state.evaluationCount >= primaryPhaseEvaluationLimit
                {
                    primaryPhaseStoppedForAuxiliaryBudget = true
                    state.record(.candidateWindowExhausted)
                    break primarySearch
                }
                let selected = [primary] + selectedSecondaries
                for layout in aspectAwareLayoutOrder(
                    layouts,
                    candidates: selected,
                    surface: input.surface
                ) {
                    guard !state.isEvaluationBudgetExhausted else { return nil }
                    if auxiliaryEvaluationReserve > 0,
                        state.evaluationCount >= primaryPhaseEvaluationLimit
                    {
                        primaryPhaseStoppedForAuxiliaryBudget = true
                        state.record(.candidateWindowExhausted)
                        break primarySearch
                    }
                    guard
                        let evaluation = evaluate(
                            input: input,
                            candidates: selected,
                            layout: layout,
                            state: &state
                        )
                    else {
                        if state.isEvaluationBudgetExhausted { return nil }
                        if auxiliaryEvaluationReserve > 0,
                            state.evaluationCount >= primaryPhaseEvaluationLimit
                        {
                            primaryPhaseStoppedForAuxiliaryBudget = true
                            state.record(.candidateWindowExhausted)
                            break primarySearch
                        }
                        continue
                    }

                    return acceptedResult(
                        input: input,
                        sceneType: sceneType,
                        layout: layout,
                        slots: evaluation.slots,
                        state: state,
                        faceStatus: selected.flatMap(\.faceRects).isEmpty ? .notApplied : .accepted,
                        protectionSummary: evaluation.protectionSummary,
                        readability: readabilitySummary(policy: input.policy, frames: Array(layout.frames.dropFirst())),
                        candidateWindowUsed: window,
                        rotation: rotation
                    )
                }
            }
            previousSecondaryPoolCount = max(previousSecondaryPoolCount, secondaryPool.count)
        }

        if (input.policy.allowsCurrentCandidateAsAuxiliaryLookahead || primaryPhaseStoppedForAuxiliaryBudget),
            let auxiliaryResult = makeCurrentAuxiliaryMultiSlotResult(
                input: input,
                current: primary,
                sceneType: sceneType,
                requiredSecondaryCount: requiredSecondaryCount,
                state: &state
            )
        {
            return auxiliaryResult
        }

        state.record(.candidateWindowExhausted)
        if state.rejectReasons.contains(.faceCropDestroyed) {
            state.record(.primaryCandidateRejected)
        }
        return nil
    }

    private nonisolated static func makeCurrentAuxiliaryMultiSlotResult(
        input: PlaybackSmartFillPlannerInput,
        current: PlaybackSmartFillCandidateSummary,
        sceneType: PlaybackSmartFillSceneType,
        requiredSecondaryCount: Int,
        state: inout PlannerState
    ) -> PlaybackSmartFillPlannerResult? {
        guard requiredSecondaryCount >= 1 else { return nil }
        let baseLayouts = layoutCandidates(for: sceneType, policy: input.policy)
        guard !baseLayouts.isEmpty else { return nil }

        var previousPrimaryPoolCount = 0
        for window in input.policy.candidateWindowPresets {
            guard !state.isEvaluationBudgetExhausted else { return nil }
            state.candidateWindowUsed = window
            let windowCandidates = Array(input.candidates.prefix(min(window, input.candidates.count)))
            guard windowCandidates.count > requiredSecondaryCount else {
                state.record(sceneType == .double ? .insufficientCandidatesForDouble : .insufficientCandidatesForTriple)
                continue
            }

            let primaryPool = Array(windowCandidates.dropFirst().prefix(input.policy.multiSlotCandidatePoolLimit))
            guard !primaryPool.isEmpty else {
                state.record(sceneType == .double ? .insufficientCandidatesForDouble : .insufficientCandidatesForTriple)
                continue
            }

            for promotedPrimaryIndex in primaryPool.indices {
                let promotedPrimary = primaryPool[promotedPrimaryIndex]
                guard !state.isEvaluationBudgetExhausted else { return nil }
                let rotation = rotationInfo(input: input, primary: promotedPrimary, sceneType: sceneType)
                let layouts = auxiliaryCurrentAwareLayoutOrder(
                    rotated(baseLayouts, by: rotation.startIndex),
                    current: current,
                    surface: input.surface
                )
                let additionalAuxiliaryPool = primaryPool.filter { $0.reference != promotedPrimary.reference }
                let slotCount = requiredSecondaryCount + 1
                let additionalAuxiliaryCount = slotCount - 2
                guard additionalAuxiliaryPool.count >= additionalAuxiliaryCount else {
                    state.record(
                        sceneType == .double ? .insufficientCandidatesForDouble : .insufficientCandidatesForTriple)
                    continue
                }

                for layout in layouts {
                    guard !state.isEvaluationBudgetExhausted else { return nil }
                    guard layout.frames.count == slotCount else { continue }
                    let currentSlotIndices = auxiliaryCurrentSlotOrder(
                        layout: layout,
                        current: current,
                        surface: input.surface
                    )
                    for additionalAuxiliaries in combinations(
                        from: additionalAuxiliaryPool, count: additionalAuxiliaryCount)
                    {
                        guard !state.isEvaluationBudgetExhausted else { return nil }
                        // When the promoted primary and the auxiliary combination both come from the old window, the
                        // result was already tried in a smaller window.
                        if promotedPrimaryIndex < previousPrimaryPoolCount,
                            !additionalAuxiliaries.contains(where: { candidate in
                                primaryPool.firstIndex(where: { $0.reference == candidate.reference }).map {
                                    $0 >= previousPrimaryPoolCount
                                } ?? false
                            })
                        {
                            continue
                        }
                        for currentSlotIndex in currentSlotIndices {
                            guard !state.isEvaluationBudgetExhausted else { return nil }
                            var selectedBySlot: [PlaybackSmartFillCandidateSummary?] = Array(
                                repeating: nil,
                                count: layout.frames.count
                            )
                            selectedBySlot[0] = promotedPrimary
                            selectedBySlot[currentSlotIndex] = current

                            var additionalIndex = 0
                            for slotIndex in layout.frames.indices.dropFirst() where slotIndex != currentSlotIndex {
                                selectedBySlot[slotIndex] = additionalAuxiliaries[additionalIndex]
                                additionalIndex += 1
                            }
                            let selected = selectedBySlot.compactMap { $0 }
                            guard selected.count == layout.frames.count else { continue }

                            guard
                                let evaluation = evaluate(
                                    input: input,
                                    candidates: selected,
                                    layout: layout,
                                    state: &state
                                )
                            else {
                                if state.isEvaluationBudgetExhausted { return nil }
                                continue
                            }

                            return acceptedResult(
                                input: input,
                                sceneType: sceneType,
                                layout: layout,
                                slots: evaluation.slots,
                                state: state,
                                faceStatus: selected.flatMap(\.faceRects).isEmpty ? .notApplied : .accepted,
                                protectionSummary: evaluation.protectionSummary,
                                readability: readabilitySummary(
                                    policy: input.policy, frames: Array(layout.frames.dropFirst())),
                                candidateWindowUsed: window,
                                rotation: rotation
                            )
                        }
                    }
                }
            }
            previousPrimaryPoolCount = max(previousPrimaryPoolCount, primaryPool.count)
        }

        return nil
    }

    private nonisolated static func makeConstructiveDoubleResult(
        input: PlaybackSmartFillPlannerInput,
        current: PlaybackSmartFillCandidateSummary,
        state: inout PlannerState
    ) -> PlaybackSmartFillPlannerResult? {
        // For double, first compute the ideal partner that fills with zero cropping, then solve a continuous split
        // ratio; no fixed menu is enumerated.
        let directions = constructiveDoubleDirections(for: input.policy, surface: input.surface)
        guard !directions.isEmpty else {
            state.record(.horizontalDoubleDisallowedOnSurface)
            state.record(.verticalDoubleDisallowedOnSurface)
            return nil
        }

        var triedVerticalPartnerReferences: Set<String> = []
        var triedHorizontalPartnerReferences: Set<String> = []
        for window in input.policy.candidateWindowPresets {
            guard !state.isEvaluationBudgetExhausted else { return nil }
            state.candidateWindowUsed = window
            let windowCandidates = Array(input.candidates.prefix(min(window, input.candidates.count)))
            guard windowCandidates.count > 1 else {
                state.record(.insufficientCandidatesForDouble)
                continue
            }

            let secondaryPool = Array(windowCandidates.dropFirst())
            guard !secondaryPool.isEmpty else {
                state.record(.insufficientCandidatesForDouble)
                continue
            }

            for direction in directions {
                let orderedPartners = constructivePartnerOrder(
                    secondaryPool,
                    current: current,
                    surface: input.surface,
                    direction: direction
                )
                // Top-K relies on ideal-ratio ordering: partners closer to the geometric solution are more likely to
                // pass first, and the slow path usually keeps failing.
                for partner in orderedPartners.prefix(input.policy.constructiveDoublePartnerSearchLimit) {
                    let alreadyTried: Bool
                    switch direction {
                    case .vertical:
                        alreadyTried = triedVerticalPartnerReferences.contains(partner.reference)
                    case .horizontal:
                        alreadyTried = triedHorizontalPartnerReferences.contains(partner.reference)
                    }
                    guard !alreadyTried else { continue }
                    guard !state.isEvaluationBudgetExhausted else { return nil }
                    // Do not retry the same partner during window expansion; directions are recorded separately so the
                    // other valid arrangement direction is not skipped.
                    switch direction {
                    case .vertical:
                        triedVerticalPartnerReferences.insert(partner.reference)
                    case .horizontal:
                        triedHorizontalPartnerReferences.insert(partner.reference)
                    }
                    let attempts = constructiveDoubleAttempts(
                        current: current,
                        partner: partner,
                        surface: input.surface,
                        policy: input.policy,
                        direction: direction
                    )
                    for attempt in attempts {
                        guard !state.isEvaluationBudgetExhausted else { return nil }
                        guard
                            let evaluation = evaluate(
                                input: input,
                                candidates: attempt.candidates,
                                layout: attempt.layout,
                                state: &state
                            )
                        else {
                            if state.isEvaluationBudgetExhausted { return nil }
                            continue
                        }

                        let primary = attempt.candidates[0]
                        let rotation = rotationInfo(input: input, primary: primary, sceneType: .double)
                        return acceptedResult(
                            input: input,
                            sceneType: .double,
                            layout: attempt.layout,
                            slots: evaluation.slots,
                            state: state,
                            faceStatus: attempt.candidates.flatMap(\.faceRects).isEmpty ? .notApplied : .accepted,
                            protectionSummary: evaluation.protectionSummary,
                            readability: readabilitySummary(
                                policy: input.policy, frames: Array(attempt.layout.frames.dropFirst())),
                            candidateWindowUsed: window,
                            rotation: rotation
                        )
                    }
                }
            }
        }

        state.record(.candidateWindowExhausted)
        if state.rejectReasons.contains(.faceCropDestroyed) {
            state.record(.primaryCandidateRejected)
        }
        return nil
    }

    private nonisolated static func evaluate(
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
                    state.recordRejectedLayoutDiagnostic(
                        reason: .slotAspectRatioOutOfRange,
                        candidate: candidates[index],
                        layout: layout,
                        slotIndex: index,
                        frame: frame,
                        surface: input.surface,
                        policy: input.policy
                    )
                    return nil
                }
            }

            if let rejectedSecondaryIndex = layout.frames.indices.dropFirst().first(where: {
                area(of: layout.frames[$0]) < input.policy.minimumSecondaryArea
            }) {
                let reason: PlaybackSmartFillPlannerRejectReason =
                    layout.variant.isTriple ? .triplePhotoWallRejected : .auxiliaryUnreadable
                state.record(reason)
                state.recordRejectedLayoutDiagnostic(
                    reason: reason,
                    candidate: candidates[rejectedSecondaryIndex],
                    layout: layout,
                    slotIndex: rejectedSecondaryIndex,
                    frame: layout.frames[rejectedSecondaryIndex],
                    surface: input.surface,
                    policy: input.policy
                )
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
                return nil
            }

            let protectionContained = protectedRects.allSatisfy { crop.contains($0, margin: 0) }
            guard protectionContained else {
                state.record(.faceCropDestroyed)
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
            return nil
        }

        return LayoutEvaluation(slots: slots, protectionSummary: protection)
    }

    private nonisolated static func acceptedResult(
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
        return PlaybackSmartFillPlannerResult(
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
            qaDebugSummary: qaSummary(
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
            ),
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
    }

    private nonisolated static func fallbackResult(
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
        return PlaybackSmartFillPlannerResult(
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
            qaDebugSummary: qaSummary(
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
            ),
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

    private nonisolated static func layoutCandidates(
        for sceneType: PlaybackSmartFillSceneType,
        policy: PlaybackSmartFillLayoutPolicy
    ) -> [LayoutCandidate] {
        policy.layoutAllowlist
            .filter { $0.sceneType == sceneType }
            .flatMap { variant -> [LayoutCandidate] in
                policy.ratioPresets(for: variant).map { preset in
                    let frames = PlaybackSmartFillLayoutCatalog.frames(for: variant, preset: preset)
                    return LayoutCandidate(variant: variant, ratioPreset: preset, frames: frames)
                }
            }
    }

    private nonisolated static func aspectAwareLayoutOrder(
        _ layouts: [LayoutCandidate],
        candidates: [PlaybackSmartFillCandidateSummary],
        surface: PlaybackSmartFillSurface
    ) -> [LayoutCandidate] {
        layouts.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = estimatedLayoutCropRetentionScore(
                    layout: lhs.element,
                    candidates: candidates,
                    surface: surface
                )
                let rhsScore = estimatedLayoutCropRetentionScore(
                    layout: rhs.element,
                    candidates: candidates,
                    surface: surface
                )
                if abs(lhsScore - rhsScore) > 0.000001 {
                    return lhsScore > rhsScore
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private nonisolated static func constructiveDoubleDirections(
        for policy: PlaybackSmartFillLayoutPolicy,
        surface: PlaybackSmartFillSurface
    ) -> [ConstructiveDoubleDirection] {
        // Try the direction that better matches the surface shape first; the allowlist is still the final boundary, and
        // constructive doubles do not open new layouts.
        let preferred: [ConstructiveDoubleDirection] =
            surface.aspectRatio < 1 ? [.vertical, .horizontal] : [.horizontal, .vertical]
        return preferred.filter { direction in
            switch direction {
            case .vertical:
                return policy.allowsVerticalDouble
            case .horizontal:
                return policy.allowsHorizontalDouble
            }
        }
    }

    private nonisolated static func constructivePartnerOrder(
        _ partners: [PlaybackSmartFillCandidateSummary],
        current: PlaybackSmartFillCandidateSummary,
        surface: PlaybackSmartFillSurface,
        direction: ConstructiveDoubleDirection
    ) -> [PlaybackSmartFillCandidateSummary] {
        guard
            let ideal = idealPartnerAspect(
                current: current,
                surface: surface,
                direction: direction
            )
        else {
            return partners
        }

        // Log-ratio distance makes 0.5x and 2x deviations symmetric, which suits top-K geometric closeness.
        return partners.enumerated()
            .sorted { lhs, rhs in
                let lhsDistance = logarithmicAspectDistance(lhs.element.aspectRatio, ideal: ideal)
                let rhsDistance = logarithmicAspectDistance(rhs.element.aspectRatio, ideal: ideal)
                if abs(lhsDistance - rhsDistance) > 0.000001 {
                    return lhsDistance < rhsDistance
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private nonisolated static func idealPartnerAspect(
        current: PlaybackSmartFillCandidateSummary,
        surface: PlaybackSmartFillSurface,
        direction: ConstructiveDoubleDirection
    ) -> Double? {
        guard let currentAspect = current.aspectRatio,
            currentAspect > 0
        else {
            return nil
        }

        let surfaceAspect = surface.aspectRatio
        switch direction {
        case .vertical:
            // A vertical stack fills with zero cropping when 1/current + 1/partner = 1/surface; there is a positive
            // solution only when current is wider than surface.
            guard currentAspect > surfaceAspect else { return nil }
            let denominator = currentAspect - surfaceAspect
            guard denominator > 0 else { return nil }
            return (surfaceAspect * currentAspect) / denominator
        case .horizontal:
            // A horizontal row fills with zero cropping when current + partner = surface; there is a positive solution
            // only when current is narrower than surface.
            let ideal = surfaceAspect - currentAspect
            return ideal > 0 ? ideal : nil
        }
    }

    private nonisolated static func logarithmicAspectDistance(
        _ aspect: Double?,
        ideal: Double
    ) -> Double {
        guard let aspect,
            aspect > 0,
            ideal > 0
        else {
            return .greatestFiniteMagnitude
        }
        return abs(log(aspect / ideal))
    }

    private nonisolated static func constructiveDoubleAttempts(
        current: PlaybackSmartFillCandidateSummary,
        partner: PlaybackSmartFillCandidateSummary,
        surface: PlaybackSmartFillSurface,
        policy: PlaybackSmartFillLayoutPolicy,
        direction: ConstructiveDoubleDirection
    ) -> [ConstructiveDoubleAttempt] {
        [
            constructiveDoubleAttempts(
                candidates: [current, partner],
                currentIsPrimary: true,
                surface: surface,
                policy: policy,
                direction: direction
            ),
            constructiveDoubleAttempts(
                candidates: [partner, current],
                currentIsPrimary: false,
                surface: surface,
                policy: policy,
                direction: direction
            )
        ]
        .flatMap { $0 }
        .sorted { lhs, rhs in
            // current as the primary photo is the stable priority for playback semantics; on failure, current as the
            // secondary photo is still tried.
            if lhs.currentIsPrimary != rhs.currentIsPrimary {
                return lhs.currentIsPrimary
            }
            if abs(lhs.score - rhs.score) > 0.000001 {
                return lhs.score > rhs.score
            }
            return lhs.order < rhs.order
        }
    }

    private nonisolated static func constructiveDoubleAttempts(
        candidates: [PlaybackSmartFillCandidateSummary],
        currentIsPrimary: Bool,
        surface: PlaybackSmartFillSurface,
        policy: PlaybackSmartFillLayoutPolicy,
        direction: ConstructiveDoubleDirection
    ) -> [ConstructiveDoubleAttempt] {
        guard candidates.count == 2,
            let primaryShare = solvedConstructivePrimaryShare(
                candidates: candidates,
                surface: surface,
                policy: policy,
                direction: direction
            )
        else {
            return []
        }

        let variants = constructiveDoubleVariants(
            primaryShare: primaryShare,
            policy: policy,
            direction: direction
        )
        return variants.enumerated().map { offset, variant in
            let ratioPreset = PlaybackSmartFillRatioPreset(
                id: constructiveRatioPresetId(
                    primaryShare: primaryShare,
                    variant: variant,
                    policy: policy
                ),
                primaryShare: primaryShare
            )
            let layout = LayoutCandidate(
                variant: variant,
                ratioPreset: ratioPreset,
                frames: PlaybackSmartFillLayoutCatalog.frames(for: variant, preset: ratioPreset)
            )
            return ConstructiveDoubleAttempt(
                candidates: candidates,
                layout: layout,
                score: estimatedLayoutCropRetentionScore(
                    layout: layout,
                    candidates: candidates,
                    surface: surface
                ),
                currentIsPrimary: currentIsPrimary,
                order: offset
            )
        }
    }

    private nonisolated static func constructiveDoubleVariants(
        primaryShare: Double,
        policy: PlaybackSmartFillLayoutPolicy,
        direction: ConstructiveDoubleDirection
    ) -> [PlaybackSmartFillLayoutVariant] {
        let equalTolerance = 0.0005
        let ordered: [PlaybackSmartFillLayoutVariant]
        switch direction {
        case .vertical:
            ordered =
                abs(primaryShare - 0.5) <= equalTolerance
                ? [.verticalEqual, .topPrimaryBottomSecondary, .bottomPrimaryTopSecondary]
                : [.topPrimaryBottomSecondary, .bottomPrimaryTopSecondary]
        case .horizontal:
            ordered =
                abs(primaryShare - 0.5) <= equalTolerance
                ? [.horizontalEqual, .leftPrimaryRightSecondary, .rightPrimaryLeftSecondary]
                : [.leftPrimaryRightSecondary, .rightPrimaryLeftSecondary]
        }
        // Variants come only from the policy allowlist, so constructive ratios cannot bypass the device's existing
        // layout boundaries.
        return ordered.filter { policy.layoutAllowlist.contains($0) }
    }

    private nonisolated static func solvedConstructivePrimaryShare(
        candidates: [PlaybackSmartFillCandidateSummary],
        surface: PlaybackSmartFillSurface,
        policy: PlaybackSmartFillLayoutPolicy,
        direction: ConstructiveDoubleDirection
    ) -> Double? {
        guard
            let interval = constructivePrimaryShareInterval(
                surface: surface,
                policy: policy,
                direction: direction
            )
        else {
            return nil
        }

        var lower = interval.lower
        var upper = interval.upper
        // Ternary search looks for the best point only inside the valid share interval; the goal is to maximize the
        // retention of the worse of the two slots.
        for _ in 0..<24 {
            let first = lower + (upper - lower) / 3
            let second = upper - (upper - lower) / 3
            if constructiveDoubleRetentionScore(
                candidates: candidates,
                surface: surface,
                direction: direction,
                primaryShare: first
            )
                < constructiveDoubleRetentionScore(
                    candidates: candidates,
                    surface: surface,
                    direction: direction,
                    primaryShare: second
                )
            {
                lower = first
            } else {
                upper = second
            }
        }

        let solved = (lower + upper) / 2
        let exactShares = constructiveExactShareHints(
            candidates: candidates,
            surface: surface,
            direction: direction
        )
        // An exact tiling point may fall within the ternary search's numeric error, so an explicit comparison avoids
        // missing the zero-crop boundary solution.
        let candidatesToCompare = ([interval.lower, interval.upper, solved, 0.5] + exactShares)
            .filter { $0.isFinite }
            .map { max(interval.lower, min(interval.upper, $0)) }

        return candidatesToCompare.max { lhs, rhs in
            constructiveDoubleRetentionScore(
                candidates: candidates,
                surface: surface,
                direction: direction,
                primaryShare: lhs
            )
                < constructiveDoubleRetentionScore(
                    candidates: candidates,
                    surface: surface,
                    direction: direction,
                    primaryShare: rhs
                )
        }
    }

    private nonisolated static func constructivePrimaryShareInterval(
        surface: PlaybackSmartFillSurface,
        policy: PlaybackSmartFillLayoutPolicy,
        direction: ConstructiveDoubleDirection
    ) -> (lower: Double, upper: Double)? {
        let surfaceAspect = surface.aspectRatio
        let aspectRange = policy.slotAspectRatioRange
        let aspectShareRange: (lower: Double, upper: Double)
        switch direction {
        case .vertical:
            // For a vertical stack, slot aspect = surfaceAspect / share, and both photos must fall within the general
            // photo aspect range.
            guard aspectRange.maximum > 0 else { return nil }
            aspectShareRange = (
                lower: surfaceAspect / aspectRange.maximum,
                upper: surfaceAspect / aspectRange.minimum
            )
        case .horizontal:
            // For a horizontal row, slot aspect = share * surfaceAspect, which likewise must constrain both the primary
            // and auxiliary slots.
            guard surfaceAspect > 0 else { return nil }
            aspectShareRange = (
                lower: aspectRange.minimum / surfaceAspect,
                upper: aspectRange.maximum / surfaceAspect
            )
        }

        let epsilon = 0.000001
        let lower = max(
            epsilon,
            aspectShareRange.lower,
            1 - aspectShareRange.upper
        )
        let upper = min(
            1 - epsilon,
            1 - policy.minimumSecondaryArea,
            aspectShareRange.upper,
            1 - aspectShareRange.lower
        )
        guard lower <= upper else { return nil }
        return (lower, upper)
    }

    private nonisolated static func constructiveExactShareHints(
        candidates: [PlaybackSmartFillCandidateSummary],
        surface: PlaybackSmartFillSurface,
        direction: ConstructiveDoubleDirection
    ) -> [Double] {
        guard candidates.count == 2 else { return [] }
        let surfaceAspect = surface.aspectRatio
        switch direction {
        case .vertical:
            return candidates.enumerated().compactMap { index, candidate in
                guard let aspect = candidate.aspectRatio,
                    aspect > 0
                else {
                    return nil
                }
                let share = surfaceAspect / aspect
                return index == 0 ? share : 1 - share
            }
        case .horizontal:
            return candidates.enumerated().compactMap { index, candidate in
                guard let aspect = candidate.aspectRatio,
                    surfaceAspect > 0
                else {
                    return nil
                }
                let share = aspect / surfaceAspect
                return index == 0 ? share : 1 - share
            }
        }
    }

    private nonisolated static func constructiveDoubleRetentionScore(
        candidates: [PlaybackSmartFillCandidateSummary],
        surface: PlaybackSmartFillSurface,
        direction: ConstructiveDoubleDirection,
        primaryShare: Double
    ) -> Double {
        guard candidates.count == 2,
            primaryShare > 0,
            primaryShare < 1
        else {
            return 0
        }

        let frames: [PlaybackPlanningRect]
        switch direction {
        case .vertical:
            frames = [
                PlaybackPlanningRect(x: 0, y: 0, width: 1, height: primaryShare),
                PlaybackPlanningRect(x: 0, y: primaryShare, width: 1, height: 1 - primaryShare)
            ]
        case .horizontal:
            frames = [
                PlaybackPlanningRect(x: 0, y: 0, width: primaryShare, height: 1),
                PlaybackPlanningRect(x: primaryShare, y: 0, width: 1 - primaryShare, height: 1)
            ]
        }

        return zip(candidates, frames)
            .map { candidate, frame in
                estimatedCropRetention(
                    candidate: candidate,
                    frame: frame,
                    surface: surface
                )
            }
            // Taking the minimum protects the photo that loses more, so an average does not hide one photo being
            // cropped too much.
            .min() ?? 0
    }

    private nonisolated static func constructiveRatioPresetId(
        primaryShare: Double,
        variant: PlaybackSmartFillLayoutVariant,
        policy: PlaybackSmartFillLayoutPolicy
    ) -> String {
        if let preset = policy.ratioPresets(for: variant).first(where: {
            abs($0.primaryShare - primaryShare) <= 0.0005
        }) {
            return preset.id
        }

        let primary = max(1, min(99, Int((primaryShare * 100).rounded())))
        return "constructive-\(primary)/\(100 - primary)"
    }

    private nonisolated static func auxiliaryCurrentAwareLayoutOrder(
        _ layouts: [LayoutCandidate],
        current: PlaybackSmartFillCandidateSummary,
        surface: PlaybackSmartFillSurface
    ) -> [LayoutCandidate] {
        layouts.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = estimatedAuxiliaryCurrentCropRetentionScore(
                    layout: lhs.element,
                    current: current,
                    surface: surface
                )
                let rhsScore = estimatedAuxiliaryCurrentCropRetentionScore(
                    layout: rhs.element,
                    current: current,
                    surface: surface
                )
                if abs(lhsScore - rhsScore) > 0.000001 {
                    return lhsScore > rhsScore
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private nonisolated static func auxiliaryCurrentSlotOrder(
        layout: LayoutCandidate,
        current: PlaybackSmartFillCandidateSummary,
        surface: PlaybackSmartFillSurface
    ) -> [Int] {
        Array(layout.frames.indices.dropFirst())
            .sorted { lhs, rhs in
                let lhsScore = estimatedCropRetention(
                    candidate: current,
                    frame: layout.frames[safe: lhs],
                    surface: surface
                )
                let rhsScore = estimatedCropRetention(
                    candidate: current,
                    frame: layout.frames[safe: rhs],
                    surface: surface
                )
                if abs(lhsScore - rhsScore) > 0.000001 {
                    return lhsScore > rhsScore
                }
                return lhs < rhs
            }
    }

    private nonisolated static func estimatedLayoutCropRetentionScore(
        layout: LayoutCandidate,
        candidates: [PlaybackSmartFillCandidateSummary],
        surface: PlaybackSmartFillSurface
    ) -> Double {
        guard layout.frames.count == candidates.count else { return 0 }
        return zip(candidates, layout.frames)
            .map { candidate, frame in
                estimatedCropRetention(
                    candidate: candidate,
                    frame: frame,
                    surface: surface
                )
            }
            .min() ?? 0
    }

    private nonisolated static func estimatedAuxiliaryCurrentCropRetentionScore(
        layout: LayoutCandidate,
        current: PlaybackSmartFillCandidateSummary,
        surface: PlaybackSmartFillSurface
    ) -> Double {
        layout.frames.indices.dropFirst()
            .map {
                estimatedCropRetention(
                    candidate: current,
                    frame: layout.frames[safe: $0],
                    surface: surface
                )
            }
            .max() ?? 0
    }

    private nonisolated static func estimatedCropRetention(
        candidate: PlaybackSmartFillCandidateSummary,
        frame: PlaybackPlanningRect?,
        surface: PlaybackSmartFillSurface
    ) -> Double {
        guard let frame,
            let imageAspect = candidate.aspectRatio,
            imageAspect > 0
        else {
            return 0
        }
        let slotAspect = slotAspectRatio(frame: frame, surface: surface)
        guard slotAspect > 0 else { return 0 }
        if imageAspect > slotAspect {
            return max(0, min(1, slotAspect / imageAspect))
        }
        return max(0, min(1, imageAspect / slotAspect))
    }

    private nonisolated static func protectedRects(
        for candidate: PlaybackSmartFillCandidateSummary,
        policy: PlaybackSmartFillLayoutPolicy
    ) -> [PlaybackPlanningRect] {
        protectedRectEntries(for: candidate, policy: policy).map(\.rect)
    }

    private nonisolated static func protectedRectEntries(
        for candidate: PlaybackSmartFillCandidateSummary,
        policy: PlaybackSmartFillLayoutPolicy
    ) -> [ProtectedRectEntry] {
        var entries = candidate.faceRects.map {
            ProtectedRectEntry(source: .face, rect: $0)
        }
        for subject in candidate.subjectRects where !entries.contains(where: { $0.rect == subject }) {
            entries.append(ProtectedRectEntry(source: .subject, rect: subject))
        }
        entries.append(
            contentsOf: candidate.faceRects.map {
                ProtectedRectEntry(
                    source: .upperBodyProxy,
                    rect: upperBodyProxy(from: $0, params: policy.upperBodyProxyParams)
                )
            })
        return entries
    }

    private nonisolated static func upperBodyProxy(
        from face: PlaybackPlanningRect,
        params: PlaybackSmartFillUpperBodyProxyParams
    ) -> PlaybackPlanningRect {
        let centerX = face.x + face.width / 2
        let width = face.width * params.horizontalFaceScale
        let left = centerX - width / 2
        let top = face.y - face.height * params.topFaceMargin
        let bottom = face.y + face.height + face.height * params.bottomFaceExtension
        return clamp(
            PlaybackPlanningRect(
                x: left,
                y: top,
                width: width,
                height: bottom - top
            )
        )
    }

    private nonisolated static func cropRect(
        for candidate: PlaybackSmartFillCandidateSummary,
        frame: PlaybackPlanningRect,
        surface: PlaybackSmartFillSurface,
        protectedRects: [PlaybackPlanningRect] = []
    ) -> PlaybackPlanningRect {
        let centered = centeredCropRect(for: candidate, frame: frame, surface: surface)
        guard !protectedRects.isEmpty else { return centered }
        return cropRectByContainingProtectedRects(centered, protectedRects: protectedRects)
    }

    private nonisolated static func centeredCropRect(
        for candidate: PlaybackSmartFillCandidateSummary,
        frame: PlaybackPlanningRect,
        surface: PlaybackSmartFillSurface
    ) -> PlaybackPlanningRect {
        guard let imageAspect = candidate.aspectRatio, imageAspect > 0 else {
            return .fullUnitRect
        }
        let slotAspect = slotAspectRatio(frame: frame, surface: surface)
        guard slotAspect > 0 else { return .fullUnitRect }

        if imageAspect > slotAspect {
            let cropWidth = max(0, min(1, slotAspect / imageAspect))
            return PlaybackPlanningRect(
                x: (1 - cropWidth) / 2,
                y: 0,
                width: cropWidth,
                height: 1
            )
        }

        let cropHeight = max(0, min(1, imageAspect / slotAspect))
        return PlaybackPlanningRect(
            x: 0,
            y: (1 - cropHeight) / 2,
            width: 1,
            height: cropHeight
        )
    }

    private nonisolated static func cropRectByContainingProtectedRects(
        _ crop: PlaybackPlanningRect,
        protectedRects: [PlaybackPlanningRect]
    ) -> PlaybackPlanningRect {
        let protectedMinX = protectedRects.map(\.x).min() ?? crop.x
        let protectedMaxX = protectedRects.map { $0.x + $0.width }.max() ?? (crop.x + crop.width)
        let protectedMinY = protectedRects.map(\.y).min() ?? crop.y
        let protectedMaxY = protectedRects.map { $0.y + $0.height }.max() ?? (crop.y + crop.height)

        return PlaybackPlanningRect(
            x: adjustedCropOrigin(
                currentOrigin: crop.x,
                cropLength: crop.width,
                protectedStart: protectedMinX,
                protectedEnd: protectedMaxX
            ),
            y: headroomBiasedCropOrigin(
                currentOrigin: crop.y,
                cropLength: crop.height,
                protectedStart: protectedMinY,
                protectedEnd: protectedMaxY
            ),
            width: crop.width,
            height: crop.height
        )
    }

    private nonisolated static func adjustedCropOrigin(
        currentOrigin: Double,
        cropLength: Double,
        protectedStart: Double,
        protectedEnd: Double
    ) -> Double {
        guard cropLength < 1 else { return 0 }
        guard protectedEnd - protectedStart <= cropLength else { return currentOrigin }

        let maxOrigin = max(0, 1 - cropLength)
        var origin = currentOrigin
        if protectedStart < origin {
            origin = protectedStart
        }
        if protectedEnd > origin + cropLength {
            origin = protectedEnd - cropLength
        }
        return max(0, min(maxOrigin, origin))
    }

    private nonisolated static func headroomBiasedCropOrigin(
        currentOrigin: Double,
        cropLength: Double,
        protectedStart: Double,
        protectedEnd: Double
    ) -> Double {
        guard cropLength < 1 else { return 0 }
        guard protectedEnd - protectedStart <= cropLength else {
            return currentOrigin
        }

        let maxOrigin = max(0, 1 - cropLength)
        let earliestOriginKeepingProtectedEnd = max(0, protectedEnd - cropLength)
        let latestOriginKeepingProtectedStart = min(maxOrigin, protectedStart)
        guard earliestOriginKeepingProtectedEnd <= latestOriginKeepingProtectedStart else {
            return adjustedCropOrigin(
                currentOrigin: currentOrigin,
                cropLength: cropLength,
                protectedStart: protectedStart,
                protectedEnd: protectedEnd
            )
        }
        return max(0, min(maxOrigin, earliestOriginKeepingProtectedEnd))
    }

    private nonisolated static func protectionSummary(
        candidates: [PlaybackSmartFillCandidateSummary],
        frames: [PlaybackPlanningRect],
        surface: PlaybackSmartFillSurface,
        protectionSnapshot: PlaybackProtectionSnapshot,
        policy: PlaybackSmartFillLayoutPolicy
    ) -> PlaybackSmartFillProtectionSummary {
        guard !protectionSnapshot.regions.isEmpty else {
            return PlaybackSmartFillProtectionSummary(
                status: .accepted,
                checkedRegionCount: 0,
                overlappingRegionCount: 0
            )
        }

        var totalOverlapCount = 0
        var hardOverlapCount = 0
        var softOverlayOverlapWarningCount = 0
        var controlBarSubjectOverlapWarningCount = 0
        var exifOverlayOverlapWarningCount = 0
        var controlBarHardRejected = false
        var exifOverlayHardRejected = false
        var overlapDetails: [PlaybackSmartFillProtectionOverlapDetail] = []
        for (candidate, frame) in zip(candidates, frames) {
            let protected = protectedRectEntries(for: candidate, policy: policy)
            let crop = cropRect(for: candidate, frame: frame, surface: surface, protectedRects: protected.map(\.rect))
            for subject in protected {
                let mappedSubject = mapSourceRect(subject.rect, crop: crop, into: frame)
                for region in protectionSnapshot.regions where mappedSubject.intersects(region.rect.planningRect) {
                    totalOverlapCount += 1
                    let isRealProtectedSource = subject.source != .upperBodyProxy
                    let isSystemSafeAreaSoftWarning =
                        region.priority == .hard
                        && isRealProtectedSource
                        && region.source == .systemSafeArea
                        && surface.profile != .iPhone
                    // On iPad/TV, systemSafeArea is a suggested boundary; faces must be fully inside the crop, but
                    // merely touching it must not cause a fallback.

                    let hardRejected =
                        region.priority == .hard
                        && isRealProtectedSource
                        && !isSystemSafeAreaSoftWarning
                    overlapDetails.append(
                        PlaybackSmartFillProtectionOverlapDetail(
                            protectedSource: subject.source,
                            regionSource: region.source,
                            regionPriority: region.priority,
                            cropRect: crop,
                            mappedRect: mappedSubject,
                            hardRejected: hardRejected,
                            systemSafeAreaSoftWarning: isSystemSafeAreaSoftWarning
                        )
                    )
                    if hardRejected {
                        hardOverlapCount += 1
                        if region.source == .controlBar {
                            controlBarHardRejected = true
                        }
                        if region.source == .exifPanel {
                            exifOverlayHardRejected = true
                        }
                    } else {
                        // Soft overlays and upper-body proxies only record risk; only a face/real subject intersecting
                        // a hard region is a hard reject.

                        softOverlayOverlapWarningCount += 1
                        if region.source == .controlBar {
                            controlBarSubjectOverlapWarningCount += 1
                        }
                        if region.source == .exifPanel {
                            exifOverlayOverlapWarningCount += 1
                        }
                    }
                }
            }
        }

        return PlaybackSmartFillProtectionSummary(
            status: hardOverlapCount > 0 ? .rejected : .accepted,
            checkedRegionCount: protectionSnapshot.regions.count,
            overlappingRegionCount: totalOverlapCount,
            hardOverlapCount: hardOverlapCount,
            softOverlayOverlapWarningCount: softOverlayOverlapWarningCount,
            controlBarSubjectOverlapWarningCount: controlBarSubjectOverlapWarningCount,
            exifOverlayOverlapWarningCount: exifOverlayOverlapWarningCount,
            controlBarHardRejected: controlBarHardRejected,
            exifOverlayHardRejected: exifOverlayHardRejected,
            overlapDetails: overlapDetails
        )
    }

    private nonisolated static func effectivePixelsTooLow(
        candidate: PlaybackSmartFillCandidateSummary,
        frame: PlaybackPlanningRect,
        surface: PlaybackSmartFillSurface,
        policy: PlaybackSmartFillLayoutPolicy,
        crop: PlaybackPlanningRect
    ) -> Bool {
        guard let pixelSize = candidate.pixelSize else { return false }
        let sourceCropWidth = Double(pixelSize.width) * crop.width
        let sourceCropHeight = Double(pixelSize.height) * crop.height
        let displayWidth = Double(surface.pixelSize.width) * frame.width
        let displayHeight = Double(surface.pixelSize.height) * frame.height
        let minimumDisplayWidth = displayWidth * policy.minimumEffectivePixelScale
        let minimumDisplayHeight = displayHeight * policy.minimumEffectivePixelScale
        return sourceCropWidth < minimumDisplayWidth || sourceCropHeight < minimumDisplayHeight
    }

    private nonisolated static func mapSourceRect(
        _ rect: PlaybackPlanningRect,
        crop: PlaybackPlanningRect,
        into frame: PlaybackPlanningRect
    ) -> PlaybackPlanningRect {
        let cropWidth = max(crop.width, .leastNonzeroMagnitude)
        let cropHeight = max(crop.height, .leastNonzeroMagnitude)
        return PlaybackPlanningRect(
            x: frame.x + ((rect.x - crop.x) / cropWidth) * frame.width,
            y: frame.y + ((rect.y - crop.y) / cropHeight) * frame.height,
            width: (rect.width / cropWidth) * frame.width,
            height: (rect.height / cropHeight) * frame.height
        )
    }

    private nonisolated static func readabilitySummary(
        policy: PlaybackSmartFillLayoutPolicy,
        frames: [PlaybackPlanningRect]
    ) -> PlaybackSmartFillReadabilitySummary {
        let smallest = frames.map(area).min()
        return PlaybackSmartFillReadabilitySummary(
            minimumSecondaryArea: policy.minimumSecondaryArea,
            smallestSecondaryArea: smallest,
            accepted: smallest.map { $0 >= policy.minimumSecondaryArea } ?? true
        )
    }

    private nonisolated static func appendStaticPolicyRejects(
        _ policy: PlaybackSmartFillLayoutPolicy,
        into state: inout PlannerState
    ) {
        if !policy.allowsHorizontalDouble {
            state.record(.horizontalDoubleDisallowedOnSurface)
        }
        if !policy.allowsVerticalDouble {
            state.record(.verticalDoubleDisallowedOnSurface)
        }
        if !policy.allowsTriple {
            state.record(.tripleDisallowedOnSurface)
        }
    }

    private nonisolated static func rotationInfo(
        input: PlaybackSmartFillPlannerInput,
        primary: PlaybackSmartFillCandidateSummary,
        sceneType: PlaybackSmartFillSceneType
    ) -> RotationInfo {
        let key = [
            input.playbackSessionSeed,
            primary.reference,
            input.policy.surfacePolicyId,
            String(input.sceneOrdinal),
            sceneType.rawValue
        ].joined(separator: "|")
        let hash = stableHash64(key)
        let layouts = layoutCandidates(for: sceneType, policy: input.policy)
        let startIndex = layouts.isEmpty ? 0 : Int(hash % UInt64(layouts.count))
        let startLayout = layouts[safe: startIndex]
        return RotationInfo(
            startIndex: startIndex,
            startVariant: startLayout?.variant ?? .single,
            startRatioPreset: startLayout?.ratioPreset.id ?? (sceneType == .fallback ? "fallback" : "full"),
            hashPrefix: String(format: "%016llx", hash).prefix(12).description
        )
    }

    private nonisolated static func stableHash64(_ text: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }

    private nonisolated static func rotated<T>(_ values: [T], by startIndex: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        let start = startIndex % values.count
        return Array(values[start...]) + Array(values[..<start])
    }

    private nonisolated static func combinations(
        from candidates: [PlaybackSmartFillCandidateSummary],
        count: Int,
        requiringIndexAtLeast minimumIndex: Int? = nil
    ) -> [[PlaybackSmartFillCandidateSummary]] {
        // minimumIndex dedupes window expansion: each returned combination has at least one new-window candidate.
        guard count > 0 else { return [[]] }
        guard candidates.count >= count else { return [] }
        if count == 1 {
            return candidates.enumerated().compactMap { offset, candidate in
                if let minimumIndex, offset < minimumIndex {
                    return nil
                }
                return [candidate]
            }
        }

        var result: [[PlaybackSmartFillCandidateSummary]] = []
        for first in 0..<(candidates.count - 1) {
            for second in (first + 1)..<candidates.count {
                if let minimumIndex,
                    first < minimumIndex,
                    second < minimumIndex
                {
                    continue
                }
                result.append([candidates[first], candidates[second]])
            }
        }
        return result
    }

    private nonisolated static func makeReasonCodes(
        sceneType: PlaybackSmartFillSceneType,
        layoutPolicyId: String,
        surfaceKey: String,
        layoutVariant: PlaybackSmartFillLayoutVariant,
        ratioPreset: String,
        candidateWindowUsed: Int,
        rejectReasons: [PlaybackSmartFillPlannerRejectReason],
        fallbackReason: PlaybackSmartFillFallbackReason?,
        fallbackCategory: PlaybackSmartFillFallbackCategory
    ) -> [String] {
        var codes = [
            "scene:\(sceneType.rawValue)",
            "policy:\(layoutPolicyId)",
            "surface:\(surfaceKey)",
            "layout:\(layoutVariant.rawValue)",
            "ratio:\(ratioPreset)",
            "candidateWindow:\(candidateWindowUsed)",
            "fallbackCategory:\(fallbackCategory.rawValue)"
        ]
        if let fallbackReason {
            codes.append("fallback:\(fallbackReason.rawValue)")
        }
        codes.append(contentsOf: rejectReasons.map { "reject:\($0.rawValue)" })
        return codes
    }

    private nonisolated static func qaSummary(
        input: PlaybackSmartFillPlannerInput,
        sceneType: PlaybackSmartFillSceneType,
        layout: LayoutCandidate,
        slots: [PlaybackSmartFillSlot],
        protectionSummary: PlaybackSmartFillProtectionSummary,
        fallbackReason: PlaybackSmartFillFallbackReason?,
        fallbackCategory: PlaybackSmartFillFallbackCategory,
        candidateWindowUsed: Int,
        evaluationCount: Int,
        rotation: RotationInfo,
        rejectReasons: [PlaybackSmartFillPlannerRejectReason],
        rejectedLayoutReasonTopList: [PlaybackSmartFillPlannerRejectReason],
        rejectedLayoutDiagnostics: [String],
        currentEvidence: CurrentAssetEvidence
    ) -> String {
        let photoCanvas = PlaybackSmartFillPhotoCanvasDescriptor(surface: input.surface)
        let geometry = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: layout.frames,
            photoCanvas: photoCanvas
        )
        return [
            "version=smart-fill-planner-v2",
            "sceneType=\(sceneType.rawValue)",
            "surfaceKey=\(input.surface.surfaceKey)",
            "surfaceFingerprint=\(photoCanvas.surfaceFingerprint)",
            "policy=\(input.policy.layoutPolicyId)",
            "layoutVariant=\(layout.variant.rawValue)",
            "ratioPreset=\(layout.ratioPreset.id)",
            "photoCanvasId=\(photoCanvas.canvasId)",
            "photoCanvasPointSize=\(format(photoCanvas.pointSize.width))x\(format(photoCanvas.pointSize.height))",
            "photoCanvasPixelSize=\(photoCanvas.pixelSize.width)x\(photoCanvas.pixelSize.height)",
            "canvasCoverage=\(format(geometry.coverageRatio))",
            "emptyCanvasRatio=\(format(geometry.emptyCanvasRatio))",
            "maxContinuousEmptyAxisRatio=\(format(geometry.maxContinuousEmptyAxisRatio))",
            "gapPixelCount=\(geometry.gapPixelCount)",
            "overlapPixelCount=\(geometry.overlapPixelCount)",
            "slotCount=\(slots.count)",
            "slotRoles=\(slots.map(\.role.rawValue).joined(separator: ",").nilIfEmpty ?? "none")",
            "slotRefs=\(slots.map(\.candidateReference).joined(separator: ",").nilIfEmpty ?? "none")",
            "currentAssetDisposition=\(currentEvidence.disposition.rawValue)",
            "currentAssetAbsentReason=\(currentEvidence.absentReason.rawValue)",
            "currentAssetSlotAreaRatio=\(formatOptional(currentEvidence.slotAreaRatio))",
            "currentAssetCropRetention=\(formatOptional(currentEvidence.cropRetention))",
            "currentAssetProtectedRegionCoverage=\(formatOptional(currentEvidence.protectedRegionCoverage))",
            "currentAssetFaceProtectionPassed=\(currentEvidence.faceProtectionPassed ? "true" : "false")",
            "currentAssetSubjectProtectionPassed=\(currentEvidence.subjectProtectionPassed ? "true" : "false")",
            "currentAssetVisibleQualityClass=\(currentEvidence.visibleQuality.rawValue)",
            "cropRetentionThresholdUsed=\(format(input.policy.cropRetentionThreshold))",
            "ledgerSceneAssets=\(currentEvidence.ledgerSceneAssets.joined(separator: ",").nilIfEmpty ?? "none")",
            "acceptedSceneSearchTier=\(PlaybackSmartFillAcceptedSceneSearchTier(sceneType: sceneType).rawValue)",
            "candidateWindowRequested=\(input.policy.candidateWindowPresets.last ?? candidateWindowUsed)",
            "candidateWindowExpansionTrace=\(candidateWindowUsed):\(fallbackReason == nil ? "accepted" : "fallback")",
            "slotFrames=\(slots.map(\.frameInScene.smartFillPlannerLabel).joined(separator: ",").nilIfEmpty ?? "none")",
            "slotCropRects=\(slots.map(\.cropRectInSource.smartFillPlannerLabel).joined(separator: ",").nilIfEmpty ?? "none")",
            "cropRetention=\(slots.map { format($0.cropRetention) }.joined(separator: ",").nilIfEmpty ?? "none")",
            "protectionContained=\(slots.map { $0.protectionContained ? "true" : "false" }.joined(separator: ",").nilIfEmpty ?? "none")",
            "protectionStatus=\(protectionSummary.status.rawValue)",
            "protectionHardOverlapCount=\(protectionSummary.hardOverlapCount)",
            "softOverlayOverlapWarningCount=\(protectionSummary.softOverlayOverlapWarningCount)",
            "controlBarSubjectOverlapWarningCount=\(protectionSummary.controlBarSubjectOverlapWarningCount)",
            "controlBarHardRejected=\(protectionSummary.controlBarHardRejected ? "true" : "false")",
            "exifOverlayOverlapWarningCount=\(protectionSummary.exifOverlayOverlapWarningCount)",
            "exifOverlayHardRejected=\(protectionSummary.exifOverlayHardRejected ? "true" : "false")",
            "protectionOverlapDetails=\(protectionSummary.overlapDetails.map(protectionOverlapDetailLabel).joined(separator: ",").nilIfEmpty ?? "none")",
            "fallbackCategory=\(fallbackCategory.rawValue)",
            "candidateWindowUsed=\(candidateWindowUsed)",
            "evaluationCount=\(evaluationCount)",
            "rotationStartLayoutVariant=\(rotation.startVariant.rawValue)",
            "rotationStartRatioPreset=\(rotation.startRatioPreset)",
            "acceptedLayoutVariant=\(layout.variant.rawValue)",
            "acceptedRatioPreset=\(layout.ratioPreset.id)",
            "rotationKeyHashPrefix=\(rotation.hashPrefix)",
            "fallback=\(fallbackReason?.rawValue ?? "none")",
            "rejects=\(rejectReasons.map(\.rawValue).joined(separator: ",").nilIfEmpty ?? "none")",
            "rejectedLayoutReasonTopList=\(rejectedLayoutReasonTopList.map(\.rawValue).joined(separator: ",").nilIfEmpty ?? "none")",
            "rejectedLayoutDiagnostics=\(rejectedLayoutDiagnostics.joined(separator: ",").nilIfEmpty ?? "none")"
        ].joined(separator: ";")
    }

    private nonisolated static func protectionOverlapDetailLabel(
        _ detail: PlaybackSmartFillProtectionOverlapDetail
    ) -> String {
        [
            "source:\(detail.protectedSource.rawValue)",
            "region:\(detail.regionSource.rawValue)",
            "priority:\(detail.regionPriority.rawValue)",
            "crop:\(detail.cropRect.smartFillPlannerLabel)",
            "mapped:\(detail.mappedRect.smartFillPlannerLabel)",
            "hardRejected:\(detail.hardRejected ? "true" : "false")",
            "systemSafeAreaSoftWarning:\(detail.systemSafeAreaSoftWarning ? "true" : "false")"
        ].joined(separator: "|")
    }

    private nonisolated static func role(for index: Int) -> PlaybackSmartFillSlotRole {
        switch index {
        case 0:
            return .primary
        case 1:
            return .secondary
        default:
            return .tertiary
        }
    }

    // An intermediate model before the manifest is emitted; named fields keep an 11-field tuple from getting misaligned
    // during later maintenance.
    private struct CurrentAssetEvidence {
        let disposition: PlaybackSmartFillCurrentAssetDisposition
        let absentReason: PlaybackSmartFillCurrentAssetAbsentReason
        let slotAreaRatio: Double?
        let cropRetention: Double?
        let protectedRegionCoverage: Double?
        let faceProtectionPassed: Bool
        let subjectProtectionPassed: Bool
        let visibleQuality: PlaybackSmartFillVisibleQualityClass
        let ledgerSceneAssets: [String]
        let slotRoles: [PlaybackSmartFillSlotRole]
        let slotRefs: [String]
    }

    private nonisolated static func currentAssetEvidence(
        input: PlaybackSmartFillPlannerInput,
        sceneType: PlaybackSmartFillSceneType,
        slots: [PlaybackSmartFillSlot]
    ) -> CurrentAssetEvidence {
        let ledgerSceneAssets = slots.map(\.candidateReference)
        let slotRoles = slots.map(\.role)
        let slotRefs = slots.map(\.candidateReference)
        guard let currentReference = input.candidates.first?.reference else {
            return CurrentAssetEvidence(
                disposition: .absentHardFail,
                absentReason: .missingMetadata,
                slotAreaRatio: nil,
                cropRetention: nil,
                protectedRegionCoverage: nil,
                faceProtectionPassed: false,
                subjectProtectionPassed: false,
                visibleQuality: .fail,
                ledgerSceneAssets: ledgerSceneAssets,
                slotRoles: slotRoles,
                slotRefs: slotRefs
            )
        }

        guard let slot = slots.first(where: { $0.candidateReference == currentReference }) else {
            return CurrentAssetEvidence(
                disposition: .absentHardFail,
                absentReason: .noLegalLayout,
                slotAreaRatio: nil,
                cropRetention: nil,
                protectedRegionCoverage: nil,
                faceProtectionPassed: false,
                subjectProtectionPassed: false,
                visibleQuality: .fail,
                ledgerSceneAssets: ledgerSceneAssets,
                slotRoles: slotRoles,
                slotRefs: slotRefs
            )
        }

        let disposition: PlaybackSmartFillCurrentAssetDisposition
        switch sceneType {
        case .single:
            disposition = .singleSlot
        case .fallback:
            disposition = .fallbackCurrent
        case .double, .triple:
            switch slot.role {
            case .primary:
                disposition = .primarySlot
            case .secondary:
                disposition = .secondarySlot
            case .tertiary:
                disposition = .tertiarySlot
            }
        }

        let visibleQuality: PlaybackSmartFillVisibleQualityClass
        if sceneType == .fallback {
            visibleQuality = .fail
        } else if sceneType == .single {
            visibleQuality =
                slot.cropRetention >= input.policy.cropRetentionThreshold && slot.protectionContained
                ? .acceptable : .fail
        } else if slot.cropRetention >= input.policy.cropRetentionThreshold && slot.protectionContained {
            visibleQuality = .acceptable
        } else {
            visibleQuality = .fail
        }

        return CurrentAssetEvidence(
            disposition: disposition,
            absentReason: .none,
            slotAreaRatio: area(of: slot.frameInScene),
            cropRetention: slot.cropRetention,
            protectedRegionCoverage: slot.protectionContained ? 1 : 0,
            faceProtectionPassed: slot.protectionContained,
            subjectProtectionPassed: slot.protectionContained,
            visibleQuality: visibleQuality,
            ledgerSceneAssets: ledgerSceneAssets,
            slotRoles: slotRoles,
            slotRefs: slotRefs
        )
    }

    private nonisolated static func area(of rect: PlaybackPlanningRect) -> Double {
        rect.width * rect.height
    }

    private nonisolated static func slotAspectRatio(
        frame: PlaybackPlanningRect,
        surface: PlaybackSmartFillSurface
    ) -> Double {
        guard frame.height > 0 else { return 1 }
        return surface.aspectRatio * frame.width / frame.height
    }

    private nonisolated static func clamp(_ rect: PlaybackPlanningRect) -> PlaybackPlanningRect {
        let x = max(0, min(1, rect.x))
        let y = max(0, min(1, rect.y))
        let maxX = max(0, min(1, rect.x + rect.width))
        let maxY = max(0, min(1, rect.y + rect.height))
        return PlaybackPlanningRect(
            x: x,
            y: y,
            width: max(0, maxX - x),
            height: max(0, maxY - y)
        )
    }

    private nonisolated static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private nonisolated static func formatOptional(_ value: Double?) -> String {
        guard let value else { return "none" }
        return format(value)
    }

    private struct LayoutCandidate: Equatable, Sendable {
        let variant: PlaybackSmartFillLayoutVariant
        let ratioPreset: PlaybackSmartFillRatioPreset
        let frames: [PlaybackPlanningRect]

        nonisolated init(
            variant: PlaybackSmartFillLayoutVariant,
            ratioPreset: PlaybackSmartFillRatioPreset,
            frames: [PlaybackPlanningRect]
        ) {
            self.variant = variant
            self.ratioPreset = ratioPreset
            self.frames = frames
        }
    }

    private struct LayoutEvaluation: Sendable {
        let slots: [PlaybackSmartFillSlot]
        let protectionSummary: PlaybackSmartFillProtectionSummary

        nonisolated init(
            slots: [PlaybackSmartFillSlot],
            protectionSummary: PlaybackSmartFillProtectionSummary
        ) {
            self.slots = slots
            self.protectionSummary = protectionSummary
        }
    }

    private struct ProtectedRectEntry: Equatable, Sendable {
        let source: PlaybackSmartFillProtectedRectSource
        let rect: PlaybackPlanningRect

        nonisolated init(
            source: PlaybackSmartFillProtectedRectSource,
            rect: PlaybackPlanningRect
        ) {
            self.source = source
            self.rect = rect
        }
    }

    private struct RotationInfo: Sendable {
        let startIndex: Int
        let startVariant: PlaybackSmartFillLayoutVariant
        let startRatioPreset: String
        let hashPrefix: String

        nonisolated init(
            startIndex: Int,
            startVariant: PlaybackSmartFillLayoutVariant,
            startRatioPreset: String,
            hashPrefix: String
        ) {
            self.startIndex = startIndex
            self.startVariant = startVariant
            self.startRatioPreset = startRatioPreset
            self.hashPrefix = hashPrefix
        }
    }

    private enum ConstructiveDoubleDirection: Sendable {
        case vertical
        case horizontal
    }

    private struct ConstructiveDoubleAttempt: Sendable {
        let candidates: [PlaybackSmartFillCandidateSummary]
        let layout: LayoutCandidate
        let score: Double
        let currentIsPrimary: Bool
        let order: Int

        nonisolated init(
            candidates: [PlaybackSmartFillCandidateSummary],
            layout: LayoutCandidate,
            score: Double,
            currentIsPrimary: Bool,
            order: Int
        ) {
            self.candidates = candidates
            self.layout = layout
            self.score = score
            self.currentIsPrimary = currentIsPrimary
            self.order = order
        }
    }

    private struct PlannerState: Sendable {
        var rejectReasons: [PlaybackSmartFillPlannerRejectReason] = []
        var rejectCounts: [PlaybackSmartFillPlannerRejectReason: Int] = [:]
        var rejectedLayoutDiagnostics: [String] = []
        var rejectedLayoutDiagnosticBucketCounts: [String: Int] = [:]
        var evaluationCount: Int = 0
        var candidateWindowUsed: Int = 1
        var isEvaluationBudgetExhausted = false

        nonisolated init() {}

        nonisolated mutating func record(_ reason: PlaybackSmartFillPlannerRejectReason) {
            rejectCounts[reason, default: 0] += 1
            guard !rejectReasons.contains(reason) else { return }
            rejectReasons.append(reason)
        }

        nonisolated mutating func reserveEvaluation(policy: PlaybackSmartFillLayoutPolicy) -> Bool {
            guard evaluationCount < policy.evaluationBudget else {
                isEvaluationBudgetExhausted = true
                record(.candidateWindowExhausted)
                return false
            }
            evaluationCount += 1
            return true
        }

        nonisolated func topRejectedReasons(limit: Int = 5) -> [PlaybackSmartFillPlannerRejectReason] {
            rejectCounts
                .sorted { left, right in
                    if left.value == right.value {
                        return left.key.rawValue < right.key.rawValue
                    }
                    return left.value > right.value
                }
                .prefix(limit)
                .map(\.key)
        }

        nonisolated mutating func recordRejectedLayoutDiagnostic(
            reason: PlaybackSmartFillPlannerRejectReason,
            candidate: PlaybackSmartFillCandidateSummary,
            layout: LayoutCandidate,
            slotIndex: Int,
            frame: PlaybackPlanningRect,
            surface: PlaybackSmartFillSurface,
            policy: PlaybackSmartFillLayoutPolicy,
            cropRetention: Double? = nil
        ) {
            guard rejectedLayoutDiagnostics.count < 36 else { return }

            let role = PlaybackSmartFillPlanner.role(for: slotIndex)
            let bucket = [
                reason.rawValue,
                layout.variant.rawValue,
                role.rawValue,
                String(slotIndex)
            ].joined(separator: "|")
            guard rejectedLayoutDiagnosticBucketCounts[bucket, default: 0] < 3 else { return }
            rejectedLayoutDiagnosticBucketCounts[bucket, default: 0] += 1

            let slotAspect = PlaybackSmartFillPlanner.slotAspectRatio(frame: frame, surface: surface)
            let protected = PlaybackSmartFillPlanner.protectedRects(for: candidate, policy: policy)
            let crop = PlaybackSmartFillPlanner.cropRect(
                for: candidate,
                frame: frame,
                surface: surface,
                protectedRects: protected
            )
            let resolvedCropRetention = cropRetention ?? crop.width * crop.height
            let thresholdDelta = resolvedCropRetention - policy.cropRetentionThreshold
            let imageAspect = candidate.aspectRatio.map(PlaybackSmartFillPlanner.format) ?? "missing"
            let secondaryArea = PlaybackSmartFillPlanner.area(of: frame)

            rejectedLayoutDiagnostics.append(
                [
                    "reason:\(reason.rawValue)",
                    "layout:\(layout.variant.rawValue)",
                    "ratio:\(layout.ratioPreset.id)",
                    "role:\(role.rawValue)",
                    "slotIndex:\(slotIndex)",
                    "imageAspect:\(imageAspect)",
                    "slotAspect:\(PlaybackSmartFillPlanner.format(slotAspect))",
                    "cropRetention:\(PlaybackSmartFillPlanner.format(resolvedCropRetention))",
                    "threshold:\(PlaybackSmartFillPlanner.format(policy.cropRetentionThreshold))",
                    "thresholdDelta:\(PlaybackSmartFillPlanner.format(thresholdDelta))",
                    "secondaryArea:\(PlaybackSmartFillPlanner.format(secondaryArea))",
                    "minimumSecondaryArea:\(PlaybackSmartFillPlanner.format(policy.minimumSecondaryArea))"
                ].joined(separator: "|"))
        }
    }
}

private extension PlaybackPlanningRect {
    nonisolated func contains(_ other: PlaybackPlanningRect, margin: Double) -> Bool {
        other.x >= x + margin && other.y >= y + margin && other.x + other.width <= x + width - margin
            && other.y + other.height <= y + height - margin
    }

    nonisolated func intersects(_ other: PlaybackPlanningRect) -> Bool {
        x < other.x + other.width && x + width > other.x && y < other.y + other.height && y + height > other.y
    }

    nonisolated var smartFillPlannerLabel: String {
        "x\(formatted(x))y\(formatted(y))w\(formatted(width))h\(formatted(height))"
    }

    private nonisolated func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private extension PlaybackProtectionRect {
    nonisolated var planningRect: PlaybackPlanningRect {
        PlaybackPlanningRect(x: x, y: y, width: width, height: height)
    }
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
