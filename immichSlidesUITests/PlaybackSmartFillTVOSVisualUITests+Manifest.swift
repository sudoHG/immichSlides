import Foundation
import XCTest

#if os(tvOS)
extension PlaybackSmartFillTVOSVisualUITests {
    func pressNext(app: XCUIApplication) {
        let nextButton = app.buttons["slideshow.control.next.button"]
        if !nextButton.exists {
            XCUIRemote.shared.press(.up)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        XCTAssertTrue(nextButton.waitForExistence(timeout: 6), "Apple TV playback page should show the Next button")

        for _ in 0..<6 {
            if nextButton.hasFocus { break }
            XCUIRemote.shared.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        if nextButton.hasFocus == false {
            for _ in 0..<6 {
                if nextButton.hasFocus { break }
                XCUIRemote.shared.press(.left)
                RunLoop.current.run(until: Date().addingTimeInterval(0.16))
            }
        }

        XCTAssertTrue(nextButton.hasFocus, "Apple TV playback page focus should move to the Next button")
        XCUIRemote.shared.press(.select)
    }

    func waitForCurrentManifest(app: XCUIApplication, timeout: TimeInterval) throws -> SmartFillManifest {
        guard waitUntil(timeout: timeout, condition: { self.currentManifest(app: app) != nil }) else {
            attachScreenshot(app: app, name: "smartfill-manifest-missing-appletv")
            throw SmartFillTVOSFailure.missingManifest
        }
        guard let manifest = currentManifest(app: app) else {
            throw SmartFillTVOSFailure.missingManifest
        }
        return manifest
    }

    func waitForCompleteStartupRuntimeManifest(
        app: XCUIApplication,
        initialManifest: SmartFillManifest,
        timeout: TimeInterval
    ) throws -> SmartFillManifest {
        var latestManifest = initialManifest
        _ = waitUntil(timeout: timeout) {
            guard let nextManifest = self.currentManifest(app: app) else { return false }
            latestManifest = nextManifest
            return self.hasCompleteStartupRuntimePhases(nextManifest)
        }
        XCTAssertTrue(
            hasCompleteStartupRuntimePhases(latestManifest),
            "Minimal runtime JSONL requires the first-frame manifest to include all startup runtime phases"
        )
        return latestManifest
    }

    func waitForScreenshotReadyManifest(
        app: XCUIApplication,
        initialManifest: SmartFillManifest,
        timeout: TimeInterval,
        scenario: String,
        index: Int
    ) throws -> SmartFillManifest {
        var latestManifest = initialManifest
        _ = waitUntil(timeout: timeout) {
            guard let nextManifest = self.currentManifest(app: app) else { return false }
            latestManifest = nextManifest
            return SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(
                manifestFields: nextManifest.rawFields
            )
        }
        XCTAssertTrue(
            SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(manifestFields: latestManifest.rawFields),
            "\(scenario) frame \(index + 1) must wait for images to be ready before the screenshot, current state: \(SmartFillRuntimeEvidenceSupport.screenshotEvidenceReadinessReason(manifestFields: latestManifest.rawFields))"
        )
        return latestManifest
    }

    func hasCompleteStartupRuntimePhases(_ manifest: SmartFillManifest) -> Bool {
        guard let timestamps = manifest.rawFields["runtimePhaseTimestampsMs"],
            let durations = manifest.rawFields["runtimePhaseDurationsMs"]
        else {
            return false
        }
        return SmartFillRuntimeEvidenceSupport.requiredRuntimePhaseKeys.allSatisfy { phase in
            timestamps.contains("\(phase):") && durations.contains("\(phase):")
        }
    }

    func currentManifest(app: XCUIApplication) -> SmartFillManifest? {
        let probe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        guard probe.exists else { return nil }
        return parseManifest(probe.label.trimmingCharacters(in: .whitespacesAndNewlines))
    }

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
        attachment.name = "smartfill-\(scenario)-manifest-appletv"
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

    func assertSurfacesAreLandscape(in evidence: SmartFillEvidence, scenario: String) {
        XCTAssertTrue(
            evidence.manifests.allSatisfy {
                $0.surfaceOrientation == "landscape" && $0.surfaceProfile == "appleTV"
            },
            "\(scenario) should read back Apple TV landscape Smart Fill surface geometry"
        )
    }

    func makePersonFilterSelectionJSON(personID: String) -> String {
        let object: [String: Any] = [
            "albumIds": [],
            "personFilters": [
                [
                    "personId": personID,
                    "matchMode": "normal"
                ]
            ],
            "tagIds": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    func makeAlbumFilterSelectionJSON(albumID: String) -> String {
        let object: [String: Any] = [
            "albumIds": [albumID],
            "personFilters": [],
            "tagIds": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    func requireFixedAlbumID() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID"]
        guard let albumID = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !albumID.isEmpty
        else {
            throw XCTSkip("Fixed-album Smart Fill UI acceptance requires IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID")
        }
        return albumID
    }

    func findEligiblePersonID(minimumAssetCount: Int) async throws -> String {
        let config = try requireTestServerConfig()
        let baseURL = config.url.hasSuffix("/") ? String(config.url.dropLast()) : config.url
        let peopleObject = try await requestJSON(
            urlString: "\(baseURL)/people?size=100",
            apiKey: config.apiKey
        )
        let people: [[String: Any]]
        if let object = peopleObject as? [String: Any],
            let peopleArray = object["people"] as? [[String: Any]]
        {
            people = peopleArray
        } else if let peopleArray = peopleObject as? [[String: Any]] {
            people = peopleArray
        } else {
            throw XCTSkip(
                "Test server people list response has an unexpected format; cannot run the Apple TV people-filter Smart Fill UI acceptance."
            )
        }

        for person in people {
            guard let personID = person["id"] as? String else { continue }
            let encodedPersonID = personID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? personID
            let statsObject = try await requestJSON(
                urlString: "\(baseURL)/people/\(encodedPersonID)/statistics",
                apiKey: config.apiKey
            )
            let count = (statsObject as? [String: Any])?["assets"] as? Int ?? 0
            if count >= minimumAssetCount {
                return personID
            }
        }

        throw XCTSkip(
            "Test server has no person with at least \(minimumAssetCount) assets; Apple TV people-filter 20-frame acceptance is marked BLOCKED_ENV."
        )
    }

    func requestJSON(urlString: String, apiKey: String) async throws -> Any {
        guard let url = URL(string: urlString) else {
            throw XCTSkip("Cannot build the test server URL.")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("immichSlides-smartfill-tvos-ui-test", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw XCTSkip(
                "Read-only probe of the test server failed; Apple TV people-filter Smart Fill UI acceptance is marked BLOCKED_ENV."
            )
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
#endif
