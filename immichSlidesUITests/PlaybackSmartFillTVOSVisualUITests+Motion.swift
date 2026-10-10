import Foundation
import XCTest

#if os(tvOS)
extension PlaybackSmartFillTVOSVisualUITests {
    func attachScreenshot(app: XCUIApplication, name: String) {
        _ = captureRuntimeScreenshot(app: app, name: name, shouldAttachToXCTest: true)
    }

    func captureRuntimeScreenshot(
        app: XCUIApplication,
        name: String,
        shouldAttachToXCTest: Bool
    ) -> (path: String, captureTimestamp: String)? {
        let screenshot = app.screenshot()
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

    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        return condition()
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

    func writeManifestEvidence(
        _ manifests: [SmartFillManifest],
        runtimeRecords: [[String: Any]],
        harnessSummary: [String: Any]?,
        scenario: String
    ) {
        guard let directory = evidenceDirectory() else { return }
        let summary = manifests.enumerated().map { index, manifest in
            [
                "index=\(index + 1)",
                "sceneType=\(manifest.sceneType)",
                "surfaceKey=\(manifest.surfaceKey)",
                "policy=\(manifest.policy)",
                "layoutVariant=\(manifest.layoutVariant)",
                "ratioPreset=\(manifest.ratioPreset)",
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
                "rejects=\(manifest.rejects)",
                "rejectedLayoutReasonTopList=\(manifest.rejectedLayoutReasonTopList)",
                "fallback=\(manifest.fallback)",
                "slotRefs=\(manifest.slotRefs)"
            ].joined(separator: ";")
        }.joined(separator: "\n")
        let fileURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-manifest") + ".txt"
        )
        requireEvidenceWrite {
            try summary.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        guard !runtimeRecords.isEmpty else { return }
        let jsonlURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-runtime") + ".jsonl"
        )
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONLines(runtimeRecords, to: jsonlURL)
        }
        let summaryURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-runtime-summary") + ".txt"
        )
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.summaryLines(for: runtimeRecords)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
        }
        if let observedLockText = SmartFillRuntimeEvidenceSupport.scenarioManifestObservationLockText(
            records: runtimeRecords,
            scenario: scenario,
            deviceTag: "appletv"
        ) {
            let lockURL = directory.appendingPathComponent(
                sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-scenario-manifest-observed") + ".lock"
            )
            requireEvidenceWrite {
                try observedLockText.write(to: lockURL, atomically: true, encoding: .utf8)
            }
        }
        if let harnessSummary {
            let harnessURL = directory.appendingPathComponent(
                sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-harness-summary") + ".json"
            )
            requireEvidenceWrite {
                try SmartFillRuntimeEvidenceSupport.writeJSONObject(harnessSummary, to: harnessURL)
            }
        }
    }

    func writeMotionFrameEvidence(_ rows: [MotionFrameEvidenceRow], scenario: String) {
        rows.forEach { SmartFillRuntimeEvidenceSupport.assertRedactedSeedSummary($0.fields) }
        guard let directory = motionEvidenceDirectory() else { return }
        let baseName = sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-motion-frames")
        let dictionaries = rows.map(motionFrameDictionary)
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONLines(
                dictionaries,
                to: directory.appendingPathComponent(baseName + ".jsonl")
            )
        }
        requireEvidenceWrite {
            try motionFrameCSV(rows)
                .write(to: directory.appendingPathComponent(baseName + ".csv"), atomically: true, encoding: .utf8)
        }
    }

    func writeProductSceneSequenceEvidence(
        _ rows: [ProductSceneSequenceRow],
        motionRows: [MotionFrameEvidenceRow],
        scenario: String,
        sampleDuration: TimeInterval
    ) {
        for row in rows {
            let refs = row.manifestSlotRefs.split(separator: ",")
            XCTAssertFalse(refs.isEmpty)
            XCTAssertTrue(refs.allSatisfy { $0.range(of: "^asset-[0-9a-f]{16}$", options: .regularExpression) != nil })
            if let motionRow = motionRows.first(where: {
                $0.sampleIndex == row.sampleIndex
                    && $0.fields["sceneId"] == row.productTransitionFields["sceneId"]
            }) {
                XCTAssertEqual(row.manifestSlotRefs, motionRow.manifestSlotRefs)
            }
        }
        guard let directory = motionEvidenceDirectory() else { return }
        let dictionaries = rows.map(productSceneSequenceDictionary)
        let transitionDictionaries = dictionaries.filter { dictionary in
            dictionary["productTransitionActive"] as? String == "true"
        }
        let countsBySceneType = Dictionary(grouping: rows, by: \.manifestSceneType)
            .mapValues(\.count)
        let motionSupportedSceneTypes = ["double", "triple", "single"]
        let cleanAvailableMotionSceneTypes = Set(
            motionRows.compactMap { row -> String? in
                guard row.fields["progressFrameStatus"] == "available",
                    row.fields["controlBarVisible"] == "false",
                    row.fields["appOverlayPollution"] == "none"
                else {
                    return nil
                }
                return row.manifestSceneType
            }
        ).sorted()
        let motionCoveredSceneTypes = cleanAvailableMotionSceneTypes
        let visibleUncoveredMotionSceneTypes = Set(rows.map(\.manifestSceneType))
            .subtracting(Set(motionCoveredSceneTypes))
            .sorted()
        let motionUnverifiedSupportedSceneTypes = Set(motionSupportedSceneTypes)
            .subtracting(Set(motionCoveredSceneTypes))
            .sorted()
        let motionCoverageVerdict = motionUnverifiedSupportedSceneTypes.isEmpty ? "PASS" : "PARTIAL"
        let manifest: [String: Any] = [
            "schemaVersion": "apple-tv-smartfill-motion-product-scope-evidence-v1",
            "scenario": scenario,
            "deviceTag": "appletv",
            "deviceRequirement": "Apple TV",
            "configuredIntervalSeconds": 5.0,
            "requestedSampleDurationSeconds": sampleDuration,
            "productScope": [
                "source": "full-product-continuous",
                "cleanAcceptedOnlyClaimAllowed": false,
                "motionSupportedSceneTypes": motionSupportedSceneTypes,
                "motionCoveredSceneTypes": motionCoveredSceneTypes,
                "motionUnverifiedSupportedSceneTypes": motionUnverifiedSupportedSceneTypes,
                "motionCoverageVerdict": motionCoverageVerdict,
                "motionScopeExpandedToSingle": true,
                "motionScopeExpandedToFallback": false,
                "motionScopeExpandedToLegacy": false,
                "known_out_of_scope_visual_gap": !visibleUncoveredMotionSceneTypes.isEmpty,
                "visibleUncoveredMotionSceneTypes": visibleUncoveredMotionSceneTypes,
                "cleanAvailableMotionSceneTypes": cleanAvailableMotionSceneTypes
            ],
            "countsBySceneType": countsBySceneType,
            "rowCount": rows.count,
            "transitionActiveRowCount": transitionDictionaries.count,
            "sceneSequenceJSON": "scene-sequence.json",
            "sceneSequenceCSV": "scene-sequence.csv",
            "productTransitionProbesJSON": "product-transition-probes.json",
            "productTransitionProbesCSV": "product-transition-probes.csv"
        ]
        let sceneSequence: [String: Any] = [
            "schemaVersion": "apple-tv-smartfill-motion-scene-sequence-v1",
            "scenario": scenario,
            "deviceTag": "appletv",
            "deviceRequirement": "Apple TV",
            "configuredIntervalSeconds": 5.0,
            "requestedSampleDurationSeconds": sampleDuration,
            "countsBySceneType": countsBySceneType,
            "rowCount": rows.count,
            "transitionActiveRowCount": transitionDictionaries.count,
            "rows": dictionaries
        ]
        let productTransitionProbes: [String: Any] = [
            "schemaVersion": "apple-tv-smartfill-motion-transition-probes-v1",
            "scenario": scenario,
            "deviceTag": "appletv",
            "transitionActiveRowCount": transitionDictionaries.count,
            "rows": transitionDictionaries
        ]
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                manifest,
                to: directory.appendingPathComponent("manifest.json")
            )
        }
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                sceneSequence,
                to: directory.appendingPathComponent("scene-sequence.json")
            )
        }
        requireEvidenceWrite {
            try productSceneSequenceCSV(rows)
                .write(to: directory.appendingPathComponent("scene-sequence.csv"), atomically: true, encoding: .utf8)
        }
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                productTransitionProbes,
                to: directory.appendingPathComponent("product-transition-probes.json")
            )
        }
        requireEvidenceWrite {
            let transitionRows = rows.filter { $0.productTransitionFields["productTransitionActive"] == "true" }
            try productSceneSequenceCSV(transitionRows)
                .write(
                    to: directory.appendingPathComponent("product-transition-probes.csv"), atomically: true,
                    encoding: .utf8
                )
        }
    }

    func writeInteractionActionEvidence(_ actions: [[String: Any]], scenario: String) {
        guard let directory = motionEvidenceDirectory() else { return }
        let payload: [String: Any] = [
            "schemaVersion": "apple-tv-smartfill-motion-interaction-actions-v1",
            "scenario": scenario,
            "deviceTag": "appletv",
            "actions": actions
        ]
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                payload,
                to: directory.appendingPathComponent("user-actions.json")
            )
        }
        requireEvidenceWrite {
            try interactionActionCSV(actions)
                .write(to: directory.appendingPathComponent("user-actions.csv"), atomically: true, encoding: .utf8)
        }
    }

    func productSceneSequenceDictionary(_ row: ProductSceneSequenceRow) -> [String: Any] {
        let endpoints = productTransitionEndpointSceneTypes(row.productTransitionFields)
        var object: [String: Any] = [
            "sampleIndex": row.sampleIndex,
            "elapsedSeconds": row.elapsedSeconds,
            "manifestSlotRefs": row.manifestSlotRefs,
            "manifestSceneType": row.manifestSceneType,
            "productTransitionActive": row.productTransitionFields["productTransitionActive"] ?? "missing",
            "acceptedMotionTransitionActive": row.productTransitionFields["acceptedMotionTransitionActive"]
                ?? "missing",
            "productBlackBackingActive": row.productTransitionFields["productBlackBackingActive"]
                ?? row.productTransitionFields["blackBackingActive"] ?? "missing",
            "transitionFromSceneType": endpoints.from,
            "transitionToSceneType": endpoints.to,
            "transitionLayerRoles": row.productTransitionFields["transitionLayerRoles"] ?? "missing",
            "transitionLayerSceneTypes": row.productTransitionFields["transitionLayerSceneTypes"] ?? "missing",
            "transitionLayerScopes": row.productTransitionFields["transitionLayerScopes"] ?? "missing"
        ]
        for (key, value) in row.productTransitionFields {
            object[key] = value
        }
        return object
    }

    func productSceneSequenceCSV(_ rows: [ProductSceneSequenceRow]) -> String {
        let columns = [
            "sampleIndex",
            "elapsedSeconds",
            "manifestSlotRefs",
            "manifestSceneType",
            "productTransitionActive",
            "acceptedMotionTransitionActive",
            "productBlackBackingActive",
            "transitionFromSceneType",
            "transitionToSceneType",
            "transitionLayerRoles",
            "transitionLayerSceneTypes",
            "transitionLayerScopes"
        ]
        let body = rows.map { row in
            let dictionary = productSceneSequenceDictionary(row)
            return columns.map { column in
                switch column {
                case "sampleIndex":
                    return "\(row.sampleIndex)"
                case "elapsedSeconds":
                    return String(format: "%.6f", row.elapsedSeconds)
                default:
                    return csvEscaped("\(dictionary[column] ?? "")")
                }
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
    }

    func productTransitionEndpointSceneTypes(_ fields: [String: String]) -> (from: String, to: String) {
        let roles =
            fields["transitionLayerRoles"]?
            .split(separator: "|")
            .map(String.init) ?? []
        let sceneTypes =
            fields["transitionLayerSceneTypes"]?
            .split(separator: "|")
            .map(String.init) ?? []
        var from = "none"
        var to = "none"
        for (index, role) in roles.enumerated() where sceneTypes.indices.contains(index) {
            if role == "outgoing" {
                from = sceneTypes[index]
            }
            if role == "incoming" {
                to = sceneTypes[index]
            }
        }
        return (from, to)
    }

    func motionFrameDictionary(_ row: MotionFrameEvidenceRow) -> [String: Any] {
        var object: [String: Any] = [
            "sampleIndex": row.sampleIndex,
            "elapsedSeconds": row.elapsedSeconds,
            "probeIdentifier": row.probeIdentifier,
            "manifestSlotRefs": row.manifestSlotRefs,
            "manifestSceneType": row.manifestSceneType
        ]
        for (key, value) in row.fields {
            object[key] = value
        }
        return object
    }

    func motionFrameCSV(_ rows: [MotionFrameEvidenceRow]) -> String {
        let columns = [
            "sampleIndex", "elapsedSeconds", "probeIdentifier", "sceneId", "slotId", "assetId",
            "renderRole", "controlBarVisible", "appOverlayPollution", "acceptedMotionScope",
            "singleFilledScope", "progressFrameStatus", "clockGeneration", "progress",
            "progressSource", "presentationProgressSource", "visualFrameSource",
            "presentationModelDivergenceStatus", "isDiscontinuous", "extensionReason",
            "timelineStartTime", "stableVisibleStartTime", "handoffStartDeadlineTime",
            "removalDeadlineTime", "stableVisibleDuration", "transitionCompletionDelay",
            "scale", "translationX", "translationY", "renderedFrameMinX", "renderedFrameMinY",
            "renderedFrameWidth", "renderedFrameHeight", "presentationFrameMinX",
            "presentationFrameMinY", "presentationFrameWidth", "presentationFrameHeight",
            "modelFrameMinX", "modelFrameMinY", "modelFrameWidth", "modelFrameHeight",
            "anchorX", "anchorY", "focalSourceKind", "focalProvenance", "zoomDirection",
            "stableSeedHash", "seedInputSummary", "requestedTranslationX", "requestedTranslationY",
            "clampedTranslationX", "clampedTranslationY", "endTranslationX", "endTranslationY",
            "phaseAction", "isIdentity", "manifestSlotRefs", "manifestSceneType"
        ]
        let body = rows.map { row in
            columns.map { column in
                switch column {
                case "sampleIndex":
                    return "\(row.sampleIndex)"
                case "elapsedSeconds":
                    return String(format: "%.6f", row.elapsedSeconds)
                case "probeIdentifier":
                    return csvEscaped(row.probeIdentifier)
                case "manifestSlotRefs":
                    return csvEscaped(row.manifestSlotRefs)
                case "manifestSceneType":
                    return csvEscaped(row.manifestSceneType)
                default:
                    return csvEscaped(row.fields[column] ?? "")
                }
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
    }

    func interactionActionCSV(_ actions: [[String: Any]]) -> String {
        let columns = ["action", "elapsedSeconds", "timestamp"]
        let body = actions.map { action in
            columns.map { column in
                if column == "elapsedSeconds", let value = action[column] as? Double {
                    return String(format: "%.6f", value)
                }
                return csvEscaped("\(action[column] ?? "")")
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
    }

    func makeHarnessSummary(
        runtimeRecords: [[String: Any]],
        firstManifestObservedMs: Double?,
        firstNonLoadingScreenshotCapturedMs: Double?
    ) -> [String: Any]? {
        guard let startupRunId = runtimeRecords.first?["startupRunId"] as? String,
            let firstManifestObservedMs,
            let firstNonLoadingScreenshotCapturedMs
        else {
            return nil
        }
        return SmartFillRuntimeEvidenceSupport.makeHarnessSummary(
            startupRunId: startupRunId,
            firstManifestObservedMs: firstManifestObservedMs,
            firstNonLoadingScreenshotCapturedMs: firstNonLoadingScreenshotCapturedMs
        )
    }

    func evidenceDirectory() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let rootPath =
            environment["IMMICHSLIDES_SMARTFILL_EVIDENCE_ROOT"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_EVIDENCE_ROOT"]
        do {
            return try PrivateEvidenceDirectory.resolve(
                rootPath: rootPath,
                components: ["ui-runtime", "appletv"]
            )
        } catch {
            XCTFail(error.localizedDescription)
            return nil
        }
    }

    func motionEvidenceDirectory() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TEST_RUNNER_SMARTFILL_MOTION_EVIDENCE_DIR"]
            ?? environment["SMARTFILL_MOTION_EVIDENCE_DIR"],
            !path.isEmpty
        {
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
        guard let root = evidenceDirectory() else { return nil }
        do {
            return try PrivateEvidenceDirectory.resolve(
                rootPath: root.path,
                components: ["motion-runtime"]
            )
        } catch {
            XCTFail(error.localizedDescription)
            return nil
        }
    }

    func csvEscaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func sanitizedEvidenceFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return raw.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    enum SmartFillTVOSFailure: Error {
        case missingManifest
        case motionTraceFinishedBeforeInteraction
    }
}
#endif
