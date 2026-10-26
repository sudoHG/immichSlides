import XCTest

enum StrictE2ELateImageError: Error {
    case fixtureControl
    case heldBudget
}

@MainActor
final class StrictE2ELateImageHold {
    // Leave two seconds of the App's 15-second download timeout for release and delivery.
    static let downloadTimeoutSeconds: TimeInterval = TestWait.seconds(.product(15))
    static let releaseMarginSeconds: TimeInterval = TestWait.seconds(.product(2))
    let armedAt: TimeInterval
    let armedElapsedMilliseconds: Double
    private(set) var deadline: TimeInterval?
    private var steps: [[String: Any]] = []
    private var heldStartedAt: TimeInterval?
    private var releasedAt: TimeInterval?

    init(armedAt: TimeInterval, state: [String: Any]) throws {
        self.armedAt = armedAt
        armedElapsedMilliseconds = try XCTUnwrap(state["armed_elapsed_ms"] as? Double)
    }

    func observe(_ state: [String: Any]) throws {
        guard deadline == nil, let started = state["hold_started_elapsed_ms"] as? Double else { return }
        // The arm request's issue time is a conservative anchor for the server's elapsed clock.
        let heldStart = armedAt + (started - armedElapsedMilliseconds) / 1000
        heldStartedAt = heldStart
        deadline = heldStart + Self.downloadTimeoutSeconds - Self.releaseMarginSeconds
        try check()
    }

    func check() throws {
        if releasedAt == nil, let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
            try writeEvidence()
            // Summarize only test-owned step names and time spent after the hold began.
            let longest = steps.compactMap { step -> (name: String, seconds: TimeInterval)? in
                guard let heldStartedAt, let name = step["name"] as? String,
                    let started = step["started_uptime"] as? TimeInterval,
                    let returned = step["returned_uptime"] as? TimeInterval
                else { return nil }
                let seconds = returned - max(started, heldStartedAt)
                return seconds > 0 ? (name, seconds) : nil
            }.max { $0.seconds < $1.seconds }
            let summary = longest.map { "\($0.name) (\(String(format: "%.3f", $0.seconds))s)" } ?? "none (0.000s)"
            XCTFail(
                "Held response budget exhausted before release: invalid late-image run; longest held step=\(summary)")
            throw StrictE2ELateImageError.heldBudget
        }
    }

    func remaining(maximum: TimeInterval) throws -> TimeInterval {
        try check()
        return min(maximum, max(.zero, (deadline ?? .infinity) - ProcessInfo.processInfo.systemUptime))
    }

    func perform<T>(_ name: String, _ operation: () throws -> T) throws -> T {
        try check()
        let started = ProcessInfo.processInfo.systemUptime
        let value: T
        do {
            value = try operation()
        } catch {
            try recordStep(name, started: started)
            throw error
        }
        try recordStep(name, started: started)
        try check()
        return value
    }

    func waitUntil(_ name: String, maximum: TimeInterval, condition: () -> Bool) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + (try remaining(maximum: maximum))
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try perform(name, condition) { return ProcessInfo.processInfo.systemUptime < deadline }
            let remainingSeconds = deadline - ProcessInfo.processInfo.systemUptime
            if remainingSeconds > 0 {
                RunLoop.current.run(
                    until: Date().addingTimeInterval(min(TestWait.seconds(.product(0.05)), remainingSeconds)))
            }
        }
        try check()
        return false
    }

    private func recordStep(_ name: String, started: TimeInterval) throws {
        let returned = ProcessInfo.processInfo.systemUptime
        steps.append([
            "name": name, "started_uptime": started, "returned_uptime": returned,
            "duration_seconds": returned - started
        ])
        print("Late-image held step: \(name) duration_seconds=\(returned - started)")
        try writeEvidence()
    }

    func released() throws {
        releasedAt = ProcessInfo.processInfo.systemUptime
        try writeEvidence()
    }

    func writeEvidence() throws {
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "armed_uptime": armedAt, "held_started_uptime": heldStartedAt as Any? ?? NSNull(),
                "deadline_uptime": deadline as Any? ?? NSNull(), "released_uptime": releasedAt as Any? ?? NSNull(),
                "observed_hold_seconds": heldStartedAt.map { (releasedAt ?? ProcessInfo.processInfo.systemUptime) - $0 }
                    as Any? ?? NSNull(),
                "release_delivery_margin_seconds": Self.releaseMarginSeconds, "steps": steps
            ],
            name: "late-image-held-window.json")
    }
}

extension XCTestCase {
    @MainActor
    func captureStep<T>(_ name: String, hold: StrictE2ELateImageHold?, _ operation: () -> T) throws -> T {
        if let hold { return try hold.perform("judged-current-" + name, operation) }
        return operation()
    }

    @MainActor
    func lateImageControl(
        input: StrictE2EInput, action: String? = nil, timeout: TimeInterval? = nil,
        hold: StrictE2ELateImageHold? = nil, selectInitialAsset: Bool = false
    ) throws -> [String:
        Any]
    {
        let url = try XCTUnwrap(URL(string: input.serverURL + "/test/late-image"))
        var request = URLRequest(url: url)
        request.setValue(input.publicKey, forHTTPHeaderField: "x-api-key")
        let timeout = timeout ?? TestWait.seconds(.infrastructure(5))
        request.timeoutInterval = timeout
        if let action {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["action": action]
            if selectInitialAsset { body["selection"] = "initial-primary" }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status: Int?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success,
            status == 200, let payload,
            let state = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            state["expired"] as? Bool == false
        else {
            task.cancel()
            try hold?.check()
            XCTFail(
                "Late image fixture control failed: hold action was not acknowledged"
            )
            throw StrictE2ELateImageError.fixtureControl
        }
        return state
    }

    @MainActor
    func armLateImageHold(input: StrictE2EInput) throws -> StrictE2ELateImageHold {
        let issuedAt = ProcessInfo.processInfo.systemUptime
        let state = try lateImageControl(input: input, action: "arm", selectInitialAsset: true)
        _ = try XCTUnwrap(
            state["selected_asset_id"] as? String, "Late image fixture control failed: selection was not acknowledged")
        return try StrictE2ELateImageHold(armedAt: issuedAt, state: state)
    }

    @MainActor
    func synchronizeLateImageHold(input: StrictE2EInput, hold: StrictE2ELateImageHold) throws {
        let waitDeadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.product(5))
        while ProcessInfo.processInfo.systemUptime < waitDeadline {
            try hold.observe(lateImageControl(input: input, timeout: TestWait.seconds(.product(1))))
            if hold.deadline != nil { return }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.05))))
        }
        XCTFail("Late image fixture control failed: no held response after cold launch")
        throw StrictE2ELateImageError.fixtureControl
    }

    @MainActor
    func releaseLateImageAndWaitForDelivery(input: StrictE2EInput, hold: StrictE2ELateImageHold) throws {
        let held = try hold.perform("fixture-before-release") {
            try lateImageControl(
                input: input, timeout: hold.remaining(maximum: TestWait.seconds(.product(1))), hold: hold)
        }
        guard held["asset_id"] as? String != nil, held["pending"] as? Int ?? 0 > 0,
            held["released"] as? Bool == false
        else {
            XCTFail(
                "Late image fixture control failed: no held response"
            )
            throw StrictE2ELateImageError.fixtureControl
        }
        _ = try hold.perform("release") {
            try lateImageControl(
                input: input, action: "release", timeout: hold.remaining(maximum: TestWait.seconds(.product(1))),
                hold: hold)
        }
        try hold.released()
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.product(1))
        while ProcessInfo.processInfo.systemUptime < deadline {
            let state = try lateImageControl(
                input: input,
                timeout: max(TestWait.seconds(.product(0.001)), deadline - ProcessInfo.processInfo.systemUptime))
            if state["pending"] as? Int == 0, state["delivered"] as? Int ?? 0 > 0,
                state["disconnected"] as? Int == 0
            {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.05))))
        }
        XCTFail(
            "Late image fixture control failed: held response was not delivered"
        )
        throw StrictE2ELateImageError.fixtureControl
    }

    @MainActor
    func waitForLateImageCurrentScene(app: XCUIApplication, hold: StrictE2ELateImageHold) throws -> Bool {
        // The model can settle before the compositor. Readiness is separate from the one judged capture.
        let timeout = try hold.remaining(maximum: .infinity)
        let deadline = try XCTUnwrap(hold.deadline)
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        var previousPNG: Data?
        var previousReferences: [String]?
        while ProcessInfo.processInfo.systemUptime < deadline {
            let before = try hold.perform("current-readiness-probe") { strictSceneFrameObservation(app: app) }
            let beforeRender = SharedSceneEvidenceManifest.parseKeyValueFields(before["render"] ?? "")
            let beforeManifest = SharedSceneEvidenceManifest.parseKeyValueFields(before["manifest"] ?? "")
            let references = [
                beforeRender["layerIDs"] ?? "", beforeRender["historyCount"] ?? "",
                beforeManifest["ledgerSceneAssets"] ?? "", beforeManifest["scenePublishTimestamp"] ?? ""
            ]
            guard StrictE2ESceneCapture.isStableWindow(before), beforeRender["playbackPaused"] == "true",
                references.allSatisfy({ !$0.isEmpty })
            else {
                previousPNG = nil
                previousReferences = nil
                RunLoop.current.run(
                    until: Date().addingTimeInterval(try hold.remaining(maximum: TestWait.seconds(.product(0.1)))))
                continue
            }
            let png = try hold.perform("current-readiness-screenshot") {
                app.screenshotForFailureEvidence().pngRepresentation
            }
            let after = try hold.perform("current-readiness-after-probe") { strictSceneFrameObservation(app: app) }
            let afterRender = SharedSceneEvidenceManifest.parseKeyValueFields(after["render"] ?? "")
            let afterManifest = SharedSceneEvidenceManifest.parseKeyValueFields(after["manifest"] ?? "")
            let afterReferences = [
                afterRender["layerIDs"] ?? "", afterRender["historyCount"] ?? "",
                afterManifest["ledgerSceneAssets"] ?? "", afterManifest["scenePublishTimestamp"] ?? ""
            ]
            if [before, after].allSatisfy(StrictE2ESceneCapture.isStableWindow),
                beforeRender["playbackPaused"] == "true", afterRender["playbackPaused"] == "true",
                references.allSatisfy({ !$0.isEmpty }), references == afterReferences,
                StrictE2EPhotoIdentity.captureIdentity(png: png).status == .match
            {
                if previousReferences == references, previousPNG == png { return true }
                previousReferences = references
                previousPNG = png
            } else {
                previousReferences = nil
                previousPNG = nil
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(min(TestWait.seconds(.product(0.1)), remaining)))
            }
        }
        try hold.check()
        return false
    }

    @MainActor
    func waitForLateImageScene(
        app: XCUIApplication, historyCount: Int, deadline: TimeInterval, hold: StrictE2ELateImageHold
    ) throws -> Bool {
        FirstFailureContext.beginWait(seconds: max(.zero, deadline - ProcessInfo.processInfo.systemUptime))
        defer {
            FirstFailureContext.endWait()
            FirstFailureContext.mark("wait-scene", element: "slideshow.control.next.button")
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            let observation = try hold.perform("next-readiness-probe") { strictSceneFrameObservation(app: app) }
            let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
            if Int(render["historyCount"] ?? "") == historyCount,
                render["playbackPaused"] == "true", StrictE2ESceneCapture.isStableWindow(observation)
            {
                return ProcessInfo.processInfo.systemUptime < deadline
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(try hold.remaining(maximum: TestWait.seconds(.product(0.05)))))
        }
        try hold.check()
        return false
    }

    @MainActor
    func recordLateImageInitialScene(app: XCUIApplication, input: StrictE2EInput, hold: StrictE2ELateImageHold) throws {
        let observation = try hold.perform("initial-scene-probe") { strictSceneFrameObservation(app: app) }
        let state = try hold.perform("initial-held-state") {
            try lateImageControl(
                input: input, timeout: hold.remaining(maximum: TestWait.seconds(.product(1))), hold: hold)
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["before_first_next": observation, "fixture": state], name: "late-image-initial-scene.json")
        let manifest = SharedSceneEvidenceManifest.parseKeyValueFields(observation["manifest"] ?? "")
        let assets = (manifest["ledgerSceneAssets"] ?? "").split(separator: ",").map(String.init)
        XCTAssertTrue(
            (state["asset_id"] as? String).map {
                assets.contains("asset-" + SmartFillRuntimeEvidenceSupport.stableHash($0))
            } == true,
            "Late image held asset must belong to the cold-launch scene before the first Next.")
    }
}
