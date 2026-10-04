import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct SharedScenePlannerDeterminismTests {
    private let sceneSampleCountPerSurface: Int = 12

    private struct CatalogRow: Codable, Equatable {
        let surface: String
        let policyId: String
        let layoutVariant: String
        let ratioPreset: String
        let primaryShare: String
        let frames: [String]
    }

    private struct PlannerRow: Codable, Equatable {
        let surface: String
        let sceneOrdinal: Int
        let sceneType: String
        let layoutPolicyId: String
        let layoutVariant: String
        let ratioPreset: String
        let acceptedSceneSearchTier: String
        let fallbackReason: String
        let fallbackCategory: String
        let candidateWindowUsed: Int
        let evaluationCount: Int
        let rotationStartLayoutVariant: String
        let rotationStartRatioPreset: String
        let acceptedLayoutVariant: String
        let acceptedRatioPreset: String
        let rotationKeyHashPrefix: String
        let slots: [SlotRow]
    }

    private struct SlotRow: Codable, Equatable {
        let role: String
        let candidateReference: String
        let frameInScene: String
        let cropRectInSource: String
        let cropRetention: String
        let slotAspectRatio: String
    }

    private struct DeterminismDocument: Codable, Equatable {
        let schemaVersion: String
        let fixedSeed: String
        let catalogRows: [CatalogRow]
        let plannerRows: [PlannerRow]
    }

    @Test
    func `planner catalog and output serialize to deterministic canonical bytes`() throws {
        let first = makeDocument()
        let second = makeDocument()
        #expect(first == second)
        #expect(!first.catalogRows.isEmpty)
        #expect(!first.plannerRows.isEmpty)

        let canonical = try SharedSceneEvidenceManifest.canonicalJSONData(first)
        let repeated = try SharedSceneEvidenceManifest.canonicalJSONData(second)
        #expect(canonical == repeated)
    }

    private func makeDocument() -> DeterminismDocument {
        let fixedSeed = "shared-scene-paired-seed-v1"
        return DeterminismDocument(
            schemaVersion: "shared-scene-planner-determinism-v1",
            fixedSeed: fixedSeed,
            catalogRows: surfaces.flatMap(catalogRows),
            plannerRows: surfaces.flatMap { surface in
                (0..<sceneSampleCountPerSurface).map { ordinal in
                    plannerRow(surface: surface, seed: fixedSeed, ordinal: ordinal)
                }
            }
        )
    }

    private func catalogRows(surface: PlaybackSmartFillSurface) -> [CatalogRow] {
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: surface)
        return policy.layoutAllowlist.flatMap { variant in
            policy.ratioPresets(for: variant).map { preset in
                CatalogRow(
                    surface: surface.internalSurfaceFingerprint,
                    policyId: policy.layoutPolicyId,
                    layoutVariant: variant.rawValue,
                    ratioPreset: preset.id,
                    primaryShare: format(preset.primaryShare),
                    frames: PlaybackSmartFillLayoutCatalog.frames(for: variant, preset: preset).map(format)
                )
            }
        }
    }

    private func plannerRow(
        surface: PlaybackSmartFillSurface,
        seed: String,
        ordinal: Int
    ) -> PlannerRow {
        let scenePlan = PlaybackSmartFillPlanner.plan(
            PlaybackSmartFillPlannerInput(
                surface: surface,
                candidates: candidates,
                protectionSnapshot: .empty,
                policy: .policy(for: surface),
                playbackSessionSeed: seed,
                sceneOrdinal: ordinal
            )
        )
        return PlannerRow(
            surface: surface.internalSurfaceFingerprint,
            sceneOrdinal: ordinal,
            sceneType: scenePlan.sceneType.rawValue,
            layoutPolicyId: scenePlan.layoutPolicyId,
            layoutVariant: scenePlan.layoutVariant.rawValue,
            ratioPreset: scenePlan.ratioPreset,
            acceptedSceneSearchTier: scenePlan.acceptedSceneSearchTier.rawValue,
            fallbackReason: scenePlan.fallbackReason?.rawValue ?? "none",
            fallbackCategory: scenePlan.fallbackCategory.rawValue,
            candidateWindowUsed: scenePlan.candidateWindowUsed,
            evaluationCount: scenePlan.evaluationCount,
            rotationStartLayoutVariant: scenePlan.rotationStartLayoutVariant.rawValue,
            rotationStartRatioPreset: scenePlan.rotationStartRatioPreset,
            acceptedLayoutVariant: scenePlan.acceptedLayoutVariant.rawValue,
            acceptedRatioPreset: scenePlan.acceptedRatioPreset,
            rotationKeyHashPrefix: scenePlan.rotationKeyHashPrefix,
            slots: scenePlan.slots.map { slot in
                SlotRow(
                    role: slot.role.rawValue,
                    candidateReference: slot.candidateReference,
                    frameInScene: format(slot.frameInScene),
                    cropRectInSource: format(slot.cropRectInSource),
                    cropRetention: format(slot.cropRetention),
                    slotAspectRatio: format(slot.slotAspectRatio)
                )
            }
        )
    }

    private var surfaces: [PlaybackSmartFillSurface] {
        [
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                profile: .iPhone,
                orientation: .portrait
            ),
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2556, height: 1179),
                profile: .iPhone,
                orientation: .landscape
            ),
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2048, height: 2732),
                profile: .iPad,
                orientation: .portrait
            ),
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            ),
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 3840, height: 2160),
                profile: .appleTV,
                orientation: .landscape
            )
        ]
    }

    private var candidates: [PlaybackSmartFillCandidateSummary] {
        let aspects = [0.42, 0.56, 0.66, 0.75, 0.80, 1.00, 1.25, 1.33, 1.50, 1.78, 2.00, 2.40, 3.00]
        return aspects.enumerated().map { index, aspect in
            let longEdge = 3200
            let width: Int
            let height: Int
            if aspect >= 1 {
                width = Int((Double(longEdge) * aspect).rounded())
                height = longEdge
            } else {
                width = longEdge
                height = Int((Double(longEdge) / aspect).rounded())
            }
            let pixelSize = PlaybackPlanningPixelSize(width: width, height: height)
            let faceRects =
                index.isMultiple(of: 3)
                ? [PlaybackPlanningRect(x: 0.35, y: 0.12, width: 0.30, height: 0.32)]
                : []
            return PlaybackSmartFillCandidateSummary(
                reference: "fixture-\(String(format: "%02d", index))",
                sourceImage: PlaybackPlanningSourceImageSummary(
                    assetPixelSize: pixelSize,
                    exifPixelSize: pixelSize,
                    orientation: "available"
                ),
                faceRects: faceRects,
                subjectRects: faceRects
            )
        }
    }

    private func format(_ rect: PlaybackPlanningRect) -> String {
        [rect.x, rect.y, rect.width, rect.height].map(format).joined(separator: ",")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.9f", value)
    }
}
