import Foundation
import CoreGraphics
import ImageIO

// Shared filter contract. Identity truth comes only from public fixture photo marks;
// final pool = union(all Album_i, all Person_j(mode)).

enum StrictE2EFilterContract {
    // This only locates the full public pattern candidate in the waiting screenshot; the raw full-screen surroundings
    // must still pass the Python image contract.
    static func displayCandidatePNG(_ png: Data, evidenceDirectory: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return png }
        let references = evidenceDirectory.appendingPathComponent("public-reference-images")
        for letter in ["A", "B"] {
            for index in 1...5 {
                let data = try Data(contentsOf: references.appendingPathComponent("\(letter)\(index).png"))
                guard let referenceSource = CGImageSourceCreateWithData(data as CFData, nil),
                    let reference = CGImageSourceCreateImageAtIndex(referenceSource, 0, nil)
                else {
                    throw AssertionError.message("Public reference image is unreadable")
                }
                let scale = min(
                    Double(image.width) / Double(reference.width), Double(image.height) / Double(reference.height))
                let width = Int((Double(reference.width) * scale).rounded())
                let height = Int((Double(reference.height) * scale).rounded())
                let left = (image.width - width) / 2
                let top = (image.height - height) / 2
                guard Double(max(left, top)) >= Double(min(image.width, image.height)) * 0.04,
                    let crop = image.cropping(to: CGRect(x: left, y: top, width: width, height: height)),
                    let observed = displaySample(crop), let expected = displaySample(reference)
                else { continue }
                var matches = 0
                for pixel in 0..<(80 * 80) {
                    let offset = pixel * 4
                    if (0..<3).allSatisfy({ abs(Int(observed[offset + $0]) - Int(expected[offset + $0])) <= 24 }) {
                        matches += 1
                    }
                }
                guard Double(matches) / Double(80 * 80) >= 0.98 else { continue }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
                else {
                    throw AssertionError.message("Cannot encode the public pattern candidate")
                }
                guard let encodedRGB = crop.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) else {
                    throw AssertionError.message("Cannot read the encoded colors of the public pattern candidate")
                }
                CGImageDestinationAddImage(destination, encodedRGB, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw AssertionError.message("Encoding the public pattern candidate failed")
                }
                return output as Data
            }
        }
        return png
    }

    private static func displaySample(_ image: CGImage) -> [UInt8]? {
        guard let encodedRGB = image.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 80 * 80 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: 80, height: 80, bitsPerComponent: 8,
                    bytesPerRow: 80 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.interpolationQuality = .high
            context.draw(encodedRGB, in: CGRect(x: 0, y: 0, width: 80, height: 80))
            return true
        }
        return drawn ? pixels : nil
    }

    enum AssertionError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    static let startPlaybackButtonID = "filterSummary.startPlayback.button"
    static let allowedIdentitySource = "public_fixture_photo_mark"
    // The hash follows the public fixture manifest fields. The empty-album fixture B uses its own glyphs and bars.
    static let frozenFixtureSHA256: [String: String] = [
        "a": "44f9dc4b144e5fcc5dd14a98b76ba1bf1ca8829648555aebe738c3e2b3048989",
        "b": "4eaeac910ff1abf6555225368882e989f7cd5d5fd568f2cccde20fab60bacf71"
    ]

    static func loadMemberManifest(from directory: URL) throws -> [String: Any] {
        let url = directory.appendingPathComponent("member-manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AssertionError.message("Missing member manifest")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AssertionError.message("member manifest is unreadable")
        }
        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            payload["kind"] as? String == "strict-e2e-member-manifest",
            let fixtureSet = payload["fixture_set"] as? String,
            let expectedHash = frozenFixtureSHA256[fixtureSet],
            payload["fixture_sha256"] as? String == expectedHash
        else {
            throw AssertionError.message("member manifest fixture hash does not match the frozen contract")
        }
        return payload
    }

    static func requirePhotoMark(source: String, status: String, mark: String?) throws -> String {
        guard source == allowedIdentitySource else {
            throw AssertionError.message("Request logs, index or probes cannot serve as identity truth")
        }
        guard status == "MATCH", let mark, ["A1", "A2", "A3", "A4", "A5"].contains(mark) else {
            throw AssertionError.message("Unrecognizable input cannot pass: status=\(status) mark=\(mark ?? "nil")")
        }
        return mark
    }

    static func assertPlaybackMarksInTarget(_ marks: [String], memberManifest: [String: Any]) throws {
        guard !marks.isEmpty else {
            throw AssertionError.message("Empty playback members cannot pass")
        }
        guard Set(marks).count == marks.count else {
            throw AssertionError.message("Duplicate members cannot pass")
        }
        let target = memberManifest["target_album"] as? [String: Any]
        let allowed = Set(target?["labels"] as? [String] ?? [])
        let wrong = marks.filter { !allowed.contains($0) }
        if !wrong.isEmpty {
            throw AssertionError.message("Wrong members cannot pass: \(wrong.joined(separator: ", "))")
        }
    }

    static func albumSelectionLabels(memberManifest: [String: Any], albumID: String) throws -> [String] {
        guard
            let objectSets = memberManifest["object_sets"] as? [String: Any],
            let albums = objectSets["albums"] as? [String: Any],
            let entry = albums[albumID] as? [String: Any],
            let labels = entry["labels"] as? [String]
        else {
            throw AssertionError.message("Unknown album: \(albumID)")
        }
        return labels
    }

    static func personSelectionLabels(
        memberManifest: [String: Any],
        personID: String,
        mode: String
    ) throws -> [String] {
        guard
            let objectSets = memberManifest["object_sets"] as? [String: Any],
            let people = objectSets["people"] as? [String: Any],
            let person = people[personID] as? [String: Any],
            let entry = person[mode] as? [String: Any],
            let labels = entry["labels"] as? [String]
        else {
            throw AssertionError.message("Unknown person or mode: \(personID) \(mode)")
        }
        return labels
    }

    static func unionSelectionLabels(
        memberManifest: [String: Any],
        albumIDs: [String],
        personFilters: [[String: String]]
    ) throws -> [String] {
        // Final pool = union(all Album_i, all Person_j(mode)); soloOnly must not filter the albums or the pool again.
        var labels: [String] = []
        var seen = Set<String>()
        func appendUnique(_ extra: [String]) {
            for label in extra where !seen.contains(label) {
                seen.insert(label)
                labels.append(label)
            }
        }
        for albumID in albumIDs {
            appendUnique(try albumSelectionLabels(memberManifest: memberManifest, albumID: albumID))
        }
        for filter in personFilters {
            guard let personID = filter["person_id"], let mode = filter["mode"] else {
                throw AssertionError.message("A person filter must be a separate person_id + mode")
            }
            appendUnique(
                try personSelectionLabels(memberManifest: memberManifest, personID: personID, mode: mode)
            )
        }
        return labels
    }

    static func assertPlaybackMarksInUnion(
        _ marks: [String],
        memberManifest: [String: Any],
        albumIDs: [String],
        personFilters: [[String: String]]
    ) throws {
        guard !marks.isEmpty else {
            throw AssertionError.message("Empty playback members cannot pass")
        }
        let allowed = Set(
            try unionSelectionLabels(
                memberManifest: memberManifest,
                albumIDs: albumIDs,
                personFilters: personFilters
            )
        )
        let wrong = marks.filter { !allowed.contains($0) }
        if !wrong.isEmpty {
            throw AssertionError.message("Members outside the union cannot pass: \(wrong.joined(separator: ", "))")
        }
    }

    static func assertFinalPoolEqualsUnion(
        _ marks: [String],
        memberManifest: [String: Any],
        albumIDs: [String],
        personFilters: [[String: String]]
    ) throws {
        guard Set(marks).count == marks.count else {
            throw AssertionError.message("Duplicate members cannot pass")
        }
        let expected = Set(
            try unionSelectionLabels(
                memberManifest: memberManifest,
                albumIDs: albumIDs,
                personFilters: personFilters
            )
        )
        let observed = Set(marks)
        let wrong = observed.subtracting(expected).sorted()
        if !wrong.isEmpty {
            throw AssertionError.message("Members outside the union cannot pass: \(wrong.joined(separator: ", "))")
        }
        let missing = expected.subtracting(observed).sorted()
        if !missing.isEmpty {
            throw AssertionError.message("Missing union members cannot pass: \(missing.joined(separator: ", "))")
        }
    }

    static func assertEmptySelectionCannotStart(isEmpty: Bool, startEnabled: Bool) throws {
        if isEmpty && startEnabled {
            throw AssertionError.message("An empty selection cannot start")
        }
        if isEmpty == startEnabled {
            throw AssertionError.message("Start button state does not match the selection contract")
        }
    }

    static func assertSoloOnlyNotVacuous(
        environment: String,
        visionAvailable: Bool,
        qualifiedMarks: [String],
        faceCounts: [String: Int],
        memberManifest: [String: Any]
    ) throws {
        guard environment == "device" else {
            throw AssertionError.message("Simulator Vision does not replace a real device; soloOnly is not PASS")
        }
        guard visionAvailable else {
            throw AssertionError.message("Vision is unavailable; soloOnly must not pass by accident")
        }
        guard !qualifiedMarks.isEmpty else {
            throw AssertionError.message("An empty soloOnly result must not qualify vacuously")
        }
        let cases = memberManifest["person_cases"] as? [String: Any]
        let qualified = cases?["solo_only_qualified"] as? [String: Any]
        let allowed = Set(qualified?["labels"] as? [String] ?? [])
        for mark in qualifiedMarks {
            guard allowed.contains(mark) else {
                throw AssertionError.message("Wrong member cannot pass soloOnly: \(mark)")
            }
            guard faceCounts[mark] == 1 else {
                throw AssertionError.message("No faces or face count not 1 cannot pass soloOnly: \(mark)")
            }
        }
    }

    static func assertForeignServerIDsAbsent(_ observedIDs: [String], memberManifest: [String: Any]) throws {
        let allowed = Set(
            (memberManifest["all_asset_ids"] as? [String] ?? []) + (memberManifest["all_album_ids"] as? [String] ?? [])
                + (memberManifest["all_person_ids"] as? [String] ?? [])
        )
        let foreign = observedIDs.filter { !allowed.contains($0) }
        if !foreign.isEmpty {
            throw AssertionError.message("Old IDs left over from another server: \(foreign.joined(separator: ", "))")
        }
    }
}
