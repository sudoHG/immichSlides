import Foundation

extension PlaybackSmartFillPlanner {
    nonisolated static func layoutCandidates(
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

    nonisolated static func aspectAwareLayoutOrder(
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
                if abs(lhsScore - rhsScore) > comparisonTolerance {
                    return lhsScore > rhsScore
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    nonisolated static func constructiveDoubleDirections(
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
                return policy.canUseVerticalDouble
            case .horizontal:
                return policy.canUseHorizontalDouble
            }
        }
    }

    nonisolated static func constructivePartnerOrder(
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
                if abs(lhsDistance - rhsDistance) > comparisonTolerance {
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

    nonisolated static func constructiveDoubleAttempts(
        current: PlaybackSmartFillCandidateSummary,
        partner: PlaybackSmartFillCandidateSummary,
        surface: PlaybackSmartFillSurface,
        policy: PlaybackSmartFillLayoutPolicy,
        direction: ConstructiveDoubleDirection
    ) -> [ConstructiveDoubleAttempt] {
        [
            constructiveDoubleAttempts(
                candidates: [current, partner],
                isCurrentPrimary: true,
                surface: surface,
                policy: policy,
                direction: direction
            ),
            constructiveDoubleAttempts(
                candidates: [partner, current],
                isCurrentPrimary: false,
                surface: surface,
                policy: policy,
                direction: direction
            )
        ]
        .flatMap { $0 }
        .sorted { lhs, rhs in
            // current as the primary photo is the stable priority for playback semantics; on failure, current as the
            // secondary photo is still tried.
            if lhs.isCurrentPrimary != rhs.isCurrentPrimary {
                return lhs.isCurrentPrimary
            }
            if abs(lhs.score - rhs.score) > comparisonTolerance {
                return lhs.score > rhs.score
            }
            return lhs.order < rhs.order
        }
    }

    nonisolated static func constructiveDoubleAttempts(
        candidates: [PlaybackSmartFillCandidateSummary],
        isCurrentPrimary: Bool,
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
                isCurrentPrimary: isCurrentPrimary,
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
        for _ in 0..<constructiveSearchIterationLimit {
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
            abs($0.primaryShare - primaryShare) <= ratioPresetMatchingTolerance
        }) {
            return preset.id
        }

        let primary = max(1, min(99, Int((primaryShare * 100).rounded())))
        return "constructive-\(primary)/\(100 - primary)"
    }

    nonisolated static func auxiliaryCurrentAwareLayoutOrder(
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
                if abs(lhsScore - rhsScore) > comparisonTolerance {
                    return lhsScore > rhsScore
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    nonisolated static func auxiliaryCurrentSlotOrder(
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
                if abs(lhsScore - rhsScore) > comparisonTolerance {
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

    nonisolated static func protectedRects(
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

    nonisolated static func upperBodyProxy(
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

    nonisolated static func cropRect(
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

    nonisolated static func protectionSummary(
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

    nonisolated static func effectivePixelsTooLow(
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

    nonisolated static func readabilitySummary(
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
}
