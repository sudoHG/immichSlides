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

        let current = try captureRequiredIdentity(app: app, name: "ooo-current-scene")
        try releaseLateImageAndWaitForDelivery(input: input)
        RunLoop.current.run(until: Date().addingTimeInterval(lateRequestSettleSeconds))
        let afterLate = try captureRequiredIdentity(app: app, name: "ooo-after-late")

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
        IOSFirstBootNavigation(app: app).selectModeAndContinue(
            "mode.random.button", selectionTimeout: TestWait.seconds(.product(8)),
            departureTimeout: TestWait.seconds(.product(8)))
        let next = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            next.waitForPublicElement("slideshow.control.next.button", timeout: TestWait.seconds(.product(8))),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        let banner = app.descendants(matching: .any)["slideshow.entryHint.banner"]
        if (try? banner.snapshot()) != nil { tapElement(banner) }
        XCTAssertTrue(
            revealLateImageControls(app: app),
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        let playPause = app.buttons["slideshow.control.playPause.button"]
        if (try? playPause.snapshot()).map({ playPauseState($0) }) != "play" { tapElement(playPause) }
        var pausedHistoryCount: Int?
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(2))) {
                let observation = self.strictSceneFrameObservation(app: app)
                let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
                guard render["playbackPaused"] == "true", let count = Int(render["historyCount"] ?? "") else {
                    return false
                }
                pausedHistoryCount = count
                return true
            },
            "Next must be tappable twice right after entering the slideshow, before old image requests finish.")
        let initialHistory = try XCTUnwrap(pausedHistoryCount)
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.product(8))
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
    private func captureRequiredIdentity(app: XCUIApplication, name: String) throws -> StrictE2EPhotoIdentity.Result {
        dismissSavePasswordPromptIfShown(app: app, deadline: Date().addingTimeInterval(TestWait.seconds(.product(2))))
        let before = strictSceneFrameObservation(app: app)
        let png = app.screenshotForFailureEvidence().pngRepresentation
        let after = strictSceneFrameObservation(app: app)
        XCTAssertFalse(png.isEmpty, "The playback screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        attachStrictSceneObservation(before: before, after: after, name: "\(name)-scene")
        XCTAssertTrue(
            [before, after].allSatisfy(StrictE2ESceneCapture.isStableWindow),
            "After late completion the current public mark must stay: no flash back, all black or unreadable: unstable capture"
        )
        return StrictE2EPhotoIdentity.captureIdentity(png: png)
    }
}
#endif
