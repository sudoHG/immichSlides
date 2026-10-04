import Foundation
import XCTest

#if os(iOS)
extension PlaybackSmartFillVisualUITests {
    func writeInteractionActionEvidence(_ actions: [[String: Any]], scenario: String) {
        guard let directory = motionEvidenceDirectory() else { return }
        let payload: [String: Any] = [
            "schemaVersion": "interaction-actions-v1",
            "scenario": scenario,
            "deviceTag": deviceTag(),
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

    func interactionActionCSV(_ actions: [[String: Any]]) -> String {
        let columns = [
            "action",
            "elapsedSeconds",
            "timestamp"
        ]
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
            "sampleIndex",
            "elapsedSeconds",
            "probeIdentifier",
            "sceneId",
            "slotId",
            "assetId",
            "renderRole",
            "controlBarVisible",
            "appOverlayPollution",
            "acceptedMotionScope",
            "singleFilledScope",
            "progressFrameStatus",
            "clockGeneration",
            "progress",
            "progressSource",
            "presentationProgressSource",
            "visualFrameSource",
            "presentationModelDivergenceStatus",
            "isDiscontinuous",
            "extensionReason",
            "timelineStartTime",
            "stableVisibleStartTime",
            "handoffStartDeadlineTime",
            "removalDeadlineTime",
            "stableVisibleDuration",
            "transitionCompletionDelay",
            "preparedNextTargetIndex",
            "preparedNextSourceCursor",
            "currentPreparedSourceCursor",
            "lookaheadCachedSourceCursor",
            "lookaheadCachedSelectedCount",
            "scale",
            "translationX",
            "translationY",
            "renderedFrameMinX",
            "renderedFrameMinY",
            "renderedFrameWidth",
            "renderedFrameHeight",
            "presentationFrameMinX",
            "presentationFrameMinY",
            "presentationFrameWidth",
            "presentationFrameHeight",
            "modelFrameMinX",
            "modelFrameMinY",
            "modelFrameWidth",
            "modelFrameHeight",
            "anchorX",
            "anchorY",
            "focalSourceKind",
            "focalProvenance",
            "zoomDirection",
            "stableSeedHash",
            "seedInputSummary",
            "requestedTranslationX",
            "requestedTranslationY",
            "clampedTranslationX",
            "clampedTranslationY",
            "endTranslationX",
            "endTranslationY",
            "phaseAction",
            "isIdentity",
            "manifestSlotRefs",
            "manifestSceneType"
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
                "Test server people list response has an unexpected format; cannot run the people-filter Smart Fill UI acceptance."
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
            "Test server has no person with at least \(minimumAssetCount) assets; people-filter 20-frame acceptance is marked BLOCKED_ENV."
        )
    }

    func requestJSON(urlString: String, apiKey: String) async throws -> Any {
        guard let url = URL(string: urlString) else {
            throw XCTSkip("Cannot build the test server URL.")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("immichSlides-smartfill-ui-test", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw XCTSkip(
                "Read-only probe of the test server failed; people-filter Smart Fill UI acceptance is marked BLOCKED_ENV."
            )
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
#endif
