import Foundation
import XCTest

#if os(iOS)
extension PlaybackSmartFillVisualUITests {
    func parseManifest(_ raw: String) -> SmartFillManifest? {
        guard raw.contains("version=smart-fill-planner-v2") else { return nil }
        let fields = Dictionary(
            uniqueKeysWithValues: raw.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                let key = String(part[..<equalIndex])
                let value = String(part[part.index(after: equalIndex)...])
                return (key, value)
            }
        )
        guard SmartFillRuntimeEvidenceSupport.requiredSummaryFields.allSatisfy({ fields[$0] != nil }),
            let sceneType = fields["sceneType"],
            let policy = fields["policy"],
            let rawSlotCount = fields["slotCount"],
            let slotCount = Int(rawSlotCount),
            let fallback = fields["fallback"],
            let fallbackCategory = fields["fallbackCategory"],
            let slotRefs = fields["slotRefs"],
            let rejects = fields["rejects"],
            let surfaceKey = fields["surfaceKey"],
            let surface = parseSurfaceKey(surfaceKey),
            let slotFrames = fields["slotFrames"],
            let layoutVariant = fields["layoutVariant"],
            let ratioPreset = fields["ratioPreset"],
            let cropRetention = fields["cropRetention"],
            let protectionContained = fields["protectionContained"],
            let rawCandidateWindowUsed = fields["candidateWindowUsed"],
            let candidateWindowUsed = Int(rawCandidateWindowUsed),
            let rawEvaluationCount = fields["evaluationCount"],
            let evaluationCount = Int(rawEvaluationCount),
            let rotationStartLayoutVariant = fields["rotationStartLayoutVariant"],
            let rotationStartRatioPreset = fields["rotationStartRatioPreset"],
            let acceptedLayoutVariant = fields["acceptedLayoutVariant"],
            let acceptedRatioPreset = fields["acceptedRatioPreset"],
            let rotationKeyHashPrefix = fields["rotationKeyHashPrefix"],
            let rejectedLayoutReasonTopList = fields["rejectedLayoutReasonTopList"]
        else {
            return nil
        }
        return SmartFillManifest(
            raw: raw,
            rawFields: fields,
            sceneType: sceneType,
            policy: policy,
            slotCount: slotCount,
            fallback: fallback,
            fallbackCategory: fallbackCategory,
            slotRefs: slotRefs,
            rejects: rejects,
            surfaceKey: surfaceKey,
            surfaceProfile: surface.profile,
            surfaceOrientation: surface.orientation,
            slotFrames: slotFrames,
            layoutVariant: layoutVariant,
            ratioPreset: ratioPreset,
            cropRetention: cropRetention,
            protectionContained: protectionContained,
            candidateWindowUsed: candidateWindowUsed,
            evaluationCount: evaluationCount,
            rotationStartLayoutVariant: rotationStartLayoutVariant,
            rotationStartRatioPreset: rotationStartRatioPreset,
            acceptedLayoutVariant: acceptedLayoutVariant,
            acceptedRatioPreset: acceptedRatioPreset,
            rotationKeyHashPrefix: rotationKeyHashPrefix,
            rejectedLayoutReasonTopList: rejectedLayoutReasonTopList
        )
    }

    func makeRuntimeManifestForTesting() -> String {
        [
            "version=smart-fill-planner-v2",
            "sceneType=double",
            "surfaceKey=iPhone-landscape-regular-compact-safeA",
            "surfaceFingerprint=iPhone-landscape-393x852-safeA",
            "policy=iphone-landscape-v2",
            "layoutVariant=horizontal-equal",
            "ratioPreset=50/50",
            "photoCanvasId=canvas-iphone-landscape",
            "photoCanvasPointSize=852.000x393.000",
            "photoCanvasPixelSize=2556x1179",
            "canvasCoverage=1.000",
            "emptyCanvasRatio=0.000",
            "maxContinuousEmptyAxisRatio=0.000",
            "gapPixelCount=0",
            "overlapPixelCount=0",
            "slotCount=2",
            "slotRoles=primary,secondary",
            "slotRefs=asset-1111,asset-2222",
            "currentAssetDisposition=primary-slot",
            "currentAssetAbsentReason=none",
            "currentAssetSlotAreaRatio=0.500",
            "currentAssetCropRetention=0.900",
            "currentAssetProtectedRegionCoverage=1.000",
            "currentAssetFaceProtectionPassed=true",
            "currentAssetSubjectProtectionPassed=true",
            "currentAssetVisibleQualityClass=acceptable",
            "cropRetentionThresholdUsed=0.600",
            "acceptedSceneSearchTier=double",
            "candidateWindowRequested=24",
            "candidateWindowExpansionTrace=24:accepted",
            "slotFrames=x0.000y0.000w0.500h1.000,x0.500y0.000w0.500h1.000",
            "slotCropRects=x0.000y0.000w1.000h1.000,x0.000y0.000w1.000h1.000",
            "cropRetention=0.900,0.850",
            "protectionContained=true,true",
            "controlBarHardRejected=false",
            "controlBarSubjectOverlapWarningCount=0",
            "exifOverlayHardRejected=false",
            "fallbackCategory=none",
            "candidateWindowUsed=24",
            "evaluationCount=4",
            "rotationStartLayoutVariant=horizontal-equal",
            "rotationStartRatioPreset=50/50",
            "acceptedLayoutVariant=horizontal-equal",
            "acceptedRatioPreset=50/50",
            "rotationKeyHashPrefix=abc12345",
            "fallback=none",
            "rejects=none",
            "rejectedLayoutReasonTopList=none",
            "rejectedLayoutDiagnostics=none",
            "slotReadiness=ready,pending",
            "ledgerSceneAssets=asset-1111,asset-2222",
            "controlBarVisible=true",
            "exifOverlayVisible=false",
            "publishReason=manualNext",
            "preparedHit=true",
            "actionToSceneLatencyMs=25.000"
        ].joined(separator: ";")
    }

    func makeStartupRuntimeManifestForTesting(overrides: [String: String] = [:]) -> String {
        var baseFields = makeRuntimeManifestForTesting()
            .split(separator: ";")
            .reduce(into: [String: String]()) { result, part in
                let entry = String(part)
                guard let equalIndex = entry.firstIndex(of: "=") else { return }
                let key = String(entry[..<equalIndex])
                let value = String(entry[entry.index(after: equalIndex)...])
                result[key] = value
            }
        var fields = [
            "runtimePhaseTimestampsMs":
                "playbackEntryRequested:0,assetPoolRequestStarted:8,assetPoolReady:24,firstScenePlanningStarted:31,firstScenePlanned:45,firstScenePublished:60,firstSlotReady:82,allVisibleSlotsReady:96",
            "runtimePhaseDurationsMs":
                "playbackEntryRequested:0,assetPoolRequestStarted:8,assetPoolReady:16,firstScenePlanningStarted:7,firstScenePlanned:14,firstScenePublished:15,firstSlotReady:22,allVisibleSlotsReady:14",
            "assetPoolSizeAtFirstPlan": "36",
            "eligibleCandidateCountAtFirstPlan": "24",
            "plannerAttemptCountAtFirstPlan": "4",
            "candidateWindowUsedAtFirstPlan": "12",
            "firstSceneSlotReadiness": "ready,pending",
            "photoLoadPhaseTimestampsMs":
                "cacheChecked:70,downloadRequestStarted:72,downloadCompleted:96,decodeCompleted:100,firstImageDisplayed:104",
            "photoLoadPhaseDurationsMs":
                "cacheChecked:0,downloadRequestStarted:2,downloadCompleted:24,decodeCompleted:4,firstImageDisplayed:4",
            "firstPhotoCacheStatus": "miss",
            "firstImageDisplayedRuntimeMs": "104",
            "firstImageLoadStatus": "displayed",
            "fallbackReasonTopList": "none",
            "rejectedLayoutDiagnostics": "none",
            "candidateRejectReasonTopList": "none",
            "protectionOverlapDetails": "none",
            "lookaheadExhausted": "false",
            "resourceReadinessAffectedFallback": "false",
            "controlBarAffectedFallback": "false",
            "legacyRendererUsedForSmartFillFallback": "false",
            "fallbackRootCauseBucket": "none"
        ]
        for (key, value) in overrides {
            fields[key] = value
        }
        for (key, value) in fields {
            baseFields[key] = value
        }
        return
            baseFields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    func parseSurfaceKey(_ raw: String) -> (profile: String, orientation: String)? {
        let parts = raw.split(separator: "-")
        guard parts.count >= 2 else {
            return nil
        }
        return (String(parts[0]), String(parts[1]))
    }

    func assertManifestIsRedacted(_ manifest: String) {
        let lowercased = manifest.lowercased()
        XCTAssertFalse(lowercased.contains("http://"))
        XCTAssertFalse(lowercased.contains("https://"))
        XCTAssertFalse(lowercased.contains("api_key"))
        XCTAssertFalse(lowercased.contains("api key"))
        XCTAssertFalse(lowercased.contains("token"))
        XCTAssertFalse(lowercased.contains("base64"))
    }

    func assertManifestMeetsSpecGates(_ manifest: SmartFillManifest, scenario: String, index: Int) {
        XCTAssertFalse(manifest.layoutVariant.isEmpty, "\(scenario) frame \(index + 1) should record layoutVariant")
        XCTAssertFalse(manifest.ratioPreset.isEmpty, "\(scenario) frame \(index + 1) should record ratioPreset")
        XCTAssertFalse(
            manifest.rotationKeyHashPrefix.isEmpty, "\(scenario) frame \(index + 1) should record rotationKeyHashPrefix"
        )
        XCTAssertGreaterThan(
            manifest.candidateWindowUsed, 0, "\(scenario) frame \(index + 1) should record candidateWindowUsed")
        XCTAssertGreaterThanOrEqual(
            manifest.evaluationCount, 0, "\(scenario) frame \(index + 1) should record evaluationCount")

        if manifest.surfaceProfile == "iPhone" {
            XCTAssertNotEqual(
                manifest.sceneType, "triple", "\(scenario) frame \(index + 1): iPhone does not allow triple")
        }

        guard manifest.sceneType != "fallback" else { return }
        let retentions = manifest.cropRetention
            .split(separator: ",")
            .compactMap { Double($0) }
        XCTAssertEqual(
            retentions.count,
            manifest.slotCount,
            "\(scenario) frame \(index + 1) should record cropRetention for every slot"
        )
        let cropRetentionThreshold = cropRetentionThreshold(for: manifest)
        let thresholdLabel = String(format: "%.0f%%", cropRetentionThreshold * 100)
        XCTAssertTrue(
            retentions.allSatisfy { $0 >= cropRetentionThreshold },
            "\(scenario) frame \(index + 1): cropRetention of every accepted slot should be >= \(thresholdLabel)"
        )
        let protectionValues = manifest.protectionContained.split(separator: ",").map(String.init)
        XCTAssertEqual(
            protectionValues.count,
            manifest.slotCount,
            "\(scenario) frame \(index + 1) should record protectionContained for every slot"
        )
        XCTAssertTrue(
            protectionValues.allSatisfy { $0 == "true" },
            "\(scenario) frame \(index + 1): every accepted slot should fully contain its protected region"
        )
    }

    func cropRetentionThreshold(for manifest: SmartFillManifest) -> Double {
        Double(manifest.rawFields["cropRetentionThresholdUsed"] ?? "") ?? EvidenceCalibration.cropRetentionThreshold
    }

    func attachManifestSummary(_ manifests: [SmartFillManifest], scenario: String) {
        let fallbackDistribution = SmartFillFallbackEvidencePolicy.format(
            SmartFillFallbackEvidencePolicy.distribution(from: manifests.map(\.fallbackCategory))
        )
        let summary =
            ([
                "fallbackDistribution=\(fallbackDistribution)"
            ]
            + manifests.enumerated().map { index, manifest in
                [
                    "index=\(index + 1)",
                    "sceneType=\(manifest.sceneType)",
                    "policy=\(manifest.policy)",
                    "layoutVariant=\(manifest.layoutVariant)",
                    "ratioPreset=\(manifest.ratioPreset)",
                    "slotCount=\(manifest.slotCount)",
                    "fallback=\(manifest.fallback)",
                    "fallbackCategory=\(manifest.fallbackCategory)",
                    "rejects=\(manifest.rejects)",
                    "rejectedLayoutReasonTopList=\(manifest.rejectedLayoutReasonTopList)",
                    "surfaceKey=\(manifest.surfaceKey)",
                    "surfaceProfile=\(manifest.surfaceProfile)",
                    "surfaceOrientation=\(manifest.surfaceOrientation)",
                    "slotFrames=\(manifest.slotFrames)",
                    "cropRetention=\(manifest.cropRetention)",
                    "protectionContained=\(manifest.protectionContained)",
                    "candidateWindowUsed=\(manifest.candidateWindowUsed)",
                    "evaluationCount=\(manifest.evaluationCount)",
                    "rotationStartLayoutVariant=\(manifest.rotationStartLayoutVariant)",
                    "rotationStartRatioPreset=\(manifest.rotationStartRatioPreset)",
                    "acceptedLayoutVariant=\(manifest.acceptedLayoutVariant)",
                    "acceptedRatioPreset=\(manifest.acceptedRatioPreset)",
                    "rotationKeyHashPrefix=\(manifest.rotationKeyHashPrefix)",
                    "slotRefs=\(manifest.slotRefs)"
                ].joined(separator: ";")
            }).joined(separator: "\n")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "smartfill-\(scenario)-manifest-\(deviceTag())"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func assertPolicies(in evidence: SmartFillEvidence, contain expectedFragment: String, scenario: String) {
        XCTAssertTrue(
            evidence.manifests.allSatisfy { $0.policy.contains(expectedFragment) },
            "\(scenario) should read back the \(expectedFragment) policy"
        )
    }

    func assertFallbackDistributionMeetsSpec(in evidence: SmartFillEvidence, scenario: String) {
        let forbiddenDistribution = evidence.forbiddenFallbackDistribution
        XCTAssertTrue(
            forbiddenDistribution.isEmpty,
            "\(scenario) forbidden fallback categories must be 0, forbidden distribution: \(SmartFillFallbackEvidencePolicy.format(forbiddenDistribution)), full distribution: \(SmartFillFallbackEvidencePolicy.format(evidence.fallbackDistribution))"
        )
    }

    func assertSurfaces(
        in evidence: SmartFillEvidence,
        orientation expectedOrientation: SmartFillSurfaceExpectation,
        scenario: String
    ) {
        let isExpectedOrientation: (SmartFillManifest) -> Bool = { manifest in
            switch expectedOrientation {
            case .portrait:
                return manifest.surfaceOrientation == "portrait"
            case .landscape:
                return manifest.surfaceOrientation == "landscape"
            }
        }
        XCTAssertTrue(
            evidence.manifests.allSatisfy(isExpectedOrientation),
            "\(scenario) should read back Smart Fill surface geometry matching the target orientation"
        )
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        _ = captureRuntimeScreenshot(app: app, name: name, shouldAttachToXCTest: true)
    }

    func captureRuntimeScreenshot(
        app: XCUIApplication,
        name: String,
        shouldAttachToXCTest: Bool
    ) -> (path: String, captureTimestamp: String)? {
        // In a landscape Simulator an app-element screenshot can keep the old window bounds,
        // so runtime evidence takes a full-screen screenshot.
        let screenshot = XCUIScreen.main.screenshot()
        if shouldAttachToXCTest {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        guard let directory = evidenceDirectory() else { return nil }
        let captureTimestamp = SmartFillRuntimeEvidenceSupport.captureTimestamp()
        let fileURL = directory.appendingPathComponent(sanitizedEvidenceFileName(name) + ".png")
        guard
            let writtenURL = SmartFillRuntimeEvidenceSupport.writeScreenshotPNG(
                screenshot.pngRepresentation,
                to: fileURL
            )
        else {
            XCTFail("SmartFill runtime PNG write or read-back failed: \(fileURL.lastPathComponent)")
            return nil
        }
        return (writtenURL.path, captureTimestamp)
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func saveEvidenceScreenshot(app: XCUIApplication, scenario: String, step: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(scenario)-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let evidenceDirectory = playbackTransitionEvidenceDirectory() else { return }
        do {
            let fileURL = evidenceDirectory.appendingPathComponent("\(scenario)-\(step).png")
            try screenshot.pngRepresentation.write(to: fileURL, options: .atomic)
        } catch {
            XCTFail("Cannot write runtime screenshot evidence")
        }
    }

    func playbackTransitionEvidenceDirectory() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let path = env["TEST_RUNNER_UI_TEST_EVIDENCE_DIR"] ?? env["UI_TEST_EVIDENCE_DIR"]
        do {
            return try PrivateEvidenceDirectory.resolve(
                rootPath: path,
                components: []
            )
        } catch {
            XCTFail(error.localizedDescription)
            return nil
        }
    }

    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func deviceTag() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iphone"
        case .pad:
            return "ipad"
        default:
            return UIDevice.current.model.replacingOccurrences(of: " ", with: "_").lowercased()
        }
    }

    func smartFillTargetSceneCount() -> Int {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["IMMICHSLIDES_SMARTFILL_SCENE_COUNT"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_SCENE_COUNT"]
        guard let rawValue,
            let count = Int(rawValue),
            count > 0
        else {
            return EvidenceCalibration.defaultSceneCount
        }
        return count
    }

    func shouldWaitForCompleteStartupRuntimePhases() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["IMMICHSLIDES_REQUIRE_STARTUP_PHASES"] == "1"
            || environment["TEST_RUNNER_IMMICHSLIDES_REQUIRE_STARTUP_PHASES"] == "1"
    }

    func screenshotSampleIndices(for sceneCount: Int) -> Set<Int> {
        guard sceneCount >= 10 else {
            return Set(0..<sceneCount)
        }
        return Set(
            (0..<10).map { sampleIndex in
                Int((Double(sampleIndex) * Double(sceneCount - 1) / 9.0).rounded())
            })
    }
}
#endif
