import XCTest

enum StrictE2ELateImageError: Error {
    case fixtureControl
}

extension XCTestCase {
    func lateImageControl(input: StrictE2EInput, action: String? = nil) throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: input.serverURL + "/test/late-image"))
        var request = URLRequest(url: url)
        request.setValue(input.publicKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = TestWait.seconds(.infrastructure(5))
        if let action {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action])
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
        guard semaphore.wait(timeout: .now() + TestWait.seconds(.infrastructure(5))) == .success,
            status == 200, let payload,
            let state = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            state["expired"] as? Bool == false
        else {
            task.cancel()
            XCTFail(
                "Late image fixture control failed: hold action was not acknowledged"
            )
            throw StrictE2ELateImageError.fixtureControl
        }
        return state
    }

    func releaseLateImageAndWaitForDelivery(input: StrictE2EInput) throws {
        let held = try lateImageControl(input: input)
        guard held["asset_id"] as? String != nil, held["pending"] as? Int ?? 0 > 0,
            held["released"] as? Bool == false
        else {
            XCTFail(
                "Late image fixture control failed: no held response"
            )
            throw StrictE2ELateImageError.fixtureControl
        }
        _ = try lateImageControl(input: input, action: "release")
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.infrastructure(5))
        while ProcessInfo.processInfo.systemUptime < deadline {
            let state = try lateImageControl(input: input)
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
    func waitForLateImageCurrentScene(app: XCUIApplication) -> Bool {
        // The model can settle before the compositor. Readiness is separate from the one judged capture.
        let timeout = TestWait.seconds(.infrastructure(60))
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        var previousPNG: Data?
        var previousReferences: [String]?
        while ProcessInfo.processInfo.systemUptime < deadline {
            let before = strictSceneFrameObservation(app: app)
            let png = app.screenshotForFailureEvidence().pngRepresentation
            let after = strictSceneFrameObservation(app: app)
            let beforeRender = SharedSceneEvidenceManifest.parseKeyValueFields(before["render"] ?? "")
            let afterRender = SharedSceneEvidenceManifest.parseKeyValueFields(after["render"] ?? "")
            let beforeManifest = SharedSceneEvidenceManifest.parseKeyValueFields(before["manifest"] ?? "")
            let afterManifest = SharedSceneEvidenceManifest.parseKeyValueFields(after["manifest"] ?? "")
            let references = [
                beforeRender["layerIDs"] ?? "", beforeRender["historyCount"] ?? "",
                beforeManifest["ledgerSceneAssets"] ?? "", beforeManifest["scenePublishTimestamp"] ?? ""
            ]
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
        return false
    }

    @MainActor
    func waitForLateImageScene(app: XCUIApplication, historyCount: Int, deadline: TimeInterval) -> Bool {
        FirstFailureContext.beginWait(seconds: max(.zero, deadline - ProcessInfo.processInfo.systemUptime))
        defer {
            FirstFailureContext.endWait()
            FirstFailureContext.mark("wait-scene", element: "slideshow.control.next.button")
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            let observation = strictSceneFrameObservation(app: app)
            let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
            if Int(render["historyCount"] ?? "") == historyCount,
                render["playbackPaused"] == "true", StrictE2ESceneCapture.isStableWindow(observation)
            {
                return ProcessInfo.processInfo.systemUptime < deadline
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.05))))
        }
        return false
    }
}
