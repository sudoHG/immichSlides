//
//  PlaybackSmartFillPlanner.swift
//  immichSlides
//
//  Smart Fill pure planner: synchronous computation only; no network, disk cache, or SwiftUI access.
//

import Foundation

enum PlaybackSmartFillPlanner {
    nonisolated static let comparisonTolerance: Double = 0.000001
    nonisolated static let constructiveSearchIterationLimit: Int = 24
    nonisolated static let ratioPresetMatchingTolerance: Double = 0.0005
    nonisolated static let rotationHashPrefixCharacterCount: Int = 12
    nonisolated static let fnvOffsetBasis: UInt64 = 14695981039346656037
    nonisolated static let fnvPrime: UInt64 = 1099511628211
    private nonisolated static let defaultTopRejectedReasonCount: Int = 5
    private nonisolated static let maximumRejectedLayoutSummaryCount: Int = 36
    private nonisolated static let maximumRejectedLayoutSummariesPerBucket: Int = 3

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

    struct LayoutCandidate: Equatable, Sendable {
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

    struct LayoutEvaluation: Sendable {
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

    struct ProtectedRectEntry: Equatable, Sendable {
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

    struct RotationInfo: Sendable {
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

    enum ConstructiveDoubleDirection: Sendable {
        case vertical
        case horizontal
    }

    struct ConstructiveDoubleAttempt: Sendable {
        let candidates: [PlaybackSmartFillCandidateSummary]
        let layout: LayoutCandidate
        let score: Double
        let isCurrentPrimary: Bool
        let order: Int

        nonisolated init(
            candidates: [PlaybackSmartFillCandidateSummary],
            layout: LayoutCandidate,
            score: Double,
            isCurrentPrimary: Bool,
            order: Int
        ) {
            self.candidates = candidates
            self.layout = layout
            self.score = score
            self.isCurrentPrimary = isCurrentPrimary
            self.order = order
        }
    }

    struct PlannerState: Sendable {
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

        nonisolated func topRejectedReasons(limit: Int = PlaybackSmartFillPlanner.defaultTopRejectedReasonCount)
            -> [PlaybackSmartFillPlannerRejectReason]
        {
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
            guard rejectedLayoutDiagnostics.count < PlaybackSmartFillPlanner.maximumRejectedLayoutSummaryCount else {
                return
            }

            let role = PlaybackSmartFillPlanner.role(for: slotIndex)
            let bucket = [
                reason.rawValue,
                layout.variant.rawValue,
                role.rawValue,
                String(slotIndex)
            ].joined(separator: "|")
            guard
                rejectedLayoutDiagnosticBucketCounts[bucket, default: 0]
                    < PlaybackSmartFillPlanner.maximumRejectedLayoutSummariesPerBucket
            else { return }
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

extension PlaybackPlanningRect {
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

extension PlaybackProtectionRect {
    nonisolated var planningRect: PlaybackPlanningRect {
        PlaybackPlanningRect(x: x, y: y, width: width, height: height)
    }
}

extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
