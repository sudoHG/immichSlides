import XCTest

#if os(iOS)
final class StrictE2ELateImageIOSUITests: XCTestCase, StrictE2EOnboardingIOS {
    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    private let lateRequestSettleSeconds: TimeInterval = TestWait.seconds(.product(1.5))

    override func setUpWithError() throws {
        continueAfterFailure = false
        FirstFailureOrientation.set(.portrait)
    }

    // Seam: the public frame after the second next, before and after an explicitly released old response.
    @MainActor
    func testLateImageKeepsCurrentSceneAfterLateRequest() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp(recordSceneSequence: true)
        defer { app.terminateForFailureEvidence() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "late-image")
        dismissSavePasswordPromptIfShown(app: app, deadline: Date().addingTimeInterval(TestWait.seconds(.product(2))))
        _ = try lateImageControl(input: input, action: "arm")
        try enterPlaybackThenAdvanceTwice(app: app)

        let currentFrame = try captureRequiredIdentity(app: app, name: "ooo-current-scene")
        try recordFixtureState(input: input, name: "late-image-held")
        try releaseLateImageAndWaitForDelivery(input: input)
        let deliveryReturnedAt = ProcessInfo.processInfo.systemUptime
        try recordFixtureState(input: input, name: "late-image-delivered")
        // firstPreload can reveal the entry hint only after the held response completes.
        let samplingWindow = dismissEntryHintDuringLateResponseWindow(
            app: app, deadline: deliveryReturnedAt + lateRequestSettleSeconds)
        try StrictE2EVisualEvidence.writeRequiredJSON(samplingWindow, name: "late-image-sampling-window.json")
        XCTAssertTrue(
            samplingWindow["hint_hidden_within_window"] as? Bool == true,
            "After late completion the current public mark must stay: no flash back, all black or unreadable: entry hint deadline"
        )
        let afterFrame = try captureRequiredIdentity(app: app, name: "ooo-after-late")
        XCTAssertEqual(
            sceneIdentity(currentFrame.after), sceneIdentity(afterFrame.before),
            "After late completion the current public mark must stay: no flash back, all black or unreadable: scene changed"
        )
        let current = currentFrame.identity
        let afterLate = afterFrame.identity

        guard current.status == .match,
            afterLate.status == .match,
            let currentMark = current.mark,
            !currentMark.split(separator: "+").contains("A1"),
            currentMark == afterLate.mark
        else {
            XCTFail(
                "After late completion the current public mark must stay: no flash back, all black or unreadable: "
                    + "ooo-current-scene=\(current.status.rawValue)/\(current.mark ?? "nil") "
                    + "ooo-after-late=\(afterLate.status.rawValue)/\(afterLate.mark ?? "nil")"
            )
            return
        }

        let visualIdentity: [String: Any] = [
            "suite": "late-image",
            "device": currentDeviceTag(),
            "identity_source": "public_fixture_photo_mark",
            "mark": currentMark,
            "ooo-current-scene": StrictE2EPhotoIdentity.payload(current),
            "ooo-after-late": StrictE2EPhotoIdentity.payload(afterLate)
        ]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(visualIdentity), "The identity JSON must be serializable.")
        try StrictE2EVisualEvidence.writeRequiredJSON(visualIdentity, name: "visual-identity.json")
    }

    @MainActor
    private func enterPlaybackThenAdvanceTwice(app: XCUIApplication) throws {
        guard
            let playbackDeadline = IOSFirstBootNavigation(app: app).selectModeAndContinue(
                "mode.random.button", destinationIdentifier: "slideshow.control.next.button",
                selectionTimeout: TestWait.seconds(.product(8)) + TestWait.seconds(.product(2)),
                departureTimeout: TestWait.seconds(.product(8)))
        else { return }
        let next = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            next.waitForPublicElement(
                "slideshow.control.next.button", timeout: max(.zero, playbackDeadline.timeIntervalSinceNow)),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        if app.evidenceSnapshotsByIdentifier()["slideshow.entryHint.banner"] != nil {
            tapElement(app.descendants(matching: .any)["slideshow.entryHint.banner"])
        }
        XCTAssertTrue(
            revealLateImageControls(app: app),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        let playPause = app.buttons["slideshow.control.playPause.button"]
        let observedPlayPauseState = (try? playPause.snapshot()).map({ playPauseState($0) })
        var playPauseTap: [String: Any] = ["control_state": observedPlayPauseState ?? "unknown", "tap_issued": false]
        if observedPlayPauseState != "play" {
            let probeStartedAt = Date().timeIntervalSince1970
            let observation = strictSceneFrameObservation(app: app)
            playPauseTap["scene_probe"] = pauseProbeEvidence(observation, startedAt: probeStartedAt)
            playPauseTap["tap_issued"] = true
            playPauseTap["tap_issued_unix"] = Date().timeIntervalSince1970
            tapElement(playPause)
            playPauseTap["tap_returned_unix"] = Date().timeIntervalSince1970
        }
        var pausedHistoryCount: Int?
        var didDeclinePrompt = false
        var didObservePrompt = false
        var hasPromptObstacle = false
        var promptChecks: [[String: Any]] = []
        let waitDeadline = Date().addingTimeInterval(TestWait.seconds(.product(2)))
        let promptDeadline = min(waitDeadline, playbackDeadline)
        let isPauseReady = waitUntil(timeout: max(.zero, waitDeadline.timeIntervalSinceNow)) {
            let startedAt = Date().timeIntervalSince1970
            var didDeclineThisRound = false
            let navigation = IOSFirstBootNavigation(app: app)
            let isPromptGone = navigation.dismissPasswordPrompt(until: promptDeadline) {
                didDeclineThisRound = true
                didDeclinePrompt = true
                didObservePrompt = true
                print("Late-image pause-readiness prompt decline returned")
            }
            var promptState = "absent"
            hasPromptObstacle = false
            if !isPromptGone {
                // An expired deadline also returns false without a prompt; that alone is not a failure.
                if let observation = try? navigation.observe() {
                    hasPromptObstacle = observation.hasPasswordPrompt
                    didObservePrompt = didObservePrompt || observation.hasPasswordPrompt
                    promptState = observation.hasPasswordPrompt ? "present" : "absent"
                } else {
                    hasPromptObstacle = true
                    promptState = "unknown"
                }
            }
            var check: [String: Any] = [
                "started_unix": startedAt, "returned_unix": Date().timeIntervalSince1970,
                "helper_returned": isPromptGone, "prompt_declined": didDeclineThisRound, "prompt_state": promptState,
                "probe_read_status": hasPromptObstacle ? "not_read_prompt_obstacle" : "not_read_deadline"
            ]
            defer { promptChecks.append(check) }
            guard !hasPromptObstacle, Date() < waitDeadline else { return false }
            let probeStartedAt = Date().timeIntervalSince1970
            let observation = self.strictSceneFrameObservation(app: app)
            check["probe_read_status"] = "read"
            check["scene_probe"] = self.pauseProbeEvidence(observation, startedAt: probeStartedAt)
            let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
            guard render["playbackPaused"] == "true", let count = Int(render["historyCount"] ?? "") else {
                return false
            }
            pausedHistoryCount = count
            return true
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "wait_deadline_unix": waitDeadline.timeIntervalSince1970,
                "departure_deadline_unix": playbackDeadline.timeIntervalSince1970,
                "prompt_deadline_unix": promptDeadline.timeIntervalSince1970,
                "prompt_declined": didDeclinePrompt, "prompt_observed": didObservePrompt,
                "prompt_checks": promptChecks, "pause_ready": isPauseReady, "play_pause_tap": playPauseTap
            ], name: "late-image-playback-entry.json")
        guard isPauseReady else {
            FirstFailureContext.mark("wait-scene", element: "slideshow.control.playPause.button")
            if hasPromptObstacle {
                XCTFail(
                    "Environment precondition: the system password prompt must be absent before late-image pause readiness."
                )
            } else {
                XCTFail(
                    "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
            }
            return
        }
        let initialHistory = try XCTUnwrap(pausedHistoryCount)
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.product(8))
        FirstFailureContext.mark("select", element: "slideshow.control.next.button")
        tapElement(next)
        XCTAssertTrue(
            waitForLateImageScene(app: app, historyCount: initialHistory + 1, deadline: deadline),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        XCTAssertTrue(
            revealLateImageControls(app: app),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        tapElement(next)
        XCTAssertTrue(
            waitForLateImageScene(app: app, historyCount: initialHistory + 2, deadline: deadline),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
    }

    private func pauseProbeEvidence(_ observation: [String: String], startedAt: TimeInterval) -> [String: Any] {
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
        let scene = SharedSceneEvidenceManifest.manifestObservation(from: observation["manifest"] ?? "")
        let layerCount: Any =
            render["layerIDs"].map { ($0 == "none" ? 0 : $0.split(separator: "|").count) as Any } ?? NSNull()
        return [
            "started_unix": startedAt, "returned_unix": Date().timeIntervalSince1970, "raw": observation,
            "scene_probe_status": render.isEmpty ? "absent_or_unreadable" : "present",
            "playbackPaused": render["playbackPaused"] ?? "unknown", "phase": render["phase"] ?? "unknown",
            "scene_status": scene.map { $0.isCompleteVisibleScene ? "complete" : "incomplete" } ?? "unavailable",
            "layer_count": layerCount
        ]
    }

    @MainActor
    private func revealLateImageControls(app: XCUIApplication) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.product(8))
        let promptDeadline = Date().addingTimeInterval(TestWait.seconds(.product(8)))
        return waitUntil(timeout: TestWait.seconds(.product(8))) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            self.dismissSavePasswordPromptIfShown(app: app, deadline: promptDeadline)
            if let next = app.evidenceSnapshotsByIdentifier()["slideshow.control.next.button"], next.isEnabled {
                return ProcessInfo.processInfo.systemUptime < deadline
            }
            app.tapForFailureEvidence()
            return false
        }
    }

    @MainActor
    private func dismissEntryHintDuringLateResponseWindow(app: XCUIApplication, deadline: TimeInterval) -> [String: Any]
    {
        var didTapHint = false
        var sawHint = false
        var hintEvents: [[String: Any]] = []
        var didObserveHiddenAfterTap = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let observation = lateImageSceneObservation(app: app)
            if observation["entryHintVisible"] == "true" { sawHint = true }
            if observation["entryHintVisible"] == "true", !didTapHint {
                let banner = app.descendants(matching: .any)["slideshow.entryHint.banner"]
                if banner.isHittable, ProcessInfo.processInfo.systemUptime < deadline {
                    let issuedAt = Date().timeIntervalSince1970
                    banner.tapForFailureEvidence()
                    didTapHint = true
                    hintEvents.append(["tap_issued_unix": issuedAt, "tap_returned_unix": Date().timeIntervalSince1970])
                }
            } else if didTapHint, observation["entryHintVisible"] == "false", !didObserveHiddenAfterTap,
                ProcessInfo.processInfo.systemUptime < deadline
            {
                didObserveHiddenAfterTap = true
                hintEvents.append(["hidden_observed_unix": observation["observed_unix"] ?? ""])
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(min(TestWait.seconds(.product(0.05)), remaining)))
            }
        }
        return [
            "deadline_uptime": deadline, "returned_uptime": ProcessInfo.processInfo.systemUptime,
            "hint_events": hintEvents, "saw_hint": sawHint,
            "hint_hidden_within_window": !sawHint || didObserveHiddenAfterTap
        ]
    }

    private func recordFixtureState(input: StrictE2EInput, name: String) throws {
        let state = try lateImageControl(input: input)
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["observed_unix": Date().timeIntervalSince1970, "fixture": state], name: "\(name).json")
    }

    @MainActor
    private func lateImageSceneObservation(app: XCUIApplication) -> [String: String] {
        var didSnapshotFail = false
        let snapshots = app.evidenceSnapshotsByIdentifier { _ in didSnapshotFail = true }
        return [
            "manifest": snapshots["slideshow.smartfill.currentManifest.flag"]?.label ?? "",
            "render": snapshots["slideshow.scenePresentation.contract.summary"]?.label ?? "",
            "entryHintVisible": didSnapshotFail ? "unknown" : String(snapshots["slideshow.entryHint.banner"] != nil),
            "observed_unix": String(Date().timeIntervalSince1970)
        ]
    }

    private func sceneIdentity(_ observation: [String: String]) -> [String: String] {
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
        let manifest = SharedSceneEvidenceManifest.parseKeyValueFields(observation["manifest"] ?? "")
        return [
            "layerIDs": render["layerIDs"] ?? "", "historyCount": render["historyCount"] ?? "",
            "ledgerSceneAssets": manifest["ledgerSceneAssets"] ?? "",
            "scenePublishTimestamp": manifest["scenePublishTimestamp"] ?? ""
        ]
    }

    private struct CapturedScene {
        let identity: StrictE2EPhotoIdentity.Result
        let before: [String: String]
        let after: [String: String]
    }

    @MainActor
    private func captureRequiredIdentity(app: XCUIApplication, name: String) throws -> CapturedScene {
        let before = lateImageSceneObservation(app: app)
        let captureRequestedAt = Date().timeIntervalSince1970
        let png = app.screenshotForFailureEvidence().pngRepresentation
        let captureReturnedAt = Date().timeIntervalSince1970
        let after = lateImageSceneObservation(app: app)
        XCTAssertFalse(png.isEmpty, "The playback screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        attachStrictSceneObservation(before: before, after: after, name: "\(name)-scene")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "before": before, "after": after,
                "capture_requested_unix": captureRequestedAt, "capture_returned_unix": captureReturnedAt
            ], name: "\(name)-window.json")
        FirstFailureContext.mark("capture-frame", element: "app-window")
        XCTAssertTrue(
            [before, after].allSatisfy {
                StrictE2ESceneCapture.isStableWindow($0) && $0["entryHintVisible"] == "false"
                    && SharedSceneEvidenceManifest.parseKeyValueFields($0["render"] ?? "")["playbackPaused"] == "true"
            } && sceneIdentity(before) == sceneIdentity(after),
            "After late completion the current public mark must stay: no flash back, all black or unreadable: unstable capture"
        )
        return CapturedScene(identity: StrictE2EPhotoIdentity.captureIdentity(png: png), before: before, after: after)
    }
}
#endif
