import Foundation

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension PlaybackSmartFillPlanner {
    nonisolated static func appendStaticPolicyRejects(
        _ policy: PlaybackSmartFillLayoutPolicy,
        into state: inout PlannerState
    ) {
        if !policy.canUseHorizontalDouble {
            state.record(.horizontalDoubleDisallowedOnSurface)
        }
        if !policy.canUseVerticalDouble {
            state.record(.verticalDoubleDisallowedOnSurface)
        }
        if !policy.canUseTriple {
            state.record(.tripleDisallowedOnSurface)
        }
    }

    nonisolated static func rotationInfo(
        input: PlaybackSmartFillPlannerInput,
        primary: PlaybackSmartFillCandidateSummary,
        sceneType: PlaybackSmartFillSceneType
    ) -> RotationInfo {
        let key = [
            input.playbackSessionSeed,
            primary.reference,
            input.policy.layoutPolicyId,
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
            hashPrefix: String(format: "%016llx", hash).prefix(rotationHashPrefixCharacterCount).description
        )
    }

    private nonisolated static func stableHash64(_ text: String) -> UInt64 {
        var hash: UInt64 = fnvOffsetBasis
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return hash
    }

    nonisolated static func rotated<T>(_ values: [T], by startIndex: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        let start = startIndex % values.count
        return Array(values[start...]) + Array(values[..<start])
    }

    nonisolated static func combinations(
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

    nonisolated static func makeReasonCodes(
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

    nonisolated static func qaSummary(
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

    nonisolated static func role(for index: Int) -> PlaybackSmartFillSlotRole {
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
    struct CurrentAssetEvidence {
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

    nonisolated static func currentAssetEvidence(
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

        let currentCandidate = input.candidates[0]
        let faceRegions =
            currentCandidate.faceRects
            + currentCandidate.faceRects.map {
                upperBodyProxy(from: $0, params: input.policy.upperBodyProxyParams)
            }
        let faceProtectionPassed = faceRegions.allSatisfy {
            slot.cropRectInSource.contains($0, margin: 0)
        }
        let subjectProtectionPassed = currentCandidate.subjectRects.allSatisfy {
            slot.cropRectInSource.contains($0, margin: 0)
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
            faceProtectionPassed: faceProtectionPassed,
            subjectProtectionPassed: subjectProtectionPassed,
            visibleQuality: visibleQuality,
            ledgerSceneAssets: ledgerSceneAssets,
            slotRoles: slotRoles,
            slotRefs: slotRefs
        )
    }

    nonisolated static func area(of rect: PlaybackPlanningRect) -> Double {
        rect.width * rect.height
    }

    nonisolated static func slotAspectRatio(
        frame: PlaybackPlanningRect,
        surface: PlaybackSmartFillSurface
    ) -> Double {
        guard frame.height > 0 else { return 1 }
        return surface.aspectRatio * frame.width / frame.height
    }

    nonisolated static func clamp(_ rect: PlaybackPlanningRect) -> PlaybackPlanningRect {
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

    nonisolated static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private nonisolated static func formatOptional(_ value: Double?) -> String {
        guard let value else { return "none" }
        return format(value)
    }
}
