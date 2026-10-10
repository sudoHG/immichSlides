import Foundation
import XCTest

enum EvidenceCalibration {
    static let defaultSceneCount: Int = 20
    static let minimumPersonAssetCount: Int = 20
    static let defaultMotionSampleSeconds: Double = TestWait.seconds(.product(36))
    static let defaultMotionIntervalSeconds: Double = TestWait.seconds(.product(5.0))
    static let defaultMotionTraceTimeoutSeconds: Double = TestWait.seconds(.product(60))
    static let cropRetentionThreshold: Double = 0.60
    static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    static let fnvPrime: UInt64 = 1_099_511_628_211
}

enum SmartFillRuntimeEvidenceSupport {
    static func writeScreenshotPNG(_ data: Data, to fileURL: URL) -> URL? {
        do {
            try data.write(to: fileURL, options: .atomic)
            guard try Data(contentsOf: fileURL) == data else { return nil }
            return fileURL
        } catch {
            return nil
        }
    }

    struct AssetIDReplayValidationRow {
        let sequence: Int
        let rule: String
        let expected: String
        let observedSlotRef: String?
        let observedCurrentAssetRef: String?
        let observedReplayIndex: Int?
        let status: String
    }

    struct AssetIDReplayMonotonicProgress {
        let expected: String
        let status: String
        let shouldIncludeManifest: Bool
        let shouldStopSampling: Bool
        let nextPreviousReplayAssetIndex: Int?
        let failureMessage: String?
    }

    static let schemaVersion = "decision-layer-v1"
    static let requiredRuntimePhaseKeys = [
        "playbackEntryRequested",
        "assetPoolRequestStarted",
        "assetPoolReady",
        "firstScenePlanningStarted",
        "firstScenePlanned",
        "firstScenePublished",
        "firstSlotReady",
        "allVisibleSlotsReady"
    ]
    static let harnessOnlyJSONFields = [
        "harnessPhaseTimestampsMs",
        "harnessPhaseDurationsMs",
        "harnessCollectionToFirstManifestObservedMs",
        "harnessCollectionToFirstNonLoadingScreenshotMs",
        "crossClockSummaryPolicy",
        "firstNonLoadingScreenshotCaptured"
    ]
    static let requiredJSONFields = [
        "schemaVersion",
        "runId",
        "prHead",
        "baseHead",
        "sequence",
        "sceneIdHash",
        "sceneType",
        "isFallback",
        "fallbackReason",
        "fallbackCategory",
        "layoutVariant",
        "layoutPreset",
        "surfaceKey",
        "surfaceFingerprint",
        "photoCanvasId",
        "photoCanvasPointSize",
        "photoCanvasPixelSize",
        "canvasCoverage",
        "emptyCanvasRatio",
        "maxContinuousEmptyAxisRatio",
        "gapPixelCount",
        "overlapPixelCount",
        "slotCount",
        "slotFrames",
        "slotCropRects",
        "protectionOverlapDetails",
        "slotReadiness",
        "ledgerSceneAssets",
        "controlBarVisible",
        "controlBarHardRejected",
        "controlBarSubjectOverlapWarning",
        "exifOverlayVisible",
        "exifOverlayHardRejected",
        "publishReason",
        "preparedHit",
        "actionToSceneMs",
        "captureTimestamp",
        "screenshotPath",
        "startupRunId",
        "startupSequence",
        "startupClockSource",
        "runtimePhaseTimestampsMs",
        "runtimePhaseDurationsMs",
        "firstSceneRuntimeMs",
        "firstSlotReadyRuntimeMs",
        "allVisibleSlotsReadyRuntimeMs",
        "startupMissingPhases",
        "startupBlockingPhase",
        "assetPoolSizeAtFirstPlan",
        "eligibleCandidateCountAtFirstPlan",
        "plannerAttemptCountAtFirstPlan",
        "candidateWindowUsedAtFirstPlan",
        "firstSceneSlotReadiness",
        "firstSceneReadySlotCount",
        "firstScenePendingSlotCount",
        "firstSceneFailedSlotCount",
        "photoLoadPhaseTimestampsMs",
        "photoLoadPhaseDurationsMs",
        "firstPhotoCacheStatus",
        "firstImageDisplayedRuntimeMs",
        "firstImageLoadStatus",
        "fallbackReasonTopList",
        "rejectedLayoutReasonTopList",
        "rejectedLayoutDiagnostics",
        "candidateRejectReasonTopList",
        "lookaheadExhausted",
        "resourceReadinessAffectedFallback",
        "controlBarAffectedFallback",
        "legacyRendererUsedForSmartFillFallback",
        "fallbackRootCauseBucket",
        "currentAssetDisposition",
        "currentAssetRef",
        "currentAssetAbsentReason",
        "currentAssetSlotAreaRatio",
        "currentAssetCropRetention",
        "currentAssetProtectedRegionCoverage",
        "currentAssetFaceProtectionPassed",
        "currentAssetSubjectProtectionPassed",
        "currentAssetVisibleQualityClass",
        "cropRetentionThresholdUsed",
        "slotRoles",
        "slotRefs",
        "candidateWindowRequested",
        "candidateWindowUsed",
        "candidateWindowExpansionTrace",
        "acceptedSceneSearchTier",
        "recentVisibleLimit",
        "recentVisibleCandidateCount",
        "duplicateVisibleSlotCount",
        "duplicateVisibleSlotRefs",
        "duplicateReuseReason",
        "multiSlotSuccessCount",
        "smartFillSingleFillCount",
        "singleRiskCount",
        "hardFallbackCount",
        "nonMultiSlotOutcomeCount",
        "userPerceivedFailureCount",
        "currentAssetAbsentSceneCount",
        "visualUnverifiedCount",
        "unknownOutcomeBucketCount",
        "visualReviewStatus"
    ]
    static let requiredHarnessSummaryFields = [
        "startupRunId",
        "startupClockSource",
        "harnessPhaseTimestampsMs",
        "harnessPhaseDurationsMs",
        "harnessCollectionToFirstManifestObservedMs",
        "harnessCollectionToFirstNonLoadingScreenshotMs",
        "crossClockSummaryPolicy"
    ]
    static let requiredSummaryFields = [
        "sceneType",
        "fallback",
        "fallbackCategory",
        "layoutVariant",
        "ratioPreset",
        "surfaceKey",
        "surfaceFingerprint",
        "photoCanvasId",
        "photoCanvasPointSize",
        "photoCanvasPixelSize",
        "canvasCoverage",
        "emptyCanvasRatio",
        "maxContinuousEmptyAxisRatio",
        "gapPixelCount",
        "overlapPixelCount",
        "slotCount",
        "slotRoles",
        "slotRefs",
        "currentAssetDisposition",
        "currentAssetAbsentReason",
        "currentAssetSlotAreaRatio",
        "currentAssetCropRetention",
        "currentAssetProtectedRegionCoverage",
        "currentAssetFaceProtectionPassed",
        "currentAssetSubjectProtectionPassed",
        "currentAssetVisibleQualityClass",
        "acceptedSceneSearchTier",
        "candidateWindowRequested",
        "candidateWindowExpansionTrace",
        "slotFrames",
        "slotCropRects",
        "slotReadiness",
        "ledgerSceneAssets",
        "controlBarVisible",
        "controlBarHardRejected",
        "controlBarSubjectOverlapWarningCount",
        "exifOverlayVisible",
        "exifOverlayHardRejected",
        "publishReason",
        "preparedHit",
        "rejectedLayoutDiagnostics",
        "protectionOverlapDetails"
    ]

    static func sceneIdHash(rawManifest: String, scenario: String, sequence: Int) -> String {
        let input = "\(scenario)|\(sequence)|\(rawManifest)"
        return stableHash(input).prefix(16).description
    }
}

enum SmartFillFallbackEvidencePolicy {
    static let forbiddenCategories: Set<String> = [
        "controlbar-triggered",
        "exif-triggered",
        "pending-resource-triggered",
        "recovery-fallback",
        "unknown"
    ]

    static func distribution(from categories: [String]) -> [String: Int] {
        Dictionary(grouping: categories) { category in
            category.isEmpty ? "missing" : category
        }
        .mapValues(\.count)
    }

    static func forbiddenDistribution(from distribution: [String: Int]) -> [String: Int] {
        distribution.filter { forbiddenCategories.contains($0.key) }
    }

    static func format(_ distribution: [String: Int]) -> String {
        distribution
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }
}

func requireEvidenceWrite(_ write: () throws -> Void) {
    do {
        try write()
    } catch {
        XCTFail("Failed to write SmartFill evidence: \(error.localizedDescription)")
    }
}

#if os(iOS)
final class PlaybackSmartFillVisualUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testScreenshotWriterRejectsUnwritableDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedFile = directory.appendingPathComponent("blocked.png")
        try FileManager.default.createDirectory(at: blockedFile, withIntermediateDirectories: true)

        XCTAssertNil(SmartFillRuntimeEvidenceSupport.writeScreenshotPNG(Data([1, 2, 3]), to: blockedFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedFile.path, isDirectory: nil))
    }

    func testScreenshotWriterReturnsReadableFileOnSuccess() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let bytes = Data([1, 2, 3])

        XCTAssertEqual(SmartFillRuntimeEvidenceSupport.writeScreenshotPNG(bytes, to: fileURL), fileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    @MainActor
    func testSmartFillRandomPlaybackTwentyScenes() throws {
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "random")
        assertPolicies(in: evidence, contain: "portrait", scenario: "random playback, portrait")
        assertSurfaces(in: evidence, orientation: .portrait, scenario: "random playback, portrait")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "random playback, portrait")
    }

    @MainActor
    func testSmartFillMotionRealAutoplayFullProductEvidence() throws {
        let scenario = smartFillMotionScenarioName(
            defaultScenario: "iphone-5sec-interval-any-iphone-real-autoplay-full-product"
        )
        let app = try launchSmartFillMotionEvidenceAppAtModeSelection(
            scenario: scenario,
            shouldForceAutoplayOff: false,
            shouldEnableSmartFillMotionTrace: true
        )
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(12))) {
                !app.buttons["slideshow.control.settings.button"].exists
            },
            "\(scenario) control bar must auto-hide before sampling so clean stable-visible segments are not polluted by the overlay"
        )

        let traceStartTimeout = smartFillMotionTraceStartTimeoutSeconds()
        let initialManifest = try waitForCurrentManifest(
            app: app,
            timeout: TestWait.seconds(.infrastructure(max(45, traceStartTimeout + 5)))
        )
        var acceptedSlotRefs = Set<String>()
        if initialManifest.sceneType == "double" || initialManifest.sceneType == "triple" {
            acceptedSlotRefs.insert(initialManifest.slotRefs)
        }
        let sampleDuration = smartFillMotionSampleDurationSeconds()
        let traceText = try appSmartFillMotionTraceText(
            app: app,
            timeout: TestWait.seconds(.infrastructure(sampleDuration + traceStartTimeout + 30)),
        )
        let rows = motionFrameRows(
            fromTraceText: traceText,
            fallbackManifest: initialManifest
        )
        let productRows = productSceneSequenceRows(
            fromTraceText: traceText,
            fallbackManifest: initialManifest
        )
        for row in rows {
            let slotRefs =
                row.fields["manifestSlotRefs"]?.replacingOccurrences(of: "|", with: ",") ?? row.manifestSlotRefs
            let sceneType = row.fields["manifestSceneType"] ?? row.manifestSceneType
            if sceneType == "double" || sceneType == "triple" {
                acceptedSlotRefs.insert(slotRefs)
            }
        }
        if let latest = currentManifest(app: app),
            latest.sceneType == "double" || latest.sceneType == "triple"
        {
            acceptedSlotRefs.insert(latest.slotRefs)
        }

        writeProductSceneSequenceEvidence(productRows, motionRows: rows, scenario: scenario)
        writeMotionFrameEvidence(rows, scenario: scenario)
        let productSceneTypes = Set(productRows.map(\.manifestSceneType))
        let motionCoveredSceneTypes = Set(["double", "triple", "single"])
        let visibleUncoveredMotionSceneTypes =
            productSceneTypes
            .subtracting(motionCoveredSceneTypes)
            .sorted()
        let cleanAvailableMotionSceneTypes = Set(
            rows.compactMap { row -> String? in
                guard row.fields["progressFrameStatus"] == "available",
                    row.fields["controlBarVisible"] == "false",
                    row.fields["appOverlayPollution"] == "none"
                else {
                    return nil
                }
                return row.manifestSceneType
            })
        let coveredSceneTypesMissingCleanMotionRows =
            productSceneTypes
            .intersection(motionCoveredSceneTypes)
            .subtracting(cleanAvailableMotionSceneTypes)
            .sorted()
        let productTransitionRows = productRows.filter { row in
            row.productTransitionFields["productTransitionActive"] == "true"
        }
        let productTransitionRowsWithoutBacking = productTransitionRows.filter { row in
            row.productTransitionFields["productBlackBackingActive"] != "true"
        }
        let availableRows = rows.filter { row in
            row.fields["progressFrameStatus"] == "available"
        }
        XCTAssertFalse(
            productRows.isEmpty, "\(scenario) must capture the full continuous product playback sceneType sequence")
        XCTAssertFalse(
            productTransitionRows.isEmpty, "\(scenario) product sequence must cover at least one real transition")
        XCTAssertTrue(
            productTransitionRowsWithoutBacking.isEmpty,
            "\(scenario) every product SmartFill transition must enable the black backing")
        XCTAssertTrue(
            visibleUncoveredMotionSceneTypes.isEmpty,
            "\(scenario) VISUAL_GAP: the full product sequence shows visible sceneTypes without runtime motion: \(visibleUncoveredMotionSceneTypes)"
        )
        XCTAssertTrue(
            coveredSceneTypesMissingCleanMotionRows.isEmpty,
            "\(scenario) VISUAL_GAP: visible sceneTypes the manifest declares covered lack a clean available motion row: \(coveredSceneTypesMissingCleanMotionRows)"
        )
        XCTAssertTrue(
            productSceneTypes.contains("double") || productSceneTypes.contains("triple"),
            "\(scenario) product sequence must still include an accepted SmartFill scene"
        )
        XCTAssertGreaterThanOrEqual(
            acceptedSlotRefs.count, 2, "\(scenario) real autoplay must show at least two accepted SmartFill scenes")
        XCTAssertFalse(rows.isEmpty, "\(scenario) must capture motion frame probes")
        XCTAssertFalse(
            availableRows.isEmpty, "\(scenario) motion frame probes must include an available progress frame")
        _ = captureRuntimeScreenshot(
            app: app,
            name: "smartfill-\(scenario)-\(deviceTag())-final",
            shouldAttachToXCTest: true
        )
    }

    @MainActor
    func testSmartFillMotionInteractionLivenessEvidence() throws {
        let scenario = smartFillMotionScenarioName(
            defaultScenario: "iphone-5sec-interval-any-iphone-interaction-liveness"
        )
        let app = try launchSmartFillMotionEvidenceAppAtModeSelection(
            scenario: scenario,
            shouldForceAutoplayOff: false,
            shouldEnableSmartFillMotionTrace: true
        )
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(12))) {
                !app.buttons["slideshow.control.settings.button"].exists
            },
            "\(scenario) control bar must auto-hide before interaction sampling so the initial overlay is not taken for interaction noise"
        )
        let initialManifest = try waitForCurrentManifest(
            app: app,
            timeout: TestWait.seconds(.infrastructure(max(45, smartFillMotionTraceStartTimeoutSeconds() + 5)))
        )
        let traceReferenceTime = try waitForSmartFillMotionTraceCollecting(
            app: app,
            timeout: TestWait.seconds(.infrastructure(smartFillMotionTraceStartTimeoutSeconds() + 10))
        )
        var actions: [[String: Any]] = []
        func recordAction(_ action: String) {
            let elapsedSeconds = TestWait.seconds(
                .product(max(0, ProcessInfo.processInfo.systemUptime - traceReferenceTime)))
            actions.append([
                "action": action,
                "elapsedSeconds": elapsedSeconds,
                "timestamp": SmartFillRuntimeEvidenceSupport.captureTimestamp()
            ])
        }

        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(1.0))))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        recordAction("tap-image-show-control-bar")
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: TestWait.seconds(.product(4))),
            "\(scenario) tapping the photo must show the control bar"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(1.5))))
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: TestWait.seconds(.product(4))),
            "\(scenario) pause/resume button must be found while the control bar is visible"
        )
        tapElement(playPauseButton)
        recordAction("pause")

        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(1.2))))
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: TestWait.seconds(.product(4))),
            "\(scenario) resume button must still be found after pause"
        )
        tapElement(playPauseButton)
        recordAction("resume")

        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(10))) {
                !settingsButton.exists
            },
            "\(scenario) control bar must auto-hide after pause/resume"
        )
        recordAction("control-bar-auto-hidden")
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(2.5))))

        let traceText = try appSmartFillMotionTraceText(
            app: app,
            timeout: TestWait.seconds(
                .infrastructure(smartFillMotionSampleDurationSeconds() + smartFillMotionTraceStartTimeoutSeconds() + 30)
            ),
        )
        let rows = motionFrameRows(
            fromTraceText: traceText,
            fallbackManifest: initialManifest
        )
        let productRows = productSceneSequenceRows(
            fromTraceText: traceText,
            fallbackManifest: initialManifest
        )
        let availableRows = rows.filter { row in
            row.fields["progressFrameStatus"] == "available"
        }
        let controlBarVisibleRows = rows.filter { row in
            row.fields["controlBarVisible"] == "true" && row.fields["progressFrameStatus"] == "available"
        }
        let controlBarHiddenRowsAfterAction = rows.filter { row in
            guard let elapsed = Double(row.fields["elapsedSeconds"] ?? ""),
                let hiddenAction = actions.first(where: { $0["action"] as? String == "control-bar-auto-hidden" }),
                let hiddenElapsed = hiddenAction["elapsedSeconds"] as? Double
            else {
                return false
            }
            return elapsed >= hiddenElapsed && row.fields["controlBarVisible"] == "false"
                && row.fields["progressFrameStatus"] == "available"
        }

        writeProductSceneSequenceEvidence(productRows, motionRows: rows, scenario: scenario)
        writeMotionFrameEvidence(rows, scenario: scenario)
        writeInteractionActionEvidence(actions, scenario: scenario)

        XCTAssertFalse(rows.isEmpty, "\(scenario) must capture motion frame probes")
        XCTAssertFalse(
            availableRows.isEmpty, "\(scenario) motion frame probes must include an available progress frame")
        XCTAssertFalse(
            controlBarVisibleRows.isEmpty,
            "\(scenario) available motion rows must continue while the control bar is visible")
        XCTAssertFalse(
            controlBarHiddenRowsAfterAction.isEmpty,
            "\(scenario) available motion rows must continue after the control bar auto-hides")
        XCTAssertTrue(
            actions.map { $0["action"] as? String }.contains("pause")
                && actions.map { $0["action"] as? String }.contains("resume"),
            "\(scenario) must record the pause/resume interaction"
        )
        _ = captureRuntimeScreenshot(
            app: app,
            name: "smartfill-\(scenario)-\(deviceTag())-final",
            shouldAttachToXCTest: true
        )
    }

    @MainActor
    func testPlaybackTransitionAnimationEvidenceSmartFillQuickSwitch() throws {
        try runPlaybackTransitionAnimationEvidence(
            shouldDisableSmartFill: false,
            scenario: "iphone-smartfill"
        )
    }

    @MainActor
    func testPlaybackTransitionAnimationEvidenceSinglePhotoQuickSwitch() throws {
        try runPlaybackTransitionAnimationEvidence(
            shouldDisableSmartFill: true,
            scenario: "iphone-single-photo"
        )
    }

    @MainActor
    func testPlaybackTransitionExifPresenceEvidenceSmartFillEdges() throws {
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)

        let scenario = "iphone-smartfill-exif-presence"
        var previousManifest = try waitForCurrentManifest(app: app, timeout: TestWait.seconds(.infrastructure(45)))
        var isPreviousVisible = isExifOverlayVisible(in: previousManifest)
        saveEvidenceScreenshot(
            app: app,
            scenario: scenario,
            step: "00-start-visible-\(isPreviousVisible)"
        )

        var coverage = ExifPresenceEdgeCoverage()
        let maximumAttempts = 60
        let midTransitionDelay: TimeInterval = TestWait.seconds(.product(0.14))
        let settledDelay: TimeInterval = TestWait.seconds(.product(0.55))

        for attempt in 1...maximumAttempts where !coverage.isComplete {
            let previousRefs = previousManifest.slotRefs
            tapNext(app: app)

            var currentManifest = previousManifest
            _ = waitUntil(timeout: TestWait.seconds(.product(10))) {
                guard let nextManifest = self.currentManifest(app: app) else { return false }
                currentManifest = nextManifest
                return nextManifest.slotRefs != previousRefs
            }

            let isCurrentVisible = isExifOverlayVisible(in: currentManifest)
            let transitionLabel = "\(isPreviousVisible)-to-\(isCurrentVisible)"
            switch coverage.observeTransition(from: isPreviousVisible, to: isCurrentVisible) {
            case .appear:
                RunLoop.current.run(until: Date().addingTimeInterval(midTransitionDelay))
                saveEvidenceScreenshot(app: app, scenario: scenario, step: "\(attempt)-appear-mid-\(transitionLabel)")
                RunLoop.current.run(until: Date().addingTimeInterval(settledDelay))
                saveEvidenceScreenshot(
                    app: app, scenario: scenario, step: "\(attempt)-appear-settled-\(transitionLabel)")
            case .disappear:
                RunLoop.current.run(until: Date().addingTimeInterval(midTransitionDelay))
                saveEvidenceScreenshot(
                    app: app, scenario: scenario, step: "\(attempt)-disappear-mid-\(transitionLabel)")
                RunLoop.current.run(until: Date().addingTimeInterval(settledDelay))
                saveEvidenceScreenshot(
                    app: app, scenario: scenario, step: "\(attempt)-disappear-settled-\(transitionLabel)")
            case nil:
                break
            }

            previousManifest = currentManifest
            isPreviousVisible = isCurrentVisible
        }

        guard coverage.isComplete else {
            XCTFail(
                """
                SmartFill EXIF overlay presence runtime evidence is incomplete: \(coverage.missingEdgeDescription).
                Sampled \(maximumAttempts) random switches on the real server without observing the target edge; the server needs photos both with and without an EXIF overlay.
                """
            )
            return
        }
        XCTAssertTrue(
            app.buttons["slideshow.control.next.button"].waitForExistence(timeout: TestWait.seconds(.product(4))),
            "Control bar should still work after the EXIF overlay appear/disappear check"
        )
    }

    func testExifPresenceEdgeCoverageRequiresAppearAndDisappear() throws {
        var coverage = ExifPresenceEdgeCoverage()

        XCTAssertEqual(
            coverage.observeTransition(from: false, to: true),
            .appear
        )
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(
            coverage.missingEdgeDescription,
            "Missing smooth EXIF overlay disappearance: single photo with EXIF → multi-photo without EXIF"
        )

        XCTAssertEqual(
            coverage.observeTransition(from: true, to: false),
            .disappear
        )
        XCTAssertTrue(coverage.isComplete)
        XCTAssertEqual(coverage.missingEdgeDescription, "")
    }

    func testExifPresenceEdgeCoverageIgnoresNoChangeTransitions() throws {
        var coverage = ExifPresenceEdgeCoverage()

        XCTAssertNil(coverage.observeTransition(from: false, to: false))
        XCTAssertNil(coverage.observeTransition(from: true, to: true))
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(
            coverage.missingEdgeDescription,
            "Missing smooth EXIF overlay appearance: multi-photo without EXIF → single photo with EXIF; Missing smooth EXIF overlay disappearance: single photo with EXIF → multi-photo without EXIF"
        )
    }

    @MainActor
    func testSmartFillRandomLandscapePlaybackTwentyScenes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "random-landscape")
        assertPolicies(in: evidence, contain: "landscape", scenario: "random playback, landscape")
        assertSurfaces(in: evidence, orientation: .landscape, scenario: "random playback, landscape")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "random playback, landscape")
    }

    @MainActor
    func testSmartFillPeopleFilterPlaybackTwentyScenes() async throws {
        let personID = try await findEligiblePersonID(minimumAssetCount: EvidenceCalibration.minimumPersonAssetCount)
        let selectionJSON = makePersonFilterSelectionJSON(personID: personID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "people-filter")
        assertPolicies(in: evidence, contain: "portrait", scenario: "people filter, portrait")
        assertSurfaces(in: evidence, orientation: .portrait, scenario: "people filter, portrait")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "people filter, portrait")
    }

    @MainActor
    func testSmartFillPeopleFilterLandscapePlaybackTwentyScenes() async throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let personID = try await findEligiblePersonID(minimumAssetCount: EvidenceCalibration.minimumPersonAssetCount)
        let selectionJSON = makePersonFilterSelectionJSON(personID: personID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "people-filter-landscape")
        assertPolicies(in: evidence, contain: "landscape", scenario: "people filter, landscape")
        assertSurfaces(in: evidence, orientation: .landscape, scenario: "people filter, landscape")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "people filter, landscape")
    }

    @MainActor
    func testSmartFillFixedAlbumPlaybackTwentyScenes() throws {
        let albumID = try requireFixedAlbumID()
        let selectionJSON = makeAlbumFilterSelectionJSON(albumID: albumID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "fixed-album")
        assertPolicies(in: evidence, contain: "portrait", scenario: "fixed album, portrait")
        assertSurfaces(in: evidence, orientation: .portrait, scenario: "fixed album, portrait")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "fixed album, portrait")
    }

    @MainActor
    func testSmartFillFixedAlbumLandscapePlaybackTwentyScenes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let albumID = try requireFixedAlbumID()
        let selectionJSON = makeAlbumFilterSelectionJSON(albumID: albumID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectSceneEvidence(app: app, scenario: "fixed-album-landscape")
        assertPolicies(in: evidence, contain: "landscape", scenario: "fixed album, landscape")
        assertSurfaces(in: evidence, orientation: .landscape, scenario: "fixed album, landscape")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "fixed album, landscape")
    }

    @MainActor
    func testRandomPlaybackSwitchWorkloadTwentyScenesWithSmartFillDisabled() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldDisableSmartFill: true)
        startRandomPlaybackFromModeSelection(app: app)

        try exerciseTwentySceneSwitches(app: app, scenario: "cpu-baseline")
    }

    @MainActor
    func testRandomPlaybackSwitchWorkloadTwentyScenesWithSmartFillEnabled() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldDisableSmartFill: false)
        startRandomPlaybackFromModeSelection(app: app)

        try exerciseTwentySceneSwitches(app: app, scenario: "cpu-smartfill")
    }
}

#endif

#if os(tvOS)

extension Array where Element == Dictionary<String, Any> {
    func containsAction(_ name: String) -> Bool {
        contains { $0["action"] as? String == name }
    }
}
#endif
