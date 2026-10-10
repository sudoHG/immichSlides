import Foundation
import XCTest

#if os(tvOS)
final class PlaybackSmartFillTVOSVisualUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSmartFillRandomPlaybackTwentyScenesOnAppleTV() throws {
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "random-tvos")
        assertPolicies(in: evidence, contain: "appletv-landscape", scenario: "Apple TV random playback")
        assertSurfacesAreLandscape(in: evidence, scenario: "Apple TV random playback")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "Apple TV random playback")
    }

    @MainActor
    func testPlaybackTransitionAnimationEvidenceControlBarQuickSwitchOnAppleTV() throws {
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)
        attachScreenshot(app: app, name: "appletv-transition-00-before")

        for index in 1...3 {
            pressNext(app: app)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.35))))
            attachScreenshot(app: app, name: "appletv-transition-\(index)-mid")
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.65))))
            attachScreenshot(app: app, name: "appletv-transition-\(index)-settled")
        }

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: TestWait.seconds(.product(6))),
            "Apple TV control bar settings button should still exist after quick switching"
        )
    }

    @MainActor
    func testSmartFillMotionAppleTVRealAutoplayRuntimeEvidence() throws {
        let scenario = smartFillMotionScenarioName(
            defaultScenario: "apple-tv-smartfill-motion-real-autoplay"
        )
        let app = try launchConfiguredAppAtModeSelection(
            shouldForceAutoplayOff: false,
            shouldEnableSmartFillMotionTrace: true
        )
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(12))) {
                !app.buttons["slideshow.control.settings.button"].exists
            },
            "\(scenario) control bar must auto-hide before sampling so clean motion rows are not polluted by the control bar"
        )
        _ = try waitForCurrentManifest(app: app, timeout: TestWait.seconds(.infrastructure(45)))

        let sampleDuration = smartFillMotionSampleDurationSeconds()
        let evidence = collectMotionRuntimeEvidence(
            app: app,
            scenario: scenario,
            duration: sampleDuration,
            interval: smartFillMotionSampleIntervalSeconds()
        )
        let traceText = try appSmartFillMotionTraceText(
            app: app, timeout: TestWait.seconds(.infrastructure(sampleDuration + 30)))
        let fallbackManifest = try waitForCurrentManifest(app: app, timeout: TestWait.seconds(.product(5)))
        let traceMotionRows = motionFrameRows(fromTraceText: traceText, fallbackManifest: fallbackManifest)
        let traceProductRows = productSceneSequenceRows(fromTraceText: traceText, fallbackManifest: fallbackManifest)
        let motionRows = traceMotionRows.isEmpty ? evidence.motionRows : traceMotionRows
        let productRows = traceProductRows.isEmpty ? evidence.productRows : traceProductRows

        writeProductSceneSequenceEvidence(
            productRows,
            motionRows: motionRows,
            scenario: scenario,
            sampleDuration: sampleDuration
        )
        writeMotionFrameEvidence(motionRows, scenario: scenario)

        let productSceneTypes = Set(productRows.map(\.manifestSceneType))
        let cleanAvailableSceneTypes = Set(
            motionRows.compactMap { row -> String? in
                guard row.fields["progressFrameStatus"] == "available",
                    row.fields["controlBarVisible"] == "false",
                    row.fields["appOverlayPollution"] == "none"
                else {
                    return nil
                }
                return row.manifestSceneType
            })
        let transitionRows = productRows.filter { row in
            row.productTransitionFields["productTransitionActive"] == "true"
        }
        let transitionRowsWithoutBacking = transitionRows.filter { row in
            row.productTransitionFields["productBlackBackingActive"] != "true"
        }

        XCTAssertFalse(motionRows.isEmpty, "\(scenario) must capture Apple TV motion frame rows")
        XCTAssertFalse(productRows.isEmpty, "\(scenario) must capture the Apple TV product scene sequence")
        XCTAssertTrue(
            productSceneTypes.contains("double") || productSceneTypes.contains("triple"),
            "\(scenario) must cover a SmartFill accepted double/triple scene"
        )
        XCTAssertTrue(
            productSceneTypes.contains("single"), "\(scenario) must cover a SmartFill planner single-filled scene")
        XCTAssertTrue(
            cleanAvailableSceneTypes.contains("double") || cleanAvailableSceneTypes.contains("triple"),
            "\(scenario) clean rows must include accepted double/triple motion"
        )
        XCTAssertTrue(
            cleanAvailableSceneTypes.contains("single"), "\(scenario) clean rows must include SmartFill single motion")
        XCTAssertFalse(transitionRows.isEmpty, "\(scenario) must cover a real autoplay transition")
        XCTAssertTrue(
            transitionRowsWithoutBacking.isEmpty,
            "\(scenario) accepted/single SmartFill transitions must enable the black backing"
        )
        _ = captureRuntimeScreenshot(app: app, name: "smartfill-\(scenario)-appletv-final", shouldAttachToXCTest: true)
    }

    @MainActor
    func testSmartFillMotionAppleTVRemoteInteractionLivenessEvidence() throws {
        let scenario = smartFillMotionScenarioName(
            defaultScenario: "apple-tv-smartfill-motion-remote-interaction-liveness"
        )
        let app = try launchConfiguredAppAtModeSelection(
            shouldForceAutoplayOff: false,
            shouldEnableSmartFillMotionTrace: true
        )
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(12))) {
                !app.buttons["slideshow.control.settings.button"].exists
            },
            "\(scenario) control bar must auto-hide before the interaction"
        )
        let initialManifest = try waitForCurrentManifest(app: app, timeout: TestWait.seconds(.infrastructure(45)))
        let traceStartedAt = try waitForSmartFillMotionTraceCollecting(
            app: app, timeout: TestWait.seconds(.infrastructure(45)))

        var actions: [[String: Any]] = []
        let sampleDuration = smartFillMotionInteractionSampleDurationSeconds()
        let evidence = collectMotionRuntimeEvidence(
            app: app,
            scenario: scenario,
            duration: sampleDuration,
            interval: smartFillMotionSampleIntervalSeconds()
        ) { elapsed in
            if actions.isEmpty, elapsed >= 1.0 {
                XCUIRemote.shared.press(.up)
                self.recordInteractionAction(
                    "tap-image-show-control-bar",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
            if actions.containsAction("tap-image-show-control-bar"),
                !actions.containsAction("select-control-bar-next"),
                elapsed >= 2.0
            {
                self.pressNext(app: app)
                self.recordInteractionAction(
                    "select-control-bar-next",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
            if actions.containsAction("select-control-bar-next"),
                !actions.containsAction("pause"),
                elapsed >= 8.0
            {
                XCUIRemote.shared.press(.playPause)
                self.recordInteractionAction(
                    "pause",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
            if actions.containsAction("pause"),
                !actions.containsAction("resume"),
                elapsed >= 10.0
            {
                XCUIRemote.shared.press(.playPause)
                self.recordInteractionAction(
                    "resume",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
            if actions.containsAction("resume"),
                !actions.containsAction("control-bar-auto-hidden"),
                !app.buttons["slideshow.control.settings.button"].exists
            {
                self.recordInteractionAction(
                    "control-bar-auto-hidden",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
        }
        XCUIRemote.shared.press(.menu)
        recordInteractionAction(
            "menu-return",
            elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
            actions: &actions
        )

        let traceText = try appSmartFillMotionTraceText(
            app: app, timeout: TestWait.seconds(.infrastructure(sampleDuration + 30)))
        let traceMotionRows = motionFrameRows(fromTraceText: traceText, fallbackManifest: initialManifest)
        let traceProductRows = productSceneSequenceRows(fromTraceText: traceText, fallbackManifest: initialManifest)
        let motionRows = traceMotionRows.isEmpty ? evidence.motionRows : traceMotionRows
        let productRows = traceProductRows.isEmpty ? evidence.productRows : traceProductRows

        writeProductSceneSequenceEvidence(
            productRows,
            motionRows: motionRows,
            scenario: scenario,
            sampleDuration: sampleDuration
        )
        writeMotionFrameEvidence(motionRows, scenario: scenario)
        writeInteractionActionEvidence(actions, scenario: scenario)

        XCTAssertTrue(
            actions.containsAction("tap-image-show-control-bar"),
            "\(scenario) must cover waking the control bar with the remote")
        XCTAssertTrue(
            actions.containsAction("select-control-bar-next"), "\(scenario) must cover Select on a control bar button")
        XCTAssertTrue(actions.containsAction("pause"), "\(scenario) must cover Play/Pause pause")
        XCTAssertTrue(actions.containsAction("resume"), "\(scenario) must cover Play/Pause resume")
        XCTAssertTrue(
            actions.containsAction("control-bar-auto-hidden"),
            "\(scenario) must cover motion continuing after auto-hide")
        XCTAssertTrue(actions.containsAction("menu-return"), "\(scenario) must cover Back/Menu or an equivalent return")
        XCTAssertFalse(motionRows.isEmpty, "\(scenario) must capture motion rows during the interaction")
        XCTAssertFalse(
            motionRows.filter { $0.fields["progressFrameStatus"] == "available" }.isEmpty,
            "\(scenario) available motion rows must continue during the interaction"
        )
        _ = captureRuntimeScreenshot(app: app, name: "smartfill-\(scenario)-appletv-final", shouldAttachToXCTest: true)
    }

    @MainActor
    func testSmartFillPeopleFilterPlaybackTwentyScenesOnAppleTV() async throws {
        let personID = try await findEligiblePersonID(minimumAssetCount: EvidenceCalibration.minimumPersonAssetCount)
        let selectionJSON = makePersonFilterSelectionJSON(personID: personID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "people-filter-tvos")
        assertPolicies(in: evidence, contain: "appletv-landscape", scenario: "Apple TV people filter playback")
        assertSurfacesAreLandscape(in: evidence, scenario: "Apple TV people filter playback")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "Apple TV people filter playback")
    }

    @MainActor
    func testSmartFillFixedAlbumPlaybackTwentyScenesOnAppleTV() throws {
        let albumID = try requireFixedAlbumID()
        let selectionJSON = makeAlbumFilterSelectionJSON(albumID: albumID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "fixed-album-tvos")
        assertPolicies(in: evidence, contain: "appletv-landscape", scenario: "Apple TV fixed album playback")
        assertSurfacesAreLandscape(in: evidence, scenario: "Apple TV fixed album playback")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "Apple TV fixed album playback")
    }
}
#endif
