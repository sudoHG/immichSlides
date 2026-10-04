import Foundation
import Testing
@testable import immichSlides

extension PlaybackSmartFillPlannerTests {
    func plan(
        surface: PlaybackSmartFillSurface,
        candidates: [PlaybackSmartFillCandidateSummary],
        protectionSnapshot: PlaybackProtectionSnapshot = .empty,
        seed: String = "test-session",
        sceneOrdinal: Int = 0
    ) -> PlaybackSmartFillPlannerResult {
        PlaybackSmartFillPlanner.plan(
            PlaybackSmartFillPlannerInput(
                surface: surface,
                candidates: candidates,
                protectionSnapshot: protectionSnapshot,
                policy: .policy(for: surface),
                playbackSessionSeed: seed,
                sceneOrdinal: sceneOrdinal
            )
        )
    }

    var phonePortraitSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
            profile: .iPhone,
            orientation: .portrait
        )
    }

    var phoneLandscapeSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2556, height: 1179),
            profile: .iPhone,
            orientation: .landscape
        )
    }

    var iPadLandscapeSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
            profile: .iPad,
            orientation: .landscape
        )
    }

    var iPadPortraitSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2048, height: 2732),
            profile: .iPad,
            orientation: .portrait
        )
    }

    var appleTVSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 3840, height: 2160),
            profile: .appleTV,
            orientation: .landscape
        )
    }

    var smartFillSurfaces: [PlaybackSmartFillSurface] {
        [
            phonePortraitSurface,
            phoneLandscapeSurface,
            iPadPortraitSurface,
            iPadLandscapeSurface,
            appleTVSurface
        ]
    }

    func candidate(
        reference: String,
        width: Int,
        height: Int,
        faceRects: [PlaybackPlanningRect] = []
    ) -> PlaybackSmartFillCandidateSummary {
        let pixelSize = PlaybackPlanningPixelSize(width: width, height: height)
        return PlaybackSmartFillCandidateSummary(
            reference: reference,
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: pixelSize,
                exifPixelSize: pixelSize,
                orientation: "available"
            ),
            faceRects: faceRects,
            subjectRects: faceRects
        )
    }

    var benchmarkAspects: [Double] {
        [
            0.42, 0.56, 0.66, 0.75, 0.80, 1.00, 1.25, 1.33, 1.50, 1.78, 2.00, 2.40, 3.00
        ]
    }

    var benchmarkFixedFaceRect: PlaybackPlanningRect {
        PlaybackPlanningRect(x: 0.35, y: 0.12, width: 0.30, height: 0.32)
    }

    func benchmarkCandidates(
        surface: PlaybackSmartFillSurface,
        sceneIndex: Int,
        candidateCount: Int = 72
    ) -> [PlaybackSmartFillCandidateSummary] {
        let currentAspect = benchmarkAspects[sceneIndex % benchmarkAspects.count]
        let current = candidate(
            reference: "bench-\(surface.surfaceKey)-\(sceneIndex)-current",
            width: benchmarkPixelSize(for: currentAspect).width,
            height: benchmarkPixelSize(for: currentAspect).height
        )
        let lookahead = (0..<candidateCount).map { candidateIndex in
            let aspect = benchmarkAspects[(sceneIndex + candidateIndex + 1) % benchmarkAspects.count]
            let pixelSize = benchmarkPixelSize(for: aspect)
            return candidate(
                reference: "bench-\(surface.surfaceKey)-\(sceneIndex)-\(candidateIndex)",
                width: pixelSize.width,
                height: pixelSize.height,
                faceRects: (sceneIndex + candidateIndex).isMultiple(of: 2) ? [benchmarkFixedFaceRect] : []
            )
        }
        return [current] + lookahead
    }

    func benchmarkPixelSize(for aspect: Double) -> PlaybackPlanningPixelSize {
        PlaybackPlanningPixelSize(width: Int((aspect * 1_200).rounded()), height: 1_200)
    }

    func assertSendable<T: Sendable>(_ type: T.Type) {}

    func assertDoesNotExposeForbiddenBackgroundBoundary(_ value: Any) {
        assertDoesNotExposeForbiddenBackgroundBoundary(value, depth: 0)
    }

    func assertDoesNotExposeForbiddenBackgroundBoundary(_ value: Any, depth: Int) {
        guard depth < 6 else { return }
        let forbiddenTypeFragments = [
            "AssetsDownloadManager",
            "PlaybackSessionEngine",
            "ObservableObject",
            "RequestModifier",
            "URLRequest",
            "View",
            "SwiftUI"
        ]
        let reflectedValueType = String(reflecting: type(of: value))
        for forbidden in forbiddenTypeFragments {
            #expect(
                !reflectedValueType.contains(forbidden),
                "\(reflectedValueType) must not cross the background planning boundary")
        }
        for child in Mirror(reflecting: value).children {
            let reflectedType = String(reflecting: type(of: child.value))
            for forbidden in forbiddenTypeFragments {
                #expect(
                    !reflectedType.contains(forbidden),
                    "\(reflectedType) must not cross the background planning boundary")
            }
            assertDoesNotExposeForbiddenBackgroundBoundary(child.value, depth: depth + 1)
        }
    }
}
