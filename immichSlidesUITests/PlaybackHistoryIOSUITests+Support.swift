import XCTest

#if os(iOS)
// Keep only the latest action/observation, not an unbounded trace or raw server identifiers.
struct PlaybackHistoryFailureDiagnostics {
    var actionRequest: TimeInterval?
    var actionReturn: TimeInterval?
    var pauseTap: (request: TimeInterval, returned: TimeInterval)?
    var firstPauseRead: String?
    var nextOrdinal = 0
    var nextBeforeIdentity = "unavailable"
    var nextTap: (request: TimeInterval, returned: TimeInterval)?
    var wake: (request: TimeInterval, returned: TimeInterval)?
    var firstWakeObservation: SlideshowControlBarButtonObservation?
    var didReadWakeObservation = false
    var wakeObservationTimes = "unavailable"
    var lastControlObservation: SlideshowControlBarButtonObservation?
    var lastControlObservationTimes = "unavailable"
    var hasShownControls = false
    var hasShownThenAbsentControls = false
    var lastSceneFields = "unavailable"
    var lastAssetPoll = "unavailable"

    static func time(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "unavailable"
    }

    static func token(_ value: String?, allowed: Set<String>) -> String {
        guard let value else { return "absent" }
        return allowed.contains(value) ? value : "redacted"
    }

    static func assetLabel(_ value: String?) -> String {
        guard let value else { return "absent" }
        if value.isEmpty || value == "no-asset" { return value.isEmpty ? "empty" : value }
        // Only the synthetic public fixture IDs may enter failure text verbatim.
        return value.range(of: #"^asset-[abc]-[1-9][0-9]{0,2}$"#, options: .regularExpression) != nil
            ? value : "redacted-nonempty"
    }

    static func identity(_ value: String?) -> String {
        guard let value else { return "absent" }
        if value.isEmpty || value == "none" { return value.isEmpty ? "empty" : value }
        return value.count <= 256
            && value.range(of: #"^asset-[0-9a-f]{16}(,asset-[0-9a-f]{16}){0,7}$"#, options: .regularExpression) != nil
            ? value : "redacted-nonempty"
    }

    static func presentation(_ snapshots: [String: XCUIElementSnapshot]) -> String {
        ["contract", "frameSynchronized"].map { kind in
            let fields = SharedSceneEvidenceManifest.parseKeyValueFields(
                snapshots["slideshow.scenePresentation.\(kind).summary"]?.label ?? "")
            let phase = token(
                fields["phase"],
                allowed: [
                    "empty", "loading", "stablePhoto", "transition", "incomingFromLoading", "grace", "paused",
                    "sourceError"
                ])
            let roles = token(
                fields["layerRoles"], allowed: ["none", "stable", "incoming", "outgoing", "outgoing|incoming"])
            let paused = token(fields["playbackPaused"], allowed: ["true", "false"])
            let loading = token(fields["loadingVisible"], allowed: ["true", "false"])
            return "\(kind).phase=\(phase),layerRoles=\(roles),playbackPaused=\(paused),loadingVisible=\(loading)"
        }.joined(separator: ";")
    }

    static let controls = ["previous", "playPause", "next", "settings"]

    mutating func observe(_ event: SlideshowControlBarDiagnosticEvent) {
        switch event {
        case .begin:
            wake = nil
            firstWakeObservation = nil
            lastControlObservation = nil
            lastControlObservationTimes = "unavailable"
            didReadWakeObservation = false
            wakeObservationTimes = "unavailable"
            hasShownControls = false
            hasShownThenAbsentControls = false
        case .wake(let request, let returned):
            wake = (request, returned)
        case .observation(let observation, let request, let returned):
            lastControlObservation = observation
            lastControlObservationTimes = "request=\(Self.time(request)),return=\(Self.time(returned))"
            if wake != nil, !didReadWakeObservation {
                didReadWakeObservation = true
                firstWakeObservation = observation
                wakeObservationTimes = "request=\(Self.time(request)),return=\(Self.time(returned))"
            }
            if let observation, wake != nil {
                let shown = Self.controls.contains { observation.snapshots["slideshow.control.\($0).button"] != nil }
                hasShownThenAbsentControls = hasShownThenAbsentControls || (hasShownControls && !shown)
                hasShownControls = hasShownControls || shown
            }
        case .tap(let request, let returned):
            actionRequest = request
            actionReturn = returned
        }
    }

    var controlSuffix: String {
        let controls = Self.controls.map { name in
            let button = firstWakeObservation?.snapshots["slideshow.control.\(name).button"]
            let exists = firstWakeObservation == nil ? "unknown" : String(button != nil)
            let inside = button.map {
                !($0.frame.isEmpty) && firstWakeObservation?.windowFrame.contains($0.frame) == true
            }
            return
                "\(name){exists=\(exists),enabled=\(button.map { String($0.isEnabled) } ?? "unknown"),frame=\(button.map { String(describing: $0.frame) } ?? "unknown"),hittable=unavailable(snapshot-api),frameInsideWindow=\(inside.map(String.init) ?? "unknown")}"
        }.joined(separator: ";")
        let visibility =
            hasShownThenAbsentControls
            ? "shown-then-absent(auto-hide-candidate)"
            : hasShownControls ? "shown" : "never-observed(visibility-between-reads-unknown)"
        let lastPlayPausePresence =
            lastControlObservation.map {
                String($0.snapshots["slideshow.control.playPause.button"] != nil)
            } ?? "unknown"
        let lastMarkerPresence = lastControlObservation.map { String($0.hasPlaybackMarker) } ?? "unknown"
        return
            " wake.request=\(Self.time(wake?.request)),wake.return=\(Self.time(wake?.returned)),wakeSnapshot{\(wakeObservationTimes),succeeded=\(firstWakeObservation != nil),window=\(firstWakeObservation.map { String(describing: $0.windowFrame) } ?? "unknown"),actionPosition=app-default-tap,playbackMarker.exists=\(firstWakeObservation.map { String($0.hasPlaybackMarker) } ?? "unknown");\(controls);\(Self.presentation(firstWakeObservation?.snapshots ?? [:]))},controls.visibility=\(visibility),lastSnapshotSucceeded=\(lastControlObservation != nil),lastSnapshot{\(lastControlObservationTimes),playPause.exists=\(lastPlayPausePresence),playbackMarker.exists=\(lastMarkerPresence)}"
    }

    var actionSuffix: String {
        "action.request=\(Self.time(actionRequest)),action.return=\(Self.time(actionReturn)),elapsedSinceAction=\(Self.time(actionRequest.map { ProcessInfo.processInfo.systemUptime - $0 }))"
    }

    var pauseSuffix: String {
        " (pause.request=\(Self.time(pauseTap?.request)),pause.return=\(Self.time(pauseTap?.returned)),firstPauseRead{\(firstPauseRead ?? "unavailable")};\(controlSuffix))"
    }

    var sceneSuffix: String {
        " (next.ordinal=\(nextOrdinal),next.beforeIdentity=\(nextBeforeIdentity),next.request=\(Self.time(nextTap?.request)),next.return=\(Self.time(nextTap?.returned)),lastScene{\(lastSceneFields)};\(actionSuffix))\(pauseSuffix)"
    }
}

extension PlaybackHistoryIOSUITests {
    func playbackControlDiagnostic(_ event: SlideshowControlBarDiagnosticEvent) {
        playbackDiagnostics.observe(event)
    }

    func tapPlaybackControl(
        app: XCUIApplication, identifier: String, beforeIdentity: String? = nil, isPause: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if identifier == "slideshow.control.next.button" {
            playbackDiagnostics.nextOrdinal += 1
            playbackDiagnostics.nextBeforeIdentity = PlaybackHistoryFailureDiagnostics.identity(beforeIdentity)
            playbackDiagnostics.nextTap = nil
        }
        app.tapSlideshowControlBarButton(
            identifier: identifier,
            onDiagnosticEvent: { event in
                self.playbackControlDiagnostic(event)
                if case .tap(let request, let returned) = event {
                    if isPause {
                        self.playbackDiagnostics.pauseTap = (request, returned)
                        self.playbackDiagnostics.firstPauseRead = nil
                    }
                    if identifier == "slideshow.control.next.button" {
                        self.playbackDiagnostics.nextTap = (request, returned)
                    }
                }
            }, failureDiagnosticSuffix: { self.playbackDiagnostics.controlSuffix }, file: file, line: line)
    }

    func attachManualLifecycleRuntimeEvidence(mode: ManualLifecycleMode) {
        guard !manualLifecycleRuntimeEvidenceRows.isEmpty,
            JSONSerialization.isValidJSONObject(manualLifecycleRuntimeEvidenceRows),
            let data = try? JSONSerialization.data(
                withJSONObject: manualLifecycleRuntimeEvidenceRows,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "manual-lifecycle-\(mode == .smartFill ? "smartfill" : "single-photo")-runtime-sequence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func currentSceneIdentity(
        app: XCUIApplication, mode: ManualLifecycleMode, snapshots: [String: XCUIElementSnapshot]? = nil
    ) -> String? {
        let snapshots = snapshots ?? app.evidenceSnapshotsByIdentifier()
        if mode == .smartFill {
            return currentCompleteVisibleSmartFillScene(app: app, snapshots: snapshots)?.sceneIdentity
        }
        return currentAssetID(app: app, snapshots: snapshots)
    }

    func announceManualLifecycleCaptureWindowIfRequested(mode: ManualLifecycleMode, kind: String) {
        guard let path = ProcessInfo.processInfo.environment["TEST_RUNNER_MANUAL_LIFECYCLE_CAPTURE_READY_FILE"],
            !path.isEmpty
        else {
            emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: "not-configured")
            return
        }
        let payload: [String: Any] = [
            "mode": mode == .smartFill ? "smartFill" : "singlePhoto",
            "kind": kind,
            "readyAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: "encode-failed")
            return
        }
        let markerStatus: String
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            markerStatus = "written"
        } catch {
            markerStatus = "write-failed"
        }
        emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: markerStatus)
        // External recording must wait for a visible stable scene; only the test capture path keeps this sync window.
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.infrastructure(1))))
    }

    func emitManualLifecycleCaptureStatus(mode: ManualLifecycleMode, kind: String, markerStatus: String) {
        let modeName = mode == .smartFill ? "smartFill" : "singlePhoto"
        let line = "MANUAL_LIFECYCLE_CAPTURE_READY mode=\(modeName) kind=\(kind) marker=\(markerStatus)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    func openPlaybackSettingsFromSlideshow(app: XCUIApplication) {
        var diagnostic = ""
        XCTAssertTrue(
            app.refreshSlideshowControlBarButton(
                identifier: "slideshow.control.settings.button",
                timeout: TestWait.seconds(.infrastructure(8)), pollSeconds: TestWait.seconds(.product(0.2)),
                onDiagnosticEvent: playbackControlDiagnostic,
                onTimeout: { diagnostic = " (\($0)\(self.playbackDiagnostics.controlSuffix))" }),
            "The slideshow Settings button must be ready before opening playback settings.\(diagnostic)")
        tapPlaybackControl(app: app, identifier: "slideshow.control.settings.button")

        let playbackEntry: XCUIElement
        if UIDevice.current.userInterfaceIdiom == .pad {
            if app.switches["settings.playback.autoPlay.toggle"].waitForPublicElement(
                "settings.playback.autoPlay.toggle",
                timeout: TestWait.seconds(.infrastructure(2)))
            {
                return
            }
            let sidebar = app.buttons["ToggleSidebar"]
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
            playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        } else {
            playbackEntry = app.buttons["settings.item.playback"]
        }
        XCTAssertTrue(
            playbackEntry.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(8))),
            "The settings list must provide the Playback Settings entry")
        tapElement(playbackEntry)
    }

    func requireAutoPlayToggle(app: XCUIApplication) throws -> XCUIElement {
        let toggle = app.switches["settings.playback.autoPlay.toggle"]
        guard
            toggle.waitForPublicElement(
                "settings.playback.autoPlay.toggle", timeout: TestWait.seconds(.infrastructure(8)))
        else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "missing settings.playback.autoPlay.toggle"]
            )
        }
        return toggle
    }

    func returnToSlideshowFromPlaybackSettings(app: XCUIApplication) {
        for _ in 0..<6 {
            if slideshowSettingsButtonIsReady(app: app) {
                break
            }

            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tapElement(globalBack)
                continue
            }
            let backButton =
                app.navigationBars.buttons.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable && $0.identifier == "BackButton" }
                .last
                ?? app.navigationBars.buttons.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable && $0.identifier != "ToggleSidebar" }
                .first
            if let backButton {
                backButton.tapForFailureEvidence()
            } else {
                app.tapForFailureEvidence()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
        }
        var diagnostic = ""
        XCTAssertTrue(
            app.refreshSlideshowControlBarButton(
                identifier: "slideshow.control.settings.button",
                timeout: TestWait.seconds(.infrastructure(6)), pollSeconds: TestWait.seconds(.product(0.2)),
                onDiagnosticEvent: playbackControlDiagnostic,
                onTimeout: { diagnostic = " (\($0)\(self.playbackDiagnostics.controlSuffix))" }),
            "Could not return from the playback settings page to the slideshow\(diagnostic)"
        )
    }

    func slideshowSettingsButtonIsReady(app: XCUIApplication) -> Bool {
        var timing = SlideshowControlBarTiming()
        let observation = timing.observe(app: app, identifier: "slideshow.control.settings.button")
        if observation == nil { print("Slideshow return observation: \(timing.diagnostic)") }
        return observation?.isReady == true
    }

    func waitForPlayPauseState(app: XCUIApplication, expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var didReadSnapshot = true
            let request = ProcessInfo.processInfo.systemUptime
            let snapshots = app.evidenceSnapshotsByIdentifier(onSnapshotFailure: { _ in didReadSnapshot = false })
            let returned = ProcessInfo.processInfo.systemUptime
            let button = snapshots["slideshow.control.playPause.button"]
            if playbackDiagnostics.pauseTap != nil, playbackDiagnostics.firstPauseRead == nil {
                let state = PlaybackHistoryFailureDiagnostics.token(
                    (button?.value as? String)?.lowercased(), allowed: ["play", "pause"])
                playbackDiagnostics.firstPauseRead =
                    "request=\(PlaybackHistoryFailureDiagnostics.time(request)),return=\(PlaybackHistoryFailureDiagnostics.time(returned)),snapshotSucceeded=\(didReadSnapshot),control.exists=\(button != nil),state=\(state);\(PlaybackHistoryFailureDiagnostics.presentation(snapshots))"
            }
            if let button, ((button.value as? String) ?? "").lowercased() == expected, Date() < deadline {
                return true
            }
            guard Date() < deadline else { break }
            if didReadSnapshot, button == nil {
                app.tapForFailureEvidence()
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(TestWait.seconds(.product(0.2)))))
        }
        return false
    }

    func isToggleOn(_ toggle: XCUIElement) -> Bool {
        let value = ((toggle.value as? String) ?? "").lowercased()
        return value == "1" || value == "true"
    }

    func waitForPresentationProbe(app: XCUIApplication, timeout: TimeInterval) throws -> ScenePresentationProbe {
        guard waitUntil(timeout: timeout, condition: { self.presentationProbe(app: app) != nil }),
            let probe = presentationProbe(app: app)
        else {
            let hierarchy = app.debugDescription
            print("MANUAL_LIFECYCLE_PROBE_HIERARCHY_BEGIN\n\(hierarchy)\nMANUAL_LIFECYCLE_PROBE_HIERARCHY_END")
            let attachment = XCTAttachment(data: Data(hierarchy.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-missing-contract-probe-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw NSError(
                domain: "PlaybackHistoryIOSUITests", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "missing presentation contract probe"])
        }
        return probe
    }

    func waitForStablePresentationProbe(app: XCUIApplication, timeout: TimeInterval) throws -> ScenePresentationProbe {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let probe = self.presentationProbe(app: app) else { return false }
                    return probe.phase == "stablePhoto" && !probe.rawProgress.isEmpty
                }), let probe = presentationProbe(app: app)
        else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "scene presentation did not reach stablePhoto"]
            )
        }
        return probe
    }

    func waitForFrameSynchronizedPresentationProbe(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> ScenePresentationProbe {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let probe = self.frameSynchronizedPresentationProbe(app: app) else { return false }
                    return probe.phase == "stablePhoto" && !probe.rawProgress.isEmpty
                }), let probe = frameSynchronizedPresentationProbe(app: app)
        else {
            let frameProbe = app.descendants(matching: .any)["slideshow.scenePresentation.frameSynchronized.summary"]
            let contractProbe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
            let diagnostic = [
                "frameProbe.exists=\(frameProbe.exists)",
                "frameProbe.label=\(frameProbe.label)",
                "contractProbe.exists=\(contractProbe.exists)",
                "contractProbe.label=\(contractProbe.label)",
                "MANUAL_LIFECYCLE_FRAME_SYNCHRONIZED_HIERARCHY_BEGIN",
                app.debugDescription,
                "MANUAL_LIFECYCLE_FRAME_SYNCHRONIZED_HIERARCHY_END"
            ].joined(separator: "\n")
            print(diagnostic)
            let attachment = XCTAttachment(data: Data(diagnostic.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-frame-synchronized-probe-diagnostic"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "missing frame-synchronized scene presentation probe"]
            )
        }
        return probe
    }

    // A pause can land mid-transition, and the reducer then freezes each layer's fade (ScenePresentationReducerTests),
    // so the freeze checks accept a paused transition as well as a stable scene. At least one photo layer must show.
    func waitForPausedFrameSynchronizedPresentationProbe(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> (probe: ScenePresentationProbe, snapshots: [XCUIElementSnapshot]) {
        var pausedFrame: (probe: ScenePresentationProbe, snapshots: [XCUIElementSnapshot])?
        var observed = "missing"
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let root = try? app.snapshot() else {
                        observed = "missing"
                        return false
                    }
                    var snapshots: [XCUIElementSnapshot] = []
                    var pending = [root]
                    while let node = pending.popLast() {
                        if !node.identifier.isEmpty {
                            snapshots.append(node)
                        }
                        pending.append(contentsOf: node.children)
                    }
                    let identifier = "slideshow.scenePresentation.frameSynchronized.summary"
                    observed = snapshots.first { $0.identifier == identifier }?.label ?? "missing"
                    guard SharedSceneEvidenceManifest.parseKeyValueFields(observed)["playbackPaused"] == "true",
                        let probe = self.scenePresentationProbe(identifier: identifier, app: app, snapshots: snapshots),
                        ["stablePhoto", "transition"].contains(probe.phase) && !probe.rawProgress.isEmpty
                            && probe.opacities.contains(where: { $0 > 0 })
                    else { return false }
                    pausedFrame = (probe, snapshots)
                    return true
                }), let pausedFrame
        else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "paused scene is not a visible photo scene: \(observed)\(playbackDiagnostics.pauseSuffix)"
                ]
            )
        }
        return pausedFrame
    }

    func presentationProbe(app: XCUIApplication) -> ScenePresentationProbe? {
        scenePresentationProbe(identifier: "slideshow.scenePresentation.contract.summary", app: app)
    }

    func frameSynchronizedPresentationProbe(app: XCUIApplication) -> ScenePresentationProbe? {
        scenePresentationProbe(identifier: "slideshow.scenePresentation.frameSynchronized.summary", app: app)
    }

    func scenePresentationProbe(
        identifier: String, app: XCUIApplication, snapshots: [XCUIElementSnapshot]? = nil
    ) -> ScenePresentationProbe? {
        let label: String
        if let snapshots {
            guard let element = snapshots.first(where: { $0.identifier == identifier }) else { return nil }
            label = element.label
        } else {
            let element = app.descendants(matching: .any)[identifier]
            guard element.exists else { return nil }
            label = element.label
        }
        let fields = SharedSceneEvidenceManifest.parseKeyValueFields(label)
        func numbers(_ key: String) -> [Double] {
            (fields[key] ?? "").split(separator: "|").compactMap { Double($0) }
        }
        // phase=empty is real evidence of empty input; do not disguise it as a missing probe.

        guard let phase = fields["phase"] else { return nil }
        return ScenePresentationProbe(
            phase: phase,
            rawProgress: numbers("motionRawProgress"),
            opacities: numbers("layerOpacities")
        )
    }

    // These fields are the render's clock (`systemUptime` when SwiftUI evaluated the view) and times derived
    // from it, so any re-render of a paused scene moves them. The paused motion clock stays under test through
    // `progress`, `stableVisibleDuration` and `transitionCompletionDelay`.
    static let renderTimeAnchoredSlotProbeFields: Set<String> = [
        "presentationSampleTime", "timelineStartTime", "stableVisibleStartTime",
        "handoffStartDeadlineTime", "removalDeadlineTime"
    ]

    // Interface chrome and next-scene bookkeeping are not photo rendering: the pause contract freezes the photo only (#218).
    static let nonPhotoSlotProbeFields: Set<String> = [
        "controlBarVisible", "appOverlayPollution", "preparedNextTargetIndex", "preparedNextSourceCursor",
        "currentPreparedSourceCursor", "lookaheadCachedSourceCursor", "lookaheadCachedSelectedCount"
    ]

    func frozenStateOfSmartFillSlots(snapshots: [XCUIElementSnapshot]) -> [String] {
        smartFillRenderedSlotProbeLabels(snapshots: snapshots).map { probe in
            probe.split(separator: ";", omittingEmptySubsequences: false)
                .filter { field in
                    let key = field.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                    return !Self.renderTimeAnchoredSlotProbeFields.contains(key)
                        && !Self.nonPhotoSlotProbeFields.contains(key)
                }
                .joined(separator: ";")
        }
    }

    func smartFillRenderedSlotProbeLabels(snapshots: [XCUIElementSnapshot]) -> [String] {
        snapshots
            .filter { $0.identifier.hasPrefix("slideshow.smartfill.motionFrame.") }
            .map { $0.identifier + "=" + $0.label }
            .sorted()
    }

    func assertSmartFillPauseOnlyFrameFreeze(
        app: XCUIApplication,
        evidenceEventPrefix: String
    ) throws {
        let initialFrame = try waitForPausedFrameSynchronizedPresentationProbe(
            app: app, timeout: TestWait.seconds(.product(3)))
        let initialProbe = initialFrame.probe
        let initialSlots = frozenStateOfSmartFillSlots(snapshots: initialFrame.snapshots)
        let initialSummary = initialFrame.snapshots.first {
            $0.identifier == "slideshow.smartfill.motionFrame.summary"
        }
        XCTAssertNotNil(
            initialSummary,
            "The pause diagnostic must read the rendered frame/transform probe of every SmartFill slot")
        let hasAvailableMotionFrame =
            initialSummary?.label.split(separator: "\n").contains { row in
                let fields = SharedSceneEvidenceManifest.parseKeyValueFields(String(row))
                return fields["eventType"] == "motionFrame" && fields["progressFrameStatus"] == "available"
            } ?? false
        XCTAssertTrue(
            hasAvailableMotionFrame,
            "The pause diagnostic must read an available motionFrame row from the rendered-slot summary")
        let initialSample = capturePausedWindowSample(app: app)
        appendManualLifecycleRuntimeEvidence(
            app: app, mode: .smartFill, event: "\(evidenceEventPrefix)-start", probe: initialProbe)
        let initialPixelsAttachment = XCTAttachment(data: initialSample.png, uniformTypeIdentifier: "public.png")
        initialPixelsAttachment.name = "\(evidenceEventPrefix)-start"
        initialPixelsAttachment.lifetime = .keepAlways
        add(initialPixelsAttachment)

        for sample in 1...PlaybackHistoryIOSUITestsCalibration.pauseSampleCount {
            RunLoop.current.run(
                until: Date().addingTimeInterval(
                    TestWait.seconds(.product(PlaybackHistoryIOSUITestsCalibration.pauseSampleIntervalSeconds))))
            let pausedFrame = try waitForPausedFrameSynchronizedPresentationProbe(
                app: app, timeout: TestWait.seconds(.product(2)))
            let probe = pausedFrame.probe
            let slots = frozenStateOfSmartFillSlots(snapshots: pausedFrame.snapshots)
            let sampleWindow = capturePausedWindowSample(app: app)
            let pixels = sampleWindow.png
            let frame = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            frame.name = "Desktop-settings-pause-before-assert-\(sample)"
            frame.lifetime = .keepAlways
            add(frame)
            XCTAssertEqual(probe.phase, initialProbe.phase, "The scene phase must not change while paused")
            XCTAssertEqual(probe.opacities, initialProbe.opacities, "Layer opacities must not change while paused")
            XCTAssertEqual(
                probe.rawProgress, initialProbe.rawProgress,
                "After pausing, the frame-synchronized motionRawProgress must stay frozen")
            XCTAssertEqual(
                slots, initialSlots,
                "After pausing, the rendered transform/frame of every SmartFill slot must stay frozen")
            let pixelComparison = comparePausedPhotoPixels(sampleWindow, against: initialSample)
            let comparisonAttachment = XCTAttachment(
                data: Data(pixelComparison.summary.utf8), uniformTypeIdentifier: "public.plain-text")
            comparisonAttachment.name = "\(evidenceEventPrefix)-photo-pixels-sample-\(sample)"
            comparisonAttachment.lifetime = .keepAlways
            add(comparisonAttachment)
            XCTAssertNil(
                pixelComparison.failureReason, "Paused screenshots must be comparable: \(pixelComparison.summary)")
            XCTAssertEqual(
                pixelComparison.differingPixelCount, 0,
                "After pausing, the photo pixels outside the control bar and entry hint must stay frozen: \(pixelComparison.summary)"
            )
            appendManualLifecycleRuntimeEvidence(
                app: app, mode: .smartFill, event: "\(evidenceEventPrefix)-sample-\(sample)", probe: probe)
            let pixelsAttachment = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            pixelsAttachment.name = "\(evidenceEventPrefix)-sample-\(sample)"
            pixelsAttachment.lifetime = .keepAlways
            add(pixelsAttachment)
        }
    }

    @MainActor
    func sceneIdentity(app: XCUIApplication, mode: ManualLifecycleMode) throws -> String {
        if mode == .smartFill {
            return try waitForCompleteVisibleSmartFillScene(app: app, timeout: TestWait.seconds(.product(8)))
                .sceneIdentity
        }
        return try waitForCurrentAssetID(app: app)
    }

    func waitForSceneIdentityChange(app: XCUIApplication, mode: ManualLifecycleMode, from oldValue: String) throws
        -> String
    {
        var changedIdentity: String?
        guard
            waitUntil(
                timeout: TestWait.seconds(.product(20)),
                condition: {
                    guard let identity = self.currentSceneIdentity(app: app, mode: mode), identity != oldValue
                    else { return false }
                    changedIdentity = identity
                    return true
                }), let changedIdentity
        else {
            attachSmartFillProbeLabels(app: app, name: "manual-lifecycle-scene-identity-unchanged-probe")
            XCTFail("scene identity did not change\(playbackDiagnostics.sceneSuffix)")
            throw NSError(
                domain: "PlaybackHistoryIOSUITests", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "scene identity did not change"])
        }
        return changedIdentity
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForPublicElement("mode.random.button", timeout: TestWait.seconds(.infrastructure(5))),
            "The mode selection page should show the Random Playback entry")
        tapElement(randomButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForPublicElement("mode.continue.button", timeout: TestWait.seconds(.infrastructure(5))),
            "The mode selection page should show the Continue button")
        XCTAssertTrue(
            continueButton.isEnabled, "After choosing Random Playback, the Continue button should be tappable")
        tapElement(continueButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                "slideshow.control.settings.button",
                timeout: TestWait.seconds(.infrastructure(25))),
            "After entering random playback, the playback control bar should be shown"
        )
    }

    func startFilteredPlaybackFromModeSelection(app: XCUIApplication) {
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            filteredButton.waitForPublicElement("mode.filtered.button", timeout: TestWait.seconds(.infrastructure(5))),
            "The filtered-playback harness should show the Filtered Playback entry")
        tapElement(filteredButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForPublicElement("mode.continue.button", timeout: TestWait.seconds(.infrastructure(5))),
            "Filtered playback should show the Continue button")
        XCTAssertTrue(
            continueButton.isEnabled, "The Continue button in the filtered-playback harness should be tappable")
        tapElement(continueButton)

        let startButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(12))),
            "The filtered playback summary should show the Start Playback button")
        // Starting before the page swaps in the real album and person would play an empty pool.
        let selectionReady = app.staticTexts["filterSummary.visual.ready"]
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.infrastructure(30))) {
                selectionReady.exists && selectionReady.label == "ready"
            },
            "The filter summary must select a real album and person before playback starts"
        )
        XCTAssertTrue(waitUntil(timeout: TestWait.seconds(.infrastructure(12))) { startButton.isEnabled })
        tapElement(startButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                "slideshow.control.settings.button",
                timeout: TestWait.seconds(.infrastructure(45))),
            "The filtered-playback harness should reach the real playback control bar"
        )
    }

    @MainActor
    func waitForCurrentAssetID(app: XCUIApplication, timeout: TimeInterval? = nil) throws -> String {
        var observedAssetID: String?
        var snapshotFailureCount = 0
        var lastSnapshotFailure: String?
        var lastSnapshotFailureCode: Int?
        let condition = {
            observedAssetID = self.currentAssetID(
                app: app,
                onSnapshotFailure: { error in
                    snapshotFailureCount += 1
                    lastSnapshotFailure = error.localizedDescription
                    lastSnapshotFailureCode = (error as NSError).code
                })
            return observedAssetID != nil
        }
        let didObserve: Bool
        if let timeout {
            didObserve = waitUntil(timeout: timeout, condition: condition)
        } else {
            let guardWait = TestWait.hangGuard()
            didObserve = guardWait.transaction().until(condition)
        }
        guard didObserve else {
            // These are failure-time direct reads, never substitutes for the final polling observation.
            let directReads = [
                ("window", app.windows.firstMatch.descendants(matching: .any)["slideshow.currentAssetId.flag"]),
                ("appRoot", app.descendants(matching: .any)["slideshow.currentAssetId.flag"])
            ].map { scope, element in
                let request = ProcessInfo.processInfo.systemUptime
                do {
                    let snapshot = try element.snapshot()
                    return
                        "\(scope){request=\(PlaybackHistoryFailureDiagnostics.time(request)),return=\(PlaybackHistoryFailureDiagnostics.time(ProcessInfo.processInfo.systemUptime)),succeeded=true,label=\(PlaybackHistoryFailureDiagnostics.assetLabel(snapshot.label))}"
                } catch {
                    return
                        "\(scope){request=\(PlaybackHistoryFailureDiagnostics.time(request)),return=\(PlaybackHistoryFailureDiagnostics.time(ProcessInfo.processInfo.systemUptime)),succeeded=false,errorCode=\((error as NSError).code),label=unknown}"
                }
            }.joined(separator: ";")
            let hierarchy = app.debugDescription
            let probeDiagnostic = [directReads, playbackDiagnostics.lastAssetPoll]
            let diagnostic =
                ([
                    "currentAssetProbe.snapshotFailures=\(snapshotFailureCount)",
                    "currentAssetProbe.lastSnapshotFailure=\(lastSnapshotFailure ?? "none")"
                ] + probeDiagnostic + [
                    "MANUAL_LIFECYCLE_CURRENT_ASSET_HIERARCHY_BEGIN",
                    hierarchy,
                    "MANUAL_LIFECYCLE_CURRENT_ASSET_HIERARCHY_END"
                ]).joined(separator: "\n")
            print(diagnostic)
            let attachment = XCTAttachment(data: Data(diagnostic.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-current-asset-probe-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            // Failure text carries only sanitized fields and numeric errors, never raw snapshot errors.
            let lastError = lastSnapshotFailureCode.map { "code:\($0)" } ?? "none"
            XCTFail(
                "The slideshow must reliably expose slideshow.currentAssetId.flag in UI tests, EXIF panel or not. (snapshotFailures=\(snapshotFailureCount), lastError=\(lastError),lastPoll{\(playbackDiagnostics.lastAssetPoll)},failureTimeDirect{\(directReads)},\(playbackDiagnostics.actionSuffix))\(playbackDiagnostics.pauseSuffix)"
            )
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "missing slideshow.currentAssetId.flag"
                ]
            )
        }

        guard let assetID = observedAssetID else {
            XCTFail("The slideshow asset ID probe disappeared; cannot read the current photo.")
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "missing slideshow.currentAssetId.flag after initial detection"
                ]
            )
        }
        return assetID
    }

    @MainActor
    func waitForCurrentAssetIDChange(app: XCUIApplication, from oldValue: String, timeout: TimeInterval) throws
        -> String
    {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let value = self.currentAssetID(app: app) else { return false }
                    return value != oldValue
                })
        else {
            XCTFail("After tapping next, the current photo ID did not change within \(Int(timeout)) seconds")
            return oldValue
        }

        return try waitForCurrentAssetID(app: app, timeout: TestWait.seconds(.product(2)))
    }

    func currentAssetID(
        app: XCUIApplication,
        snapshots: [String: XCUIElementSnapshot]? = nil,
        onSnapshotFailure: ((Error) -> Void)? = nil
    ) -> String? {
        let request = ProcessInfo.processInfo.systemUptime
        var hasMainWindow: Bool?
        var succeeded = true
        let observed =
            snapshots
            ?? app.evidenceSnapshotsByIdentifier(
                onSnapshotFailure: { error in
                    succeeded = false
                    onSnapshotFailure?(error)
                },
                onRootSnapshot: { root in
                    hasMainWindow = root.children.contains { $0.elementType == .window }
                })
        let candidate = observed["slideshow.currentAssetId.flag"]
        playbackDiagnostics.lastAssetPoll =
            "request=\(PlaybackHistoryFailureDiagnostics.time(request)),return=\(PlaybackHistoryFailureDiagnostics.time(ProcessInfo.processInfo.systemUptime)),source=\(snapshots == nil ? "appRoot" : "suppliedSnapshot"),succeeded=\(succeeded),hasWindow=\(hasMainWindow.map(String.init) ?? "unknown"),flag=\(PlaybackHistoryFailureDiagnostics.assetLabel(candidate?.label));\(PlaybackHistoryFailureDiagnostics.presentation(observed))"
        guard
            let probe = candidate
        else { return nil }
        let label = probe.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty || label == "no-asset" ? nil : label
    }

    func waitForCompleteVisibleSmartFillScene(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> CompleteVisibleSmartFillScene {
        var observedScene: CompleteVisibleSmartFillScene?
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    observedScene = self.currentCompleteVisibleSmartFillScene(app: app)
                    return observedScene != nil
                }), let scene = observedScene
        else {
            attachSmartFillProbeLabels(app: app, name: "smartfill-history-missing-complete-visible-probe")
            XCTFail(
                "SmartFill must expose the complete manifest, stable visible render state and history cursor together\(playbackDiagnostics.sceneSuffix)"
            )
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "missing complete visible SmartFill scene"]
            )
        }
        return scene
    }

    func waitForCompleteVisibleSmartFillSceneChange(
        app: XCUIApplication,
        from previousIdentity: String,
        timeout: TimeInterval
    ) throws -> CompleteVisibleSmartFillScene {
        var changedScene: CompleteVisibleSmartFillScene?
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let scene = self.currentCompleteVisibleSmartFillScene(app: app) else { return false }
                    guard scene.sceneIdentity != previousIdentity else { return false }
                    changedScene = scene
                    return true
                }), let changedScene
        else {
            attachSmartFillProbeLabels(app: app, name: "smartfill-history-next-identity-unchanged-probe")
            XCTFail(
                "After tapping next, the fully visible SmartFill scene identity did not change in \(Int(timeout)) s\(playbackDiagnostics.sceneSuffix)"
            )
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "complete visible SmartFill scene did not change"]
            )
        }
        return changedScene
    }

    func currentCompleteVisibleSmartFillScene(
        app: XCUIApplication, snapshots: [String: XCUIElementSnapshot]? = nil
    ) -> CompleteVisibleSmartFillScene? {
        let request = ProcessInfo.processInfo.systemUptime
        var snapshotSucceeded = true
        let snapshots =
            snapshots ?? app.evidenceSnapshotsByIdentifier(onSnapshotFailure: { _ in snapshotSucceeded = false })
        let returned = ProcessInfo.processInfo.systemUptime
        let manifestLabel = snapshots["slideshow.smartfill.currentManifest.flag"]?.label
        let fields = SharedSceneEvidenceManifest.parseKeyValueFields(manifestLabel ?? "")
        let historyLabel = snapshots["slideshow.historyLedger.summary.flag"]?.label
        let historyObject = historyLabel?.data(using: .utf8).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        let numbers = ["slotCount", "gapPixelCount", "overlapPixelCount", "canvasCoverage", "emptyCanvasRatio"].map {
            let number = fields[$0].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            return "\($0)=\(number.map { String($0) } ?? "unavailable")"
        }.joined(separator: ",")
        let historyFields = ["cursor", "entryCount", "canPrevious", "canRedo"].map {
            "\($0)=\((historyObject?[$0] as? NSNumber)?.stringValue ?? "unavailable")"
        }.joined(separator: ",")
        let readiness =
            fields["slotReadiness"].map {
                $0.split(separator: ",", omittingEmptySubsequences: false).prefix(8).map {
                    PlaybackHistoryFailureDiagnostics.token(String($0), allowed: ["ready", "pending", "failed"])
                }.joined(separator: ",")
            } ?? "absent"
        playbackDiagnostics.lastSceneFields =
            "request=\(PlaybackHistoryFailureDiagnostics.time(request)),return=\(PlaybackHistoryFailureDiagnostics.time(returned)),snapshotSucceeded=\(snapshotSucceeded),manifest.exists=\(manifestLabel != nil),complete=\(SharedSceneEvidenceManifest.manifestObservation(from: manifestLabel ?? "")?.isCompleteVisibleScene.description ?? "unknown"),\(numbers),slotReadiness=\(readiness),ledgerSceneAssets=\(PlaybackHistoryFailureDiagnostics.identity(fields["ledgerSceneAssets"])),history.exists=\(historyLabel != nil),\(historyFields);\(PlaybackHistoryFailureDiagnostics.presentation(snapshots))"
        guard let manifestProbe = snapshots["slideshow.smartfill.currentManifest.flag"],
            let contractProbe = snapshots["slideshow.scenePresentation.contract.summary"],
            let historyProbe = snapshots["slideshow.historyLedger.summary.flag"]
        else {
            return nil
        }

        let manifestFields = SharedSceneEvidenceManifest.parseKeyValueFields(manifestProbe.label)
        let contractFields = SharedSceneEvidenceManifest.parseKeyValueFields(contractProbe.label)
        guard
            SharedSceneEvidenceManifest.manifestObservation(from: manifestProbe.label)?.isCompleteVisibleScene == true,
            contractFields["phase"] == "stablePhoto",
            contractFields["layerRoles"] == "stable",
            contractFields["loadingVisible"] == "false",
            let sceneIdentity = manifestFields["ledgerSceneAssets"],
            sceneIdentity != "none",
            !sceneIdentity.isEmpty,
            let historyData = historyProbe.label.data(using: .utf8),
            let history = try? JSONSerialization.jsonObject(with: historyData) as? [String: Any],
            let cursor = history["cursor"] as? Int
        else {
            return nil
        }
        return CompleteVisibleSmartFillScene(sceneIdentity: sceneIdentity, historyCursor: cursor)
    }

    func smartFillPauseTapMarginSeconds(snapshots: [String: XCUIElementSnapshot]) -> TimeInterval? {
        let manifest = SharedSceneEvidenceManifest.parseKeyValueFields(
            snapshots["slideshow.smartfill.currentManifest.flag"]?.label ?? "")
        let slots = (snapshots["slideshow.smartfill.motionFrame.summary"]?.label ?? "")
            .split(separator: "\n")
            .map { SharedSceneEvidenceManifest.parseKeyValueFields(String($0)) }
            .filter { $0["renderRole"] == "settled" }
        guard let slotCount = Int(manifest["slotCount"] ?? ""), slotCount > 0, slots.count == slotCount else {
            return nil
        }
        let observedAt = ProcessInfo.processInfo.systemUptime
        let margins = slots.compactMap { fields -> TimeInterval? in
            guard fields["progressFrameStatus"] == "available",
                let sampledAt = Double(fields["presentationSampleTime"] ?? ""), sampledAt.isFinite,
                let handoffDeadline = Double(fields["handoffStartDeadlineTime"] ?? ""), handoffDeadline.isFinite,
                sampledAt <= observedAt
            else { return nil }
            // The diagnostic motion clock starts before stable presentation, making this deadline conservative.
            // Use current uptime so an old render sample cannot manufacture time remaining for the tap.
            return handoffDeadline - observedAt
        }
        guard margins.count == slots.count else { return nil }
        return margins.min()
    }

    func attachSmartFillProbeLabels(app: XCUIApplication, name: String) {
        let identifiers = [
            "slideshow.currentAssetId.flag",
            "slideshow.smartfill.currentManifest.flag",
            "slideshow.scenePresentation.contract.summary",
            "slideshow.historyLedger.summary.flag"
        ]
        let snapshots = app.evidenceSnapshotsByIdentifier()
        let labels = identifiers.map { identifier in
            let probe = snapshots[identifier]
            return "[\(identifier)] exists=\(probe != nil)\n\(probe?.label ?? "notVisible")"
        }.joined(separator: "\n\n")
        let attachment = XCTAttachment(data: Data(labels.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let screenshot = XCTAttachment(screenshot: app.screenshotForFailureEvidence())
        screenshot.name = "\(name)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshotForFailureEvidence())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func tapElement(_ element: XCUIElement) {
        defer { playbackDiagnostics.actionReturn = ProcessInfo.processInfo.systemUptime }
        if element.isHittable {
            playbackDiagnostics.actionRequest = ProcessInfo.processInfo.systemUptime
            element.tapForFailureEvidence()
            return
        }
        let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        playbackDiagnostics.actionRequest = ProcessInfo.processInfo.systemUptime
        coordinate.tapForFailureEvidence()
    }

    // Callers resolve the TestWait budget once; polling cadence stays fixed.
    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        return condition()
    }

    func currentDeviceTag() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iphone"
        case .pad:
            return "ipad"
        default:
            return UIDevice.current.model.replacingOccurrences(of: " ", with: "_").lowercased()
        }
    }
}
#endif
