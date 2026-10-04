//
//  PlaybackProtectionTests.swift
//  immichSlidesTests
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct PlaybackProtectionTests {

    @Test
    func `normalized coordinates clamp out-of-range input and discard invalid input`() throws {
        let clamped = try #require(
            PlaybackProtectionRect.normalized(
                x: -0.25,
                y: 0.75,
                width: 1.5,
                height: 0.5
            ))

        #expect(clamped == PlaybackProtectionRect(x: 0, y: 0.75, width: 1, height: 0.25))
        #expect(PlaybackProtectionRect.normalized(x: 0, y: 0, width: -0.1, height: 0.2) == nil)
        #expect(PlaybackProtectionRect.normalized(x: .nan, y: 0, width: 0.1, height: 0.2) == nil)
        #expect(
            PlaybackProtectionRect.fromPixelRect(
                x: 100,
                y: 50,
                width: 200,
                height: 100,
                surfaceWidth: 1000,
                surfaceHeight: 500
            ) == PlaybackProtectionRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        #expect(
            PlaybackProtectionRect.fromPointRect(
                x: 10,
                y: 20,
                width: 30,
                height: 40,
                surfaceWidth: 0,
                surfaceHeight: 100
            ) == nil)
    }

    @Test
    func `safe area and top system obstruction produce hard-priority protection regions`() {
        let snapshot = PlaybackProtectionSnapshot(
            safeAreaInsets: PlaybackProtectionInsets(top: 20, leading: 10, bottom: 30, trailing: 40),
            systemTopObstructionHeight: 44,
            surfaceWidth: 200,
            surfaceHeight: 100
        )

        #expect(snapshot.regions.count == 5)
        #expect(snapshot.regions.allSatisfy { $0.priority == .hard })
        #expect(snapshot.regions.map(\.source).contains(.systemSafeArea))
        #expect(snapshot.regions.map(\.source).contains(.systemTopObstruction))
        #expect(
            snapshot.regions.contains {
                $0.source == .systemTopObstruction
                    && $0.rect == PlaybackProtectionRect(x: 0, y: 0, width: 1, height: 0.44)
            })
    }

    @Test
    func `EXIF panel is a soft overlay only when shown, has content, and the frame is valid`() {
        let validFrame = PlaybackProtectionRect(x: 0.7, y: 0.2, width: 0.2, height: 0.3)

        let active = PlaybackProtectionRegion.exifPanel(
            isShowingExif: true,
            hasExifContent: true,
            frame: validFrame
        )
        let hidden = PlaybackProtectionRegion.exifPanel(
            isShowingExif: false,
            hasExifContent: true,
            frame: validFrame
        )
        let empty = PlaybackProtectionRegion.exifPanel(
            isShowingExif: true,
            hasExifContent: false,
            frame: validFrame
        )
        let invalid = PlaybackProtectionRegion.exifPanel(
            isShowingExif: true,
            hasExifContent: true,
            frame: nil
        )

        #expect(active?.source == .exifPanel)
        #expect(active?.priority == .soft)
        #expect(active?.activeConditionSummary == "showExif=true;hasExif=true;frame=valid")
        #expect(hidden == nil)
        #expect(empty == nil)
        #expect(invalid == nil)
    }

    @Test
    func `futureOverlay and controlBar use stable sources and priorities`() throws {
        let overlay = try #require(
            PlaybackProtectionRegion.futureOverlay(
                rect: PlaybackProtectionRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                activeConditionSummary: "debug-preview"
            ))
        let controlBar = try #require(
            PlaybackProtectionRegion.controlBar(
                rect: PlaybackProtectionRect(x: 0, y: 0.85, width: 1, height: 0.15),
                activeConditionSummary: "visible"
            ))

        #expect(overlay.source == .futureOverlay)
        #expect(overlay.priority == .soft)
        #expect(controlBar.source == .controlBar)
        #expect(controlBar.priority == .soft)
    }

    @Test
    func `QA debug summary is stable and readable and contains no sensitive patterns`() throws {
        let unsafeSummary = "url=h" + "ttps://example.invalid/to" + "ken/asset-1234567890" + "1234567890"
        let snapshot = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.futureOverlay(
                    rect: PlaybackProtectionRect(x: 0, y: 0, width: 0.1, height: 0.1),
                    activeConditionSummary: unsafeSummary
                ))
        ])

        #expect(
            snapshot.qaDebugSummary
                == "version=screen-protection-v1;regions=1;hard=0;standard=0;soft=1;sources=future-overlay")
        #expect(!snapshot.qaDebugSummary.localizedCaseInsensitiveContains("http" + "://"))
        #expect(!snapshot.qaDebugSummary.localizedCaseInsensitiveContains("https" + "://"))
        #expect(!snapshot.qaDebugSummary.localizedCaseInsensitiveContains("api " + "key"))
        #expect(!snapshot.qaDebugSummary.localizedCaseInsensitiveContains("tok" + "en"))
        #expect(!snapshot.qaDebugSummary.localizedCaseInsensitiveContains("key" + "chain"))
        #expect(!snapshot.qaDebugSummary.localizedCaseInsensitiveContains("gp" + "s"))
        #expect(!snapshot.qaDebugSummary.localizedCaseInsensitiveContains("base" + "64"))
        #expect(!snapshot.qaDebugSummary.localizedCaseInsensitiveContains("/Us" + "ers/"))
        #expect(!snapshot.qaDebugSummary.contains("asset-1234567890" + "1234567890"))
    }
}
