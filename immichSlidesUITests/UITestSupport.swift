import ImageIO
import UIKit
import XCTest

enum UITestSupportWaitTiming {
    static let briefElementTimeoutSeconds: TimeInterval = TestWait.seconds(.product(1))
    static let connectionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(15))
    static let controlAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(8))
    static let elementAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(5))
    static let identityPollSeconds: TimeInterval = TestWait.seconds(.product(0.3))
    static let playbackStartupTimeoutSeconds: TimeInterval = TestWait.seconds(.product(30))
    static let readbackTimeoutSeconds: TimeInterval = TestWait.seconds(.product(2))
    static let sceneReadyTimeoutSeconds: TimeInterval = TestWait.seconds(.infrastructure(45))
    static let screenTransitionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(12))
    static let settingsChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(6))
    static let shortInteractionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(3))
    static let stateChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(4))
}

// Shared by the strict end-to-end UI tests: writing required PNGs / steps to disk, stable-frame waits, and real settings
// actions on both platforms.
// scripts/strict_e2e_p2_contract.py is the single source of truth for the p2-steps.json format.

enum Timing {
    // Interval between two screenshots (seconds). Stable only when two consecutive frames show the same public
    // pattern, which rules out mid-transition frames.
    static let identityPoll: TimeInterval = TestWait.seconds(.product(0.3))
    static let stableIdentityTimeout: TimeInterval = TestWait.seconds(.product(8))
    static let exifSettleTimeout: TimeInterval = TestWait.seconds(.product(5))
    // Multi-photo scenes must hold for 1 second in a row, to avoid capturing a half-switched frame.
    static let multiPhotoWait: TimeInterval = TestWait.seconds(.product(4))
    static let multiPhotoHold: TimeInterval = TestWait.seconds(.product(1))
    static let clearCompletionTimeout: TimeInterval = TestWait.seconds(.product(15))
    static let focusSettle: TimeInterval = TestWait.seconds(.product(0.16))
    static let poll: TimeInterval = TestWait.seconds(.product(0.1))
    // Orientation steady state: capture only when two frames 0.5 seconds apart show no layout jump. Wait at most
    // 10 seconds per attempt; on timeout keep the scene as it is.
    static let stableFramePair: TimeInterval = TestWait.seconds(.product(0.5))
    static let stableFrameTimeout: TimeInterval = TestWait.seconds(.product(10))
}

// Values match the orientation field in p2-steps.json; notApplicable skips the orientation check.
enum StepOrientation: String {
    case portrait
    case landscape
    case notApplicable = "not_applicable"

    func matches(_ size: CGSize) -> Bool {
        switch self {
        case .portrait: return size.height > size.width
        case .landscape: return size.width > size.height
        case .notApplicable: return true
        }
    }
}

struct Failure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

enum Wait {
    @MainActor
    static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.poll))
        }
        return condition()
    }

    // The condition must hold continuously for hold seconds within timeout; the timer restarts if it fails midway.
    @MainActor
    static func held(timeout: TimeInterval, hold: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout + hold)
        var heldSince: Date?
        while Date() < deadline {
            if condition() {
                let start = heldSince ?? Date()
                heldSince = start
                if Date().timeIntervalSince(start) >= hold { return true }
            } else {
                heldSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.poll))
        }
        return false
    }
}

@MainActor
final class Evidence {
    private var steps: [[String: Any]] = []

    // Write the required PNG and record a step only when accept passes. On timeout keep only a -rejected
    // diagnostic frame; the required file stays missing so the contract fails.
    @discardableResult
    func capture(
        _ name: String,
        from app: XCUIApplication,
        orientation: StepOrientation = .notApplicable,
        timeout: TimeInterval = Timing.stableIdentityTimeout,
        accept: (StrictE2EPhotoIdentity.Result) -> Bool = { _ in true }
    ) throws -> StrictE2EPhotoIdentity.Result {
        let deadline = Date().addingTimeInterval(timeout)
        var capturedAt = Date()
        var png = app.screenshot().pngRepresentation
        var identity = StrictE2EPhotoIdentity.classify(png: png)
        // No retakes past the deadline, so a last round cannot push later watermarks out of the contract window.
        while !accept(identity) {
            let retryAt = Date().addingTimeInterval(Timing.identityPoll)
            guard retryAt < deadline else { break }
            RunLoop.current.run(until: retryAt)
            capturedAt = Date()
            png = app.screenshot().pngRepresentation
            identity = StrictE2EPhotoIdentity.classify(png: png)
        }
        guard accept(identity) else {
            try reject(name, png: png)
            throw Failure("\(name) unmet at timeout: status=\(identity.status.rawValue) mark=\(identity.mark ?? "nil")")
        }
        try record(name, png: png, capturedAt: capturedAt, orientation: orientation)
        return identity
    }

    // A frame the caller already accepted: write the required PNG and record a step.
    func record(_ name: String, png: Data, capturedAt: Date, orientation: StepOrientation) throws {
        try save(png, as: name)
        try appendStep(name, at: capturedAt, orientation: orientation, png: "\(name).png")
    }

    // A rejected frame leaves only a -rejected diagnostic; the required PNG stays missing so the contract fails.
    func reject(_ name: String, png: Data) throws {
        try save(png, as: "\(name)-rejected")
    }

    // Time marker without a PNG (rotation start, start of a recording segment). The contract uses it to convert
    // recording offsets.
    func markStep(_ name: String) throws {
        try appendStep(name, at: Date(), orientation: .notApplicable, png: nil)
    }

    private func save(_ png: Data, as fileName: String) throws {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: fileName) { $0.add(attachment) }
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: fileName)
    }

    private func appendStep(_ name: String, at wallTime: Date, orientation: StepOrientation, png: String?) throws {
        var step: [String: Any] = [
            "index": steps.count + 1,
            "name": name,
            "wall_time": wallTime.timeIntervalSince1970,
            "orientation": orientation.rawValue
        ]
        if let png { step["png"] = png }
        steps.append(step)
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["schema": "strict-e2e-steps-v1", "steps": steps], name: "p2-steps.json")
    }

}

struct StableFrame {
    // Upper limit of the mean per-pixel difference (0-1) between 64x64 grayscale thumbnails. On the public pattern
    // a slow 0.5-second zoom / pan is about <=0.02, while a 5% relayout or a crossfade is about >=0.032. A relayout
    // of a screen with little content may fall below it.
    static let layoutJumpLimit = 0.03
    private static let thumbnailSide = 64

    let png: Data
    let capturedAt: Date
    let isStable: Bool
    let detail: String

    // Stable only when window orientation, prepare (run before the screenshot, e.g. waking the control bar), pixel
    // orientation and accept all hold, and two frames 0.5 seconds apart differ by no more than the limit. On
    // timeout, returns the last frame for the record.
    @MainActor
    static func wait(
        in app: XCUIApplication,
        orientation: StepOrientation,
        timeout: TimeInterval = Timing.stableFrameTimeout,
        prepare: () -> Bool = { true },
        accept: (Data) -> Bool
    ) -> StableFrame {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: Data?
        while true {
            let window = app.frame.size
            let isPrepared = orientation.matches(window) && prepare()
            let capturedAt = Date()
            let png = uprightScreenPNG()
            let pixels = pixelSize(png) ?? .zero
            var candidate: Data?
            let detail: String
            if !orientation.matches(window) {
                detail = "window \(window) not yet \(orientation.rawValue)"
            } else if !isPrepared {
                detail = "controls or scene not ready"
            } else if !orientation.matches(pixels) {
                detail = "screenshot pixels \(pixels) not yet \(orientation.rawValue)"
            } else if !accept(png) {
                detail = "screen not ready"
            } else if let previous {
                candidate = png
                if let difference = difference(previous, png) {
                    let formatted = String(format: "%.4f", difference)
                    if difference <= layoutJumpLimit {
                        return StableFrame(
                            png: png, capturedAt: capturedAt, isStable: true, detail: "frame diff \(formatted)")
                    }
                    detail = "frame diff \(formatted) exceeds \(layoutJumpLimit)"
                } else {
                    detail = "thumbnail decoding failed; cannot compare the two frames"
                }
            } else {
                candidate = png
                detail = "waiting for the second frame"
            }
            previous = candidate
            let nextAt = capturedAt.addingTimeInterval(Timing.stableFramePair)
            guard nextAt <= deadline else {
                return StableFrame(png: png, capturedAt: capturedAt, isStable: false, detail: detail)
            }
            RunLoop.current.run(until: nextAt)
        }
    }

    // In landscape, an app-element screenshot is cropped at the wrong offset and a full-screen screenshot is the
    // native portrait framebuffer; redraw it using the system's imageOrientation to match what the user sees.
    static func uprightScreenPNG() -> Data {
        let screenshot = XCUIScreen.main.screenshot()
        let image = screenshot.image
        guard image.imageOrientation != .up else { return screenshot.pngRepresentation }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in image.draw(at: .zero) }
    }

    // MATCH or TRANSITION both mean the public pattern is visible; mixed colors in multi-photo scenes usually
    // classify as TRANSITION.
    static func showsFixturePhoto(_ png: Data) -> Bool {
        [.match, .transition].contains(StrictE2EPhotoIdentity.classify(png: png).status)
    }

    static func pixelSize(_ png: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    static func difference(_ first: Data, _ second: Data) -> Double? {
        guard let lhs = thumbnail(first), let rhs = thumbnail(second) else { return nil }
        let total = zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(lhs.count * 255)
    }

    private static func thumbnail(_ png: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: thumbnailSide * thumbnailSide)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                let context = CGContext(
                    data: base,
                    width: thumbnailSide,
                    height: thumbnailSide,
                    bitsPerComponent: 8,
                    bytesPerRow: thumbnailSide,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailSide, height: thumbnailSide))
            return true
        }
        return didDraw ? pixels : nil
    }
}

enum PlaybackSetting {
    case interval30Seconds
    // Positive control for Reduce Motion: moves faster than 30 seconds and is easier to see, yet still leaves
    // enough time to observe the same scene after returning.
    case interval15Seconds
    case displayMode(isSinglePhoto: Bool)
    case showExif(Bool)
}

// The two platforms differ only in how they tap; photo identification, waiting and evidence checks are shared.
@MainActor
protocol PlaybackDriver {
    var app: XCUIApplication { get }
    func launchToPlayback(input: StrictE2EInput)
    func applyPlaybackSettings(_ settings: [PlaybackSetting])
    func pause()
    func next()
    func returnToPlayback()
    // On the cache page, capture the screen before clearing, then handle the confirm alert; ends on the cache page.
    func clearDiskCache(onCachePage: () throws -> Void) throws
}

extension PlaybackDriver {
    // Returns only after two consecutive frames show the same MATCH; previous skips the old screen left over
    // from before the switch.
    func stableMark(excluding previous: String? = nil, timeout: TimeInterval = Timing.stableIdentityTimeout) -> String?
    {
        stableMark(excluding: previous, timeout: timeout, checkEachPoll: {})
    }

    // checkEachPoll runs before every screenshot and ends the wait by throwing.
    func stableMark(
        excluding previous: String? = nil, timeout: TimeInterval = Timing.stableIdentityTimeout,
        checkEachPoll: () throws -> Void
    ) rethrows -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        var unchanged: String?
        while Date() < deadline {
            try checkEachPoll()
            let identity = StrictE2EPhotoIdentity.classify(png: app.screenshot().pngRepresentation)
            let mark = identity.status == .match ? identity.mark : nil
            if let mark, mark == last {
                if mark != previous { return mark }
                unchanged = mark
            }
            last = mark
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.identityPoll))
        }
        return unchanged
    }

    func advance(toAnyOf marks: Set<String>, maxNextPresses: Int = 6) throws -> String {
        var current = stableMark()
        for _ in 0..<maxNextPresses {
            if let current, marks.contains(current) { return current }
            next()
            current = stableMark(excluding: current)
        }
        if let current, marks.contains(current) { return current }
        throw Failure(
            "\(maxNextPresses) next presses never reached \(marks.sorted()); last was \(current ?? "unidentified").")
    }

    // Identify multi-photo screens by the public pattern; a missing probe must not veto a visible two-photo screen.
    func advanceToMultiPhotoScene(in orientation: StepOrientation = .notApplicable, maxNextPresses: Int = 6) throws {
        var observations: [[String: Any]] = []
        for press in 0...maxNextPresses {
            if press > 0 { next() }
            if Wait.held(
                timeout: Timing.multiPhotoWait, hold: Timing.multiPhotoHold,
                {
                    isShowingMultiPhotoScene(in: orientation)
                })
            {
                return
            }
            let current = snapshotNodes { $0.identifier == "slideshow.smartfill.currentManifest.flag" }
            let layers = snapshotNodes { $0.identifier == "slideshow.smartfill.manifest.flag" }
            observations.append([
                "next_presses": press,
                "current_probe_count": current.count,
                "current_scene_types": current.compactMap { manifestField("sceneType", in: $0.label) },
                "layer_probe_count": layers.count,
                "layer_scene_types": layers.compactMap { manifestField("sceneType", in: $0.label) }
            ])
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["schema": "strict-e2e-multi-scene-search-v1", "observations": observations],
            name: "multi-scene-search-diagnostic.json"
        )
        try Evidence().reject("multi-scene-search", png: app.screenshot().pngRepresentation)
        throw Failure(
            "Public fixture: no 2/3-photo scene within \(maxNextPresses) next presses; too few multi-photo frames.")
    }

    private func manifestField(_ key: String, in label: String) -> String? {
        label.split(separator: ";").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    // Collect only visible EXIF Fixture text. Take one snapshot of the whole tree so elements cannot vanish while
    // labels are read one by one.
    func visibleOverlayText() -> String {
        snapshotNodes { $0.elementType == .staticText && $0.label.contains("Fixture") }
            .map(\.label)
            .joined(separator: " | ")
    }

    func waitForClearCompletion() {
        XCTAssertTrue(
            Wait.until(timeout: Timing.clearCompletionTimeout) {
                let identifiers = Set(snapshotNodes { $0.identifier.hasPrefix("settings.cache.") }.map(\.identifier))
                return identifiers.contains("settings.cache.status.message")
                    && !identifiers.contains("settings.cache.clearing.status")
            },
            "After confirming the clear, the completion message must appear and the clearing status must go away."
        )
    }

    // Confirm both orientation and two-photo identity from actual screen pixels.
    func isShowingMultiPhotoScene(in orientation: StepOrientation = .notApplicable) -> Bool {
        guard orientation.matches(app.frame.size) else { return false }
        let png = StableFrame.uprightScreenPNG()
        guard let pixels = StableFrame.pixelSize(png), orientation.matches(pixels) else { return false }
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
        return identity.status == .match && (identity.mark?.split(separator: "+").count ?? 0) >= 2
    }

    private func snapshotNodes(where include: (XCUIElementSnapshot) -> Bool) -> [XCUIElementSnapshot] {
        guard let root = try? app.snapshot() else { return [] }
        var matched: [XCUIElementSnapshot] = []
        var pending: [XCUIElementSnapshot] = [root]
        while let node = pending.popLast() {
            if include(node) { matched.append(node) }
            pending.append(contentsOf: node.children)
        }
        return matched
    }
}
