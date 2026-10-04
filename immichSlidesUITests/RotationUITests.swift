import XCTest

// P2-04 iPad landscape / portrait multi-photo layout, P2-05 portrait -> landscape -> portrait during playback.
// Evidence is captured only in stable states; a human judges layout, cropping and safe area from the PNGs / recording.
final class RotationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    // Finish first launch and settings in portrait (same path as the other tests), then rotate to landscape for the
    // first capture; the contract requires landscape first and portrait second.
    @MainActor
    func testSmartFillLayoutBothOrientationsIPad() throws {
        XCUIDevice.shared.orientation = .portrait
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        let driver = IOSDriver(app: app)
        let evidence = Evidence()
        driver.launchToPlayback(input: input)
        driver.applyPlaybackSettings([.interval30Seconds, .displayMode(isSinglePhoto: false)])
        let targets: [(name: String, device: UIDeviceOrientation, orientation: StepOrientation)] = [
            ("layout-landscape-multi", .landscapeLeft, .landscape),
            ("layout-portrait-multi", .portrait, .portrait)
        ]
        for target in targets {
            try rotate(app, to: target.device, expecting: target.orientation)
            try driver.advanceToMultiPhotoScene(in: target.orientation)
            try captureStable(target.name, orientation: target.orientation, driver: driver, evidence: evidence) {
                driver.isShowingMultiPhotoScene(in: target.orientation)
            }
        }
    }

    // After next switches to a new scene, a fresh 30-second window starts. The whole rotation must finish before the
    // earliest natural switch, so any switch in the recording can be attributed to the rotation.
    @MainActor
    func testRotationDuringPlaybackIOS() throws {
        XCUIDevice.shared.orientation = .portrait
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        let driver = IOSDriver(app: app)
        let evidence = Evidence()
        driver.launchToPlayback(input: input)
        driver.applyPlaybackSettings([.interval30Seconds, .displayMode(isSinglePhoto: false)])
        var observedMark: String?
        _ = Wait.until(timeout: Timing.multiPhotoWait) {
            observedMark = visibleSceneMark()
            return observedMark?.isEmpty == false
        }
        guard let sceneBeforeNext = observedMark, !sceneBeforeNext.isEmpty else {
            try evidence.reject("rotation-scene-before-next", png: app.screenshot().pngRepresentation)
            throw Failure(
                "Could not recognize a public photo on screen within \(Int(Timing.multiPhotoWait)) seconds before next, so the photo change cannot be confirmed."
            )
        }
        let sceneStartedAt = Date()
        try evidence.markStep("next-requested")
        driver.next()
        guard
            Wait.until(
                timeout: Timing.multiPhotoWait,
                {
                    guard let mark = visibleSceneMark() else { return false }
                    return mark != sceneBeforeNext
                })
        else {
            throw Failure(
                "The public photo on screen did not change after next; the start of the 30-second timer is unknown, so a natural switch cannot be ruled out."
            )
        }
        try captureStable("rotation-start-portrait", orientation: .portrait, driver: driver, evidence: evidence)
        let playPause = app.buttons["slideshow.control.playPause.button"]
        var playPauseValue = ""
        let isPlaying = Wait.until(timeout: Timing.multiPhotoWait) {
            _ = driver.revealUsableControls()
            playPauseValue = playPause.exists ? ((playPause.value as? String) ?? "").lowercased() : ""
            return playPauseValue == "pause"
        }
        guard isPlaying else {
            try evidence.reject("rotation-play-state", png: app.screenshot().pngRepresentation)
            throw Failure(
                "Before rotating, the play button value must be pause (playing), but it was '\(playPauseValue.isEmpty ? "empty" : playPauseValue)'."
            )
        }
        try evidence.markStep("rotate-to-landscape")
        let landscapeDeadline = try rotate(app, to: .landscapeLeft, expecting: .landscape)
        try captureStable(
            "rotation-landscape-stable", orientation: .landscape, driver: driver, evidence: evidence,
            deadline: landscapeDeadline
        )
        try evidence.markStep("rotate-to-portrait")
        let portraitDeadline = try rotate(app, to: .portrait, expecting: .portrait)
        try captureStable(
            "rotation-portrait-stable", orientation: .portrait, driver: driver, evidence: evidence,
            deadline: portraitDeadline
        )
        let elapsed = Date().timeIntervalSince(sceneStartedAt)
        let limit = RotationTiming.naturalSwitchEarliest
        guard elapsed < limit else {
            throw Failure(
                "The rotation sequence took \(Int(elapsed)) seconds, reaching the \(Int(limit))-second earliest natural switch; a timed switch cannot be told apart from the rotation. Rerun."
            )
        }
    }

    // Orientation API spot check: no server; only checks that the window / screenshot pixel orientation after rotation
    // and the stable-frame wait settle within 10 seconds.
    @MainActor
    func testOrientationChangeReachesStableFrameIOS() throws {
        guard StrictE2EVisualEvidence.directory() != nil else {
            throw XCTSkip(
                "Self-check screenshots are written only to the StrictE2E evidence directory; runs only when the StrictE2E plan provides one."
            )
        }
        XCUIDevice.shared.orientation = .portrait
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        let targets: [(name: String, device: UIDeviceOrientation, orientation: StepOrientation)] = [
            ("selfcheck-orientation-portrait", .portrait, .portrait),
            ("selfcheck-orientation-landscape", .landscapeLeft, .landscape),
            ("selfcheck-orientation-portrait-again", .portrait, .portrait)
        ]
        let evidence = Evidence()
        var readback: [String: Any] = [:]
        for target in targets {
            let startedAt = Date()
            let deadline = try rotate(app, to: target.device, expecting: target.orientation)
            let frame = StableFrame.wait(
                in: app, orientation: target.orientation, timeout: deadline.timeIntervalSinceNow
            ) { _ in true }
            guard frame.isStable else {
                try evidence.reject(target.name, png: frame.png)
                throw Failure("\(target.name) did not stabilize: \(frame.detail)")
            }
            try evidence.record(
                target.name, png: frame.png, capturedAt: frame.capturedAt, orientation: target.orientation)
            let pixels = StableFrame.pixelSize(frame.png) ?? .zero
            readback[target.name] = [
                "seconds_to_stable": frame.capturedAt.timeIntervalSince(startedAt),
                "window": "\(Int(app.frame.width))x\(Int(app.frame.height))",
                "pixels": "\(Int(pixels.width))x\(Int(pixels.height))",
                "screen_image_orientation": XCUIScreen.main.screenshot().image.imageOrientation.rawValue,
                "detail": frame.detail
            ]
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(readback, name: "selfcheck-orientation.json")
    }

    // Returns the deadline of this stable wait: the window settling and the stable frame share the 10 seconds after the
    // rotation starts. If the orientation API has no effect, fail right away and leave the state for inspection.
    @MainActor
    @discardableResult
    private func rotate(_ app: XCUIApplication, to device: UIDeviceOrientation, expecting orientation: StepOrientation)
        throws -> Date
    {
        let deadline = Date().addingTimeInterval(Timing.stableFrameTimeout)
        XCUIDevice.shared.orientation = device
        guard Wait.until(timeout: Timing.stableFrameTimeout, { orientation.matches(app.frame.size) }) else {
            throw Failure(
                "Orientation API: after setting \(orientation.rawValue), \(Int(Timing.stableFrameTimeout)) seconds later the window is still \(app.frame.size)."
            )
        }
        return deadline
    }

    // Trust only the public photo pattern actually on screen, not scene markers the render layer may not provide.
    @MainActor
    private func visibleSceneMark() -> String? {
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: StableFrame.uprightScreenPNG())
        return identity.status == .match ? identity.mark : nil
    }

    // Save the required PNG only when a photo is visible, all three control bar buttons are tappable and isSceneReady
    // holds. If not stable by the deadline, keep only the -rejected capture and fail.
    @MainActor
    private func captureStable(
        _ name: String,
        orientation: StepOrientation,
        driver: IOSDriver,
        evidence: Evidence,
        deadline: Date? = nil,
        isSceneReady: () -> Bool = { true }
    ) throws {
        let timeout = deadline?.timeIntervalSinceNow ?? Timing.stableFrameTimeout
        let frame = StableFrame.wait(
            in: driver.app,
            orientation: orientation,
            timeout: timeout,
            prepare: { driver.revealUsableControls() && isSceneReady() },
            accept: StableFrame.showsFixturePhoto
        )
        guard frame.isStable else {
            try evidence.reject(name, png: frame.png)
            throw Failure(
                "\(name) did not stabilize within the \(Int(Timing.stableFrameTimeout))-second stable wait: \(frame.detail)"
            )
        }
        try evidence.record(name, png: frame.png, capturedAt: frame.capturedAt, orientation: orientation)
    }
    #endif
}

#if os(iOS)
private enum RotationTiming {
    // With a 30-second interval, the new scene after next switches naturally after 30 seconds at the earliest (the
    // timer also waits for the fade-in to finish).
    static let naturalSwitchEarliest: TimeInterval = 30
}
#endif
