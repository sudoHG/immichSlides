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
                "After late completion the current public mark must stay: no flash back, all black or unreadable: fixture hold failed"
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
                "After late completion the current public mark must stay: no flash back, all black or unreadable: no held response"
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
            "After late completion the current public mark must stay: no flash back, all black or unreadable: held response was not delivered"
        )
        throw StrictE2ELateImageError.fixtureControl
    }

    @MainActor
    func waitForLateImageScene(app: XCUIApplication, historyCount: Int, deadline: TimeInterval) -> Bool {
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
