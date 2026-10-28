#if DEBUG
import CryptoKit
import Foundation
import ImageIO
import XCTest

/// Screenshot contents remain an independent verdict; the file channel supplies only temporal attribution.
@MainActor
final class LifecycleTimelineCapture {
    private let directory: URL
    private let nonce = UUID().uuidString
    private var proofs: [[String: Any]] = []
    private var actions: [[String: Any]] = []

    init() throws {
        guard let directory = StrictE2EVisualEvidence.directory() else {
            throw LifecycleTimelineJudge.Failure("missing evidence directory")
        }
        self.directory = directory
    }

    func launchTimelineApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "UI_TEST_PLAYBACK_LIFECYCLE_TIMELINE": "1", "UI_TEST_PLAYBACK_LIFECYCLE_NONCE": nonce,
            "UI_TEST_EVIDENCE_DIR": directory.path
        ]
        FirstFailureContext.mark("launch-app", element: "app-window")
        FirstFailureContext.action("launch") { app.launch() }
        return app
    }

    func readTimelineEvents() throws -> [LifecycleTimelineEvent] {
        let url = directory.appendingPathComponent("playback-lifecycle-timeline.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        // A concurrent append may leave one incomplete trailing line. It supplies no evidence until terminated.
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        let complete = data.last == 10 ? lines : Array(lines.dropLast())
        if complete.isEmpty { return [] }
        let events = try complete.map { try JSONDecoder().decode(LifecycleTimelineEvent.self, from: Data($0)) }
        try LifecycleTimelineJudge.validate(events)
        guard events.first?.caseNonce == nonce else { throw LifecycleTimelineJudge.Failure("case nonce mismatch") }
        return events
    }

    private func waitForTimelineEvents(
        guardWait: TestWait.HangGuard? = nil, _ predicate: ([LifecycleTimelineEvent]) -> Bool
    ) throws -> [LifecycleTimelineEvent] {
        let waiting = guardWait ?? TestWait.hangGuard()
        FirstFailureContext.beginWait(seconds: waiting.remainingSeconds)
        defer { FirstFailureContext.endWait() }
        repeat {
            let events = try readTimelineEvents()
            if predicate(events) { return events }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.infrastructure(0.05))))
        } while waiting.remainingSeconds > 0
        throw LifecycleTimelineJudge.Failure("missing required event")
    }

    @discardableResult
    private func checkpoint(
        clockHandshake: Bool = false, guardWait: TestWait.HangGuard? = nil
    ) throws -> LifecycleTimelineEvent {
        let request = (clockHandshake ? "clock-" : "checkpoint-") + UUID().uuidString
        let issued = ProcessInfo.processInfo.systemUptime
        try request.write(
            to: directory.appendingPathComponent("playback-lifecycle-request"), atomically: true, encoding: .utf8)
        let events = try waitForTimelineEvents(guardWait: guardWait) { $0.contains { $0.request == request } }
        let returned = ProcessInfo.processInfo.systemUptime
        guard let event = events.first(where: { $0.request == request }), issued <= event.uptime,
            event.uptime <= returned
        else {
            throw LifecycleTimelineJudge.Failure("runner and App uptime domains do not align")
        }
        if clockHandshake {
            proofs.append([
                "name": "clock-handshake", "runner_request": issued, "app_uptime": event.uptime,
                "runner_return": returned, "request": request
            ])
        }
        return event
    }

    private func performTimelineAction(_ name: String, perform: () throws -> Void) throws -> LifecycleTimelineEvent {
        let baseline = try readTimelineEvents().last?.sequence ?? 0
        let issued = ProcessInfo.processInfo.systemUptime
        try perform()
        let returned = ProcessInfo.processInfo.systemUptime
        let events = try waitForTimelineEvents { $0.contains { $0.sequence > baseline && $0.kind == name } }
        guard let receipt = events.first(where: { $0.sequence > baseline && $0.kind == name }) else {
            throw LifecycleTimelineJudge.Failure("missing action receipt")
        }
        actions.append([
            "name": name, "runner_issue": issued, "runner_return": returned,
            "app_receipt": receipt.uptime, "sequence": receipt.sequence
        ])
        return receipt
    }

    private func captureTimelineContent(
        _ name: String, expectedScene: String? = nil, excludingScene: String? = nil
    ) throws -> LifecycleTimelineEvent {
        let waiting = TestWait.hangGuard()
        var frozenReference: (frame: String, pixels: String, png: Data)?
        repeat {
            _ = try checkpoint(guardWait: waiting)
            let requested = ProcessInfo.processInfo.systemUptime
            let screenshot = XCUIScreen.main.screenshot()
            let returned = ProcessInfo.processInfo.systemUptime
            let png = screenshot.pngRepresentation
            _ = try checkpoint(guardWait: waiting)
            let events = try readTimelineEvents()
            if let state = try LifecycleTimelineJudge.contentState(events, request: requested, returned: returned),
                expectedScene.map({ state.scene == $0 }) ?? true,
                excludingScene.map({ state.scene != $0 }) ?? true
            {
                let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
                let mark: String
                var frozenProof: [String: Any] = [:]
                if state.isStable {
                    guard identity.status == .match, let observedMark = identity.mark,
                        let number = Int(observedMark.dropFirst()), observedMark.first == "A", (1...5).contains(number),
                        state.assets == [Self.hash("asset-a-\(number)")],
                        identity.meanLuma >= AccessLifecycleContract.newStableMarkMinimumLuma
                    else { throw LifecycleTimelineJudge.Failure("content contradicts stable or frozen timeline") }
                    mark = observedMark
                } else {
                    // A legitimate frozen dim frame need not brighten enough for identity classification.
                    guard state.kind == "frameFrozen", state.isPaused,
                        let anchor = proofs.last(where: {
                            $0["scene"] as? String == state.scene && $0["status"] as? String == "MATCH"
                        }),
                        let anchoredMark = anchor["mark"] as? String,
                        let pixels = Self.frozenPhotoPixels(png)
                    else { throw LifecycleTimelineJudge.Failure("missing frozen content anchor") }
                    guard let reference = frozenReference, reference.frame == state.frame else {
                        frozenReference = (state.frame, pixels, png)
                        continue
                    }
                    guard reference.pixels == pixels else {
                        throw LifecycleTimelineJudge.Failure("frozen photo pixels changed")
                    }
                    mark = anchoredMark
                    try StrictE2EVisualEvidence.writeRequiredPNG(reference.png, name: name + "-frozen-reference")
                    frozenProof = ["frozen_reference_sha256": Self.hash(reference.png), "frozen_pixels_sha256": pixels]
                }
                try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
                guard let photoPixels = Self.frozenPhotoPixels(png) else {
                    throw LifecycleTimelineJudge.Failure("unreadable photo pixels")
                }
                let source = CGImageSourceCreateWithData(png as CFData, nil)
                let properties =
                    source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
                proofs.append([
                    "name": name, "request": requested, "return": returned, "scene": state.scene,
                    "state_sequence": state.sequence, "mark": mark, "status": state.isStable ? "MATCH" : "FROZEN",
                    "mean_luma": identity.meanLuma, "png_sha256": Self.hash(png),
                    "photo_pixels_sha256": photoPixels,
                    "width": properties[kCGImagePropertyPixelWidth as String] ?? 0,
                    "height": properties[kCGImagePropertyPixelHeight as String] ?? 0,
                    "frozen_proof": frozenProof
                ])
                return state
            }
            // Crossing a transition is inconclusive; every requested proof must still obtain a conclusive capture.
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.infrastructure(0.1))))
        } while waiting.remainingSeconds > 0
        throw LifecycleTimelineJudge.Failure("missing conclusive content proof")
    }

    func exercisePauseContinueTimeline(
        interval: Int, pause: () throws -> Void, next: () throws -> Void, resume: () throws -> Void,
        prepareFinalResume: () throws -> Void, finalResume: () throws -> Void
    ) throws {
        _ = try checkpoint(clockHandshake: true)
        _ = try performTimelineAction("pauseReceived", perform: pause)
        let setupNext = try performTimelineAction("manualNavigationReceived", perform: next)
        let start = try captureTimelineContent("timeline-start", excludingScene: setupNext.scene)
        let firstContinue = try performTimelineAction("continueReceived", perform: resume)
        waitUntilUptime(firstContinue.uptime + Double(interval) / 2)
        let midpointPause = try performTimelineAction("pauseReceived", perform: pause)
        try LifecycleTimelineJudge.judgeMidpointPause(
            readTimelineEvents(), continueSequence: firstContinue.sequence, pauseSequence: midpointPause.sequence,
            interval: Double(interval))
        _ = try captureTimelineContent("timeline-midpoint-pause", expectedScene: start.scene)
        _ = try performTimelineAction("manualNavigationReceived", perform: next)
        let nextScene = try captureTimelineContent("timeline-after-next", excludingScene: start.scene)
        let heldPhotoPixels = proofs.last?["photo_pixels_sha256"] as? String
        guard nextScene.scene != start.scene, nextScene.assets != start.assets else {
            throw LifecycleTimelineJudge.Failure("Next did not change photo")
        }
        let holdStart = try checkpoint()
        waitUntilUptime(holdStart.uptime + Double(interval) + 2)
        let holdEnd = try checkpoint()
        guard holdEnd.uptime - holdStart.uptime >= Double(interval) + 2 else {
            throw LifecycleTimelineJudge.Failure("pause hold shorter than T+2")
        }
        _ = try captureTimelineContent("timeline-after-hold", expectedScene: nextScene.scene)
        guard let heldPhotoPixels, proofs.last?["photo_pixels_sha256"] as? String == heldPhotoPixels else {
            throw LifecycleTimelineJudge.Failure("frozen photo pixels changed")
        }
        try prepareSIGSTOPIfRequested()
        try prepareFinalResume()
        let receipt = try performTimelineAction("continueReceived", perform: finalResume)
        _ = try captureTimelineContent("timeline-continue-early", expectedScene: nextScene.scene)
        let events = try waitForTimelineEvents { events in
            events.contains { $0.sequence > receipt.sequence && $0.kind == "sceneStable" && $0.scene != receipt.scene }
        }
        let judgment = try LifecycleTimelineJudge.judge(
            events, continueSequence: receipt.sequence, interval: Double(interval))
        guard let stable = events.first(where: { $0.sequence == judgment.stableSequence }) else {
            throw LifecycleTimelineJudge.Failure("missing stable event")
        }
        _ = try captureTimelineContent("timeline-after-auto", expectedScene: stable.scene)
        _ = try checkpoint()
        let finalEvents = try readTimelineEvents()
        _ = try LifecycleTimelineJudge.judge(
            finalEvents, continueSequence: receipt.sequence, interval: Double(interval))
        let judgmentData = try JSONEncoder().encode(judgment)
        let judgmentObject = try JSONSerialization.jsonObject(with: judgmentData)
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "schema_version": 1, "suite": "lifecycle-pause-app-timeline", "verdict": "PASS",
                "case_nonce": nonce, "launch_nonce": finalEvents[0].launchNonce, "event_count": finalEvents.count,
                "timeline_sha256": Self.hash(
                    try Data(contentsOf: directory.appendingPathComponent("playback-lifecycle-timeline.jsonl"))
                        .split(separator: 10).prefix(finalEvents.count).reduce(into: Data()) { $0 += $1 + Data([10]) }),
                "interval": interval, "judgment": judgmentObject, "actions": actions, "content_checks": proofs
            ], name: "app-timeline-verdict.json")
    }

    private func prepareSIGSTOPIfRequested() throws {
        guard
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("playback-lifecycle-inject-stop").path)
        else { return }
        try "ready".write(
            to: directory.appendingPathComponent("playback-lifecycle-before-continue"), atomically: true,
            encoding: .utf8)
        let waiting = TestWait.hangGuard()
        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("playback-lifecycle-stop-armed").path)
        {
            guard waiting.remainingSeconds > 0 else {
                throw LifecycleTimelineJudge.Failure("missing SIGSTOP handshake")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.infrastructure(0.05))))
        }
    }

    private func waitUntilUptime(_ target: TimeInterval) {
        while ProcessInfo.processInfo.systemUptime < target {
            RunLoop.current.run(
                until: Date().addingTimeInterval(
                    min(TestWait.seconds(.infrastructure(0.05)), target - ProcessInfo.processInfo.systemUptime)))
        }
    }

    private static func hash(_ value: String) -> String { hash(Data(value.utf8)) }
    private static func frozenPhotoPixels(_ png: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let crop = image.cropping(
                to: CGRect(
                    // EXIF animates at the top and controls auto-hide at the bottom independently of Pause.
                    x: Double(image.width) * 0.1, y: Double(image.height) * 0.3,
                    width: Double(image.width) * 0.8, height: Double(image.height) * 0.3
                ).integral)
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        return didDraw ? hash(Data(pixels)) : nil
    }
    private static func hash(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
