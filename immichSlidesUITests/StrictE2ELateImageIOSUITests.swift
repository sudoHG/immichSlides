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
        let app = try launchStrictE2EApp(recordSceneSequence: true, disablePlaybackEntryHint: true)
        defer { app.terminateForFailureEvidence() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "late-image")
        dismissSavePasswordPromptIfShown(app: app, deadline: Date().addingTimeInterval(TestWait.seconds(.product(2))))
        try enterPlaybackThenAdvanceTwice(app: app)
        try preparePausedColdLaunch(app: app)
        _ = try lateImageControl(input: input, action: "arm")
        FirstFailureContext.mark("launch-app", element: "app-window")
        FirstFailureContext.action("launch") { app.launch() }
        try enterPlaybackThenAdvanceTwice(app: app, isColdRelaunch: true)

        XCTAssertTrue(
            waitForLateImageCurrentScene(app: app),
            "After late completion the current public mark must stay: no flash back, all black or unreadable: unstable capture"
        )
        let currentFrame = try captureRequiredIdentity(app: app, name: "ooo-current-scene")
        try recordFixtureState(input: input, name: "late-image-held")
        try releaseLateImageAndWaitForDelivery(input: input)
        let deliveryReturnedAt = ProcessInfo.processInfo.systemUptime
        try recordFixtureState(input: input, name: "late-image-delivered")
        let remaining = deliveryReturnedAt + lateRequestSettleSeconds - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { RunLoop.current.run(until: Date().addingTimeInterval(remaining)) }
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
    private func enterPlaybackThenAdvanceTwice(app: XCUIApplication, isColdRelaunch: Bool = false) throws {
        let playbackDeadline: Date
        if isColdRelaunch {
            playbackDeadline = Date().addingTimeInterval(TestWait.seconds(.product(8)))
        } else {
            guard
                let enteredDeadline = IOSFirstBootNavigation(app: app).selectModeAndContinue(
                    "mode.random.button", destinationIdentifier: "slideshow.control.next.button")
            else { return }
            playbackDeadline = enteredDeadline.deadline
        }
        let next = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            next.waitForPublicElement(
                "slideshow.control.next.button", timeout: max(.zero, playbackDeadline.timeIntervalSinceNow)),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        XCTAssertTrue(
            revealLateImageControls(app: app),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        let playPause = app.buttons["slideshow.control.playPause.button"]
        let observedPlayPauseState = (try? playPause.snapshot()).map({ playPauseState($0) })
        var playPauseTap: [String: Any] = ["control_state": observedPlayPauseState ?? "unknown", "tap_issued": false]
        if isColdRelaunch {
            XCTAssertEqual(
                observedPlayPauseState, "play",
                "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        } else if observedPlayPauseState != "play" {
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
            let isPromptGone =
                isColdRelaunch
                || navigation.dismissPasswordPrompt(until: promptDeadline) {
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
            ], name: isColdRelaunch ? "late-image-playback-entry.json" : "late-image-preparation-entry.json")
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
        XCTAssertTrue(
            revealLateImageControls(app: app),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
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

    @MainActor
    private func preparePausedColdLaunch(app: XCUIApplication) throws {
        let driver = IOSDriver(app: app)
        _ = driver.openSettings()
        let autoPlay = app.switches["settings.playback.autoPlay.toggle"]
        if !autoPlay.waitForPublicElement(
            "settings.playback.autoPlay.toggle", timeout: TestWait.seconds(.product(2)))
        {
            let playback = app.buttons["settings.item.playback"]
            XCTAssertTrue(
                playback.waitForPublicElement("settings.item.playback", timeout: TestWait.seconds(.product(8))),
                "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
            tapElement(playback)
        }
        XCTAssertTrue(
            autoPlay.waitForPublicElement("settings.playback.autoPlay.toggle", timeout: TestWait.seconds(.product(8))),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        if (try? autoPlay.snapshot()).map({ String(describing: $0.value ?? "") }) != "0" {
            tapElement(autoPlay)
        }
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(8))) {
                (try? autoPlay.snapshot()).map { String(describing: $0.value ?? "") } == "0"
            },
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        driver.returnToPlayback()
        try driver.clearDiskCache(onCachePage: {})
        // A cold process plus the real cache clear prevents prefetched photos from satisfying the race.
        app.terminateForFailureEvidence()
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
