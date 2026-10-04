import CoreGraphics
import Foundation
import ImageIO

// On-screen identification of public fixtures: uses only pixels and visible EXIF text, never asset IDs or probes.

enum StrictE2EPhotoIdentity {
    enum Status: String {
        case match = "MATCH"
        case black = "BLACK"
        case blank = "BLANK"
        case unrecognizable = "UNRECOGNIZABLE"
        case transition = "TRANSITION"
    }

    struct Result {
        let status: Status
        let mark: String?
        let scores: [String: Double]
        let meanLuma: Double
        let notes: [String]
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

    private static let marks = ["A1", "A2", "A3", "A4", "A5"]
    private static let expectedExif: [String: String?] = [
        "A1": "Fixture 1",
        "A2": nil,
        "A3": "Fixture 3",
        "A4": nil,
        "A5": "Fixture 5"
    ]
    private static let keyColors: [String: Set<String>] = [
        "A1": ["green", "purple"],
        "A2": ["green", "gray"],
        "A3": ["magenta", "brown"],
        "A4": ["blue", "brown"],
        "A5": ["green", "blue"]
    ]
    // Kept in sync with Python DISPLAY_REGION_BOXES. top/upper cover the case where motion cropping of the upper half
    // makes top_half scan as TRANSITION.
    static let displayRegionBoxes: [(name: String, box: (CGFloat, CGFloat, CGFloat, CGFloat))] = [
        ("center", (0.28, 0.18, 0.72, 0.82)),
        ("left", (0.0, 0.12, 0.18, 0.82)),
        ("right", (0.82, 0.12, 1.0, 0.82)),
        ("top", (0.20, 0.02, 0.80, 0.16)),
        ("upper", (0.0, 0.0, 1.0, 0.40)),
        ("mid_left", (0.18, 0.20, 0.42, 0.80)),
        ("mid_right", (0.58, 0.20, 0.82, 0.80)),
        ("top_half", (0.0, 0.0, 1.0, 0.50)),
        ("bottom_half", (0.0, 0.50, 1.0, 1.0))
    ]
    // Composite identification needs the four central quadrants to match in pairs along one axis, away from controls
    // and the divider.
    private static let captureUpperLeftBox: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.28, 0.18, 0.48, 0.42)
    private static let captureUpperRightBox: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.52, 0.18, 0.72, 0.42)
    private static let captureLowerLeftBox: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.28, 0.58, 0.48, 0.82)
    private static let captureLowerRightBox: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.52, 0.58, 0.72, 0.82)
    private static let minDisplayCropEdgePixels = 8

    static func overlayModel(from overlayText: String) -> String? {
        for model in ["Fixture 1", "Fixture 3", "Fixture 5"] where overlayText.contains(model) {
            return model
        }
        return nil
    }

    static func classify(png: Data) -> Result {
        guard !png.isEmpty,
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return Result(status: .unrecognizable, mark: nil, scores: [:], meanLuma: 0, notes: ["unreadable"])
        }
        let sampleW = 96
        let sampleH = max(8, Int((96.0 * Double(image.height) / Double(max(1, image.width))).rounded(.down)))
        var pixels = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                let context = CGContext(
                    data: base,
                    width: sampleW,
                    height: sampleH,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleW * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.interpolationQuality = .low
            context.translateBy(x: 0, y: CGFloat(sampleH))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
            return true
        }
        guard drawn else {
            return Result(status: .unrecognizable, mark: nil, scores: [:], meanLuma: 0, notes: ["undrawn"])
        }

        var counts: [String: Int] = [
            "green": 0, "gray": 0, "magenta": 0, "blue": 0, "brown": 0, "purple": 0
        ]
        var lumaSum = 0.0
        var chromatic = 0
        let observed = max(1, Int(Double(sampleW * sampleH) * 0.86 * 0.85))
        for row in 0..<sampleH {
            if row > Int(Double(sampleH) * 0.86) { continue }
            for col in 0..<sampleW {
                if col > Int(Double(sampleW) * 0.72) && row < Int(Double(sampleH) * 0.22) { continue }
                let offset = (row * sampleW + col) * 4
                let red = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let blue = Double(pixels[offset + 2])
                let luma = (0.299 * red + 0.587 * green + 0.114 * blue) / 255.0
                lumaSum += luma
                if luma < 0.035 || luma > 0.94 { continue }
                let (hue, saturation) = hueSaturation(red: red, green: green, blue: blue)
                if saturation < 0.16 || hue == nil {
                    counts["gray", default: 0] += 1
                    chromatic += 1
                    continue
                }
                guard let hue else { continue }
                if (70...170).contains(hue) {
                    counts["green", default: 0] += 1
                } else if (185...255).contains(hue) {
                    counts["blue", default: 0] += 1
                } else if (265...345).contains(hue) {
                    if saturation > 0.35 && luma < 0.55 {
                        counts["magenta", default: 0] += 1
                    } else {
                        counts["purple", default: 0] += 1
                    }
                } else if (8...50).contains(hue) {
                    counts["brown", default: 0] += 1
                } else {
                    continue
                }
                chromatic += 1
            }
        }
        let meanLuma = lumaSum / Double(observed)
        if chromatic < 18 {
            if meanLuma < 0.10 {
                return Result(status: .black, mark: nil, scores: [:], meanLuma: meanLuma, notes: ["low-chroma-dark"])
            }
            if meanLuma > 0.86 {
                return Result(status: .blank, mark: nil, scores: [:], meanLuma: meanLuma, notes: ["low-chroma-bright"])
            }
            return Result(status: .unrecognizable, mark: nil, scores: [:], meanLuma: meanLuma, notes: ["low-chroma"])
        }
        let total = Double(chromatic)
        let fraction = counts.mapValues { Double($0) / total }
        let green = fraction["green"] ?? 0
        let gray = fraction["gray"] ?? 0
        let magenta = fraction["magenta"] ?? 0
        let blue = fraction["blue"] ?? 0
        let brown = fraction["brown"] ?? 0
        let purple = fraction["purple"] ?? 0
        let scores: [String: Double] = [
            "A1": min(green, purple) + 0.15 * min(green, purple),
            "A2": max(0, min(green, gray) + 0.12 * green - 0.55 * magenta - 0.40 * blue - 0.20 * brown),
            "A3": min(magenta, brown) + 0.20 * magenta,
            "A4": min(blue, brown) + 0.15 * blue,
            "A5": max(0, min(green, blue) + 0.12 * blue - 0.45 * brown - 0.25 * magenta)
        ]
        let ranked = scores.sorted { $0.value > $1.value }
        let best = ranked[0]
        let second = ranked[1]
        let notes = [
            String(format: "luma=%.3f", meanLuma),
            String(format: "best=%@:%0.3f", best.key, best.value),
            String(format: "second=%@:%0.3f", second.key, second.value)
        ]
        // The dark blurred background of an empty result has some blue/brown noise; a gray wash must not read as A4.
        if meanLuma <= 0.30 && gray >= 0.60 {
            return Result(
                status: .unrecognizable,
                mark: nil,
                scores: scores,
                meanLuma: meanLuma,
                notes: notes + ["dark-gray-wash"]
            )
        }
        if best.value < 0.045 {
            return Result(status: .unrecognizable, mark: nil, scores: scores, meanLuma: meanLuma, notes: notes)
        }
        let mixed = second.value >= 0.05 && Set(keyColors[best.key] ?? []).isDisjoint(with: keyColors[second.key] ?? [])
        let close = second.value > 0 && best.value < second.value * 1.18 && (best.value - second.value) < 0.035
        if mixed || close {
            return Result(status: .transition, mark: nil, scores: scores, meanLuma: meanLuma, notes: notes)
        }
        return Result(status: .match, mark: best.key, scores: scores, meanLuma: meanLuma, notes: notes)
    }

    static func classifyRegions(png: Data) -> [String: Result] {
        var regions = ["full": classify(png: png)]
        for item in displayRegionBoxes {
            if let cropped = cropPNG(png, box: item.box) {
                regions[item.name] = classify(png: cropped)
            } else {
                regions[item.name] = Result(
                    status: .unrecognizable,
                    mark: nil,
                    scores: [:],
                    meanLuma: 0,
                    notes: ["crop-failed"]
                )
            }
        }
        return regions
    }

    static func captureIdentity(png: Data) -> Result {
        let full = classify(png: png)
        let pairedMarks = pairedCaptureMarks(png: png)
        if pairedMarks.count >= 2 {
            return Result(
                status: .match,
                mark: pairedMarks.joined(separator: "+"),
                scores: full.scores,
                meanLuma: full.meanLuma,
                notes: ["paired-photo-quadrant-match"] + full.notes
            )
        }
        return full
    }

    static func assertExifCorrespondence(_ identity: Result, overlayText: String) throws {
        guard identity.status == .match, let mark = identity.mark, expectedExif.keys.contains(mark) else {
            throw AssertionError.message(
                "Can't check EXIF: photo status \(identity.status.rawValue) mark=\(identity.mark ?? "nil")")
        }
        let expected = expectedExif[mark] ?? nil
        let actual = overlayModel(from: overlayText)
        if expected != actual {
            throw AssertionError.message(
                "EXIF does not match the photo: mark=\(mark) expected=\(expected ?? "nil") actual=\(actual ?? "nil")"
            )
        }
    }

    static func assertRoundTrip(_ identities: [Result]) throws {
        guard identities.count == 5 else {
            throw AssertionError.message("Round trip must have five steps, got \(identities.count)")
        }
        let marks = try requireMarks(identities, context: "Round trip")
        if marks[1] == marks[0] {
            throw AssertionError.message("Still the original photo after the first forward step")
        }
        if marks[2] == marks[1] {
            throw AssertionError.message("Still the same photo after the second forward step")
        }
        if marks[3] != marks[1] {
            throw AssertionError.message("The first back step must return to the first forward photo")
        }
        if marks[4] != marks[0] {
            throw AssertionError.message("Second back step must return to original photo \(marks[0]), got \(marks[4])")
        }
    }

    static func assertPauseHold(_ immediate: Result, _ after: Result) throws {
        let marks = try requireMarks([immediate, after], context: "Pause hold")
        if marks[0] != marks[1] {
            throw AssertionError.message("Photo changed after pausing over 10 seconds: \(marks[0]) → \(marks[1])")
        }
    }

    static func assertResumedAdvanced(_ paused: Result, _ resumed: Result) throws {
        let marks = try requireMarks([paused, resumed], context: "Resume advance")
        if marks[0] == marks[1] {
            throw AssertionError.message("Still \(marks[0]) after resuming playback; it did not advance")
        }
    }

    static func assertRequiredFrames(_ present: [String: Bool], required: [String]) throws {
        let missing = required.filter { present[$0] != true }
        if !missing.isEmpty {
            throw AssertionError.message("Window missed or required frames missing: " + missing.joined(separator: ", "))
        }
    }

    static func payload(_ identity: Result) -> [String: Any] {
        [
            "status": identity.status.rawValue,
            "mark": identity.mark ?? NSNull(),
            "mean_luma": identity.meanLuma,
            "notes": identity.notes,
            "scores": identity.scores
        ]
    }

    private static func requireMarks(_ identities: [Result], context: String) throws -> [String] {
        try identities.enumerated().map { index, identity in
            guard identity.status == .match, let mark = identity.mark, marks.contains(mark) else {
                throw AssertionError.message(
                    "\(context) step \(index + 1) cannot be identified: status=\(identity.status.rawValue) mark=\(identity.mark ?? "nil")"
                )
            }
            return mark
        }
    }

    private static func pairedCaptureMarks(png: Data) -> [String] {
        let upperLeft = capturePhotoMark(png: png, box: captureUpperLeftBox)
        let upperRight = capturePhotoMark(png: png, box: captureUpperRightBox)
        let lowerLeft = capturePhotoMark(png: png, box: captureLowerLeftBox)
        let lowerRight = capturePhotoMark(png: png, box: captureLowerRightBox)

        if let upperLeft, let upperRight, let lowerLeft, let lowerRight,
            upperLeft == upperRight, lowerLeft == lowerRight, upperLeft != lowerLeft
        {
            return [upperLeft, lowerLeft]
        }
        if let upperLeft, let upperRight, let lowerLeft, let lowerRight,
            upperLeft == lowerLeft, upperRight == lowerRight, upperLeft != upperRight
        {
            return [upperLeft, upperRight]
        }
        return []
    }

    private static func capturePhotoMark(
        png: Data,
        box: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> String? {
        guard let cropped = cropPNG(png, box: box) else { return nil }
        let identity = classify(png: cropped)
        guard identity.status == .match,
            let mark = identity.mark,
            marks.contains(mark)
        else {
            return nil
        }
        return mark
    }

    private static func cropPNG(_ png: Data, box: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let left = min(max(box.0, 0), 1) * width
        let top = min(max(box.1, 0), 1) * height
        let right = min(max(box.2, 0), 1) * width
        let bottom = min(max(box.3, 0), 1) * height
        let cropWidth = max(CGFloat(minDisplayCropEdgePixels), right - left)
        let cropHeight = max(CGFloat(minDisplayCropEdgePixels), bottom - top)
        let rect = CGRect(x: left, y: top, width: cropWidth, height: cropHeight)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
            return nil
        }
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded,
                "public.png" as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return encoded as Data
    }

    private static func hueSaturation(red: Double, green: Double, blue: Double) -> (Double?, Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        if maximum == 0 { return (nil, 0) }
        let saturation = (maximum - minimum) / maximum
        let rf = red / 255, gf = green / 255, bf = blue / 255
        let mx = max(rf, gf, bf)
        let mn = min(rf, gf, bf)
        let delta = mx - mn
        if delta == 0 { return (nil, saturation) }
        let hue: Double
        if mx == rf {
            hue = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
        } else if mx == gf {
            hue = (bf - rf) / delta + 2
        } else {
            hue = (rf - gf) / delta + 4
        }
        let wrapped = hue < 0 ? hue + 6 : hue
        return (wrapped * 60, saturation)
    }
}

enum StrictE2EVisualEvidence {
    enum WriteError: LocalizedError {
        case missingDirectory
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingDirectory:
                return "STRICT_E2E_EVIDENCE_DIR is missing; cannot write photo identity evidence"
            case .writeFailed(let name):
                return "Cannot write evidence \(name)"
            }
        }
    }

    static func directory() -> URL? {
        let path = ProcessInfo.processInfo.environment["STRICT_E2E_EVIDENCE_DIR"] ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func writePNG(_ data: Data, name: String) {
        guard let directory = directory() else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    static func writeJSON(_ payload: [String: Any], name: String) {
        guard let directory = directory(),
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    // Filter identity evidence must be written to disk; a missing directory must not be skipped silently and
    // mislead Python.
    static func writeRequiredPNG(_ data: Data, name: String) throws {
        guard let directory = directory() else { throw WriteError.missingDirectory }
        do {
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        } catch {
            throw WriteError.writeFailed("\(name).png")
        }
    }

    static func writeRequiredJSON(_ payload: [String: Any], name: String) throws {
        guard let directory = directory() else { throw WriteError.missingDirectory }
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else {
            throw WriteError.writeFailed(name)
        }
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            throw WriteError.writeFailed(name)
        }
    }
}
