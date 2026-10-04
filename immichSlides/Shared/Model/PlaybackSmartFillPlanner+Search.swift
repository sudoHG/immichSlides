import Foundation

extension PlaybackSmartFillPlanner {
    nonisolated static func makeSingleResult(
        input: PlaybackSmartFillPlannerInput,
        state: inout PlannerState
    ) -> PlaybackSmartFillPlannerResult? {
        let layout = LayoutCandidate(
            variant: .single,
            ratioPreset: PlaybackSmartFillRatioPreset(id: "full", primaryShare: 1),
            frames: [.fullUnitRect]
        )

        if !input.policy.canUseSingleCandidateLookahead {
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

    nonisolated static func makeMultiSlotResult(
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
            input.policy.canUseCurrentCandidateAsAuxiliaryLookahead ? input.policy.currentAuxiliaryEvaluationReserve : 0
        let primaryPhaseEvaluationLimit = max(0, input.policy.evaluationBudget - auxiliaryEvaluationReserve)
        var didStopPrimaryPhaseForAuxiliaryBudget = false

        primarySearch: for window in input.policy.candidateWindowPresets {
            guard !state.isEvaluationBudgetExhausted else { return nil }
            // Once the primary phase budget is reached, yield early to the auxiliary lookahead so an acceptable triple
            // is not starved.
            if auxiliaryEvaluationReserve > 0,
                state.evaluationCount >= primaryPhaseEvaluationLimit
            {
                didStopPrimaryPhaseForAuxiliaryBudget = true
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
                    didStopPrimaryPhaseForAuxiliaryBudget = true
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
                        didStopPrimaryPhaseForAuxiliaryBudget = true
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
                            didStopPrimaryPhaseForAuxiliaryBudget = true
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

        if (input.policy.canUseCurrentCandidateAsAuxiliaryLookahead || didStopPrimaryPhaseForAuxiliaryBudget),
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
                    let hasAlreadyTried: Bool
                    switch direction {
                    case .vertical:
                        hasAlreadyTried = triedVerticalPartnerReferences.contains(partner.reference)
                    case .horizontal:
                        hasAlreadyTried = triedHorizontalPartnerReferences.contains(partner.reference)
                    }
                    guard !hasAlreadyTried else { continue }
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
}
