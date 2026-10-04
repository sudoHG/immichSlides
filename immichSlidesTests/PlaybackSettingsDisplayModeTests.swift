//
//  PlaybackSettingsDisplayModeTests.swift
//  immichSlidesTests
//
//  Placeholder; the template example() was removed so it does not skew test counts.
//

import Testing
import Foundation
@testable import immichSlides

struct ImmichSlidesTestsPlaceholder {
}

@MainActor
@Suite(.serialized)
struct PlaybackSettingsDisplayModeTests {

    @Test
    func `legacy playback settings missing displayMode decode to SmartFill without dropping other fields`() throws {
        let data = Data(
            """
            {
              "autoPlayEnabled": false,
              "intervalSeconds": 8,
              "showExif": false,
              "defaultPlaybackMode": "filtered",
              "showDebugOverlay": true
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)

        #expect(settings.autoPlayEnabled == false)
        #expect(settings.intervalSeconds == 8)
        #expect(settings.showExif == false)
        #expect(settings.defaultPlaybackMode == .filtered)
        #expect(settings.showDebugOverlay == true)
        #expect(settings.displayMode == .smartFill)
    }

    @Test
    func `each missing playback settings field falls back to its default independently`() throws {
        let data = Data(
            """
            {
              "autoPlayEnabled": false,
              "showExif": false,
              "defaultPlaybackMode": "filtered",
              "displayMode": "singlePhoto"
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)

        #expect(settings.autoPlayEnabled == false)
        #expect(settings.intervalSeconds == PlaybackSettings().intervalSeconds)
        #expect(settings.showExif == false)
        #expect(settings.defaultPlaybackMode == .filtered)
        #expect(settings.showDebugOverlay == PlaybackSettings().showDebugOverlay)
        #expect(settings.displayMode == .singlePhoto)
    }

    @Test
    func `single photo display mode round trips through PlaybackSettingsStore`() {
        let snapshot = PlaybackSettingsSnapshot.capture()
        defer { snapshot.restore() }

        let store = PlaybackSettingsStore()
        var settings = PlaybackSettings()
        settings.autoPlayEnabled = false
        settings.intervalSeconds = 12
        settings.showExif = false
        settings.defaultPlaybackMode = .filtered
        settings.showDebugOverlay = true
        settings.displayMode = .singlePhoto

        store.save(settings)

        let restored = store.load()
        #expect(restored == settings)
    }

    @Test
    func `selecting single photo display mode only updates displayMode`() {
        let snapshot = PlaybackSettingsSnapshot.capture()
        defer { snapshot.restore() }

        let store = PlaybackSettingsStore()
        var settings = PlaybackSettings()
        settings.autoPlayEnabled = false
        settings.intervalSeconds = 9
        settings.showExif = false
        settings.defaultPlaybackMode = .filtered
        settings.showDebugOverlay = true
        store.save(settings)

        let viewModel = PlaybackSettingsViewModel(store: store)
        viewModel.settings.displayMode = .singlePhoto

        let restored = store.load()
        #expect(restored?.displayMode == .singlePhoto)
        #expect(restored?.autoPlayEnabled == false)
        #expect(restored?.intervalSeconds == 9)
        #expect(restored?.showExif == false)
        #expect(restored?.defaultPlaybackMode == .filtered)
        #expect(restored?.showDebugOverlay == true)
    }
}

private struct PlaybackSettingsSnapshot {
    let settings: PlaybackSettings?

    static func capture() -> PlaybackSettingsSnapshot {
        PlaybackSettingsSnapshot(settings: PlaybackSettingsStore().load())
    }

    func restore() {
        let store = PlaybackSettingsStore()
        if let settings {
            store.save(settings)
        } else {
            store.clear()
        }
    }
}
