import XCTest

#if os(tvOS)
final class SmokeFlowTVOSUITests: XCTestCase {
    let playPauseID = "slideshow.control.playPause.button"
    let indexID = "slideshow.control.indexProbe"
    let wakeID = "slideshow.hiddenWakeReceiver"
    @MainActor var peerExifLabels: Set<String> = []
    @MainActor var didObservePeerPhoto = false

    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAlbumSelection() throws {
        try tvSmokeRunFlow(shouldInjectConfiguration: true) { app, guardWait in
            try tvSmokeChooseMode("filtered", app: app, guardWait: guardWait)
            try tvSmokeSelect("filterSummary.album.button", app: app, guardWait: guardWait)
            let target = "albumFilter.album.album-a-target.button"
            let neighbor = "albumFilter.album.album-a-non-target.button"
            try tvSmokeFocus(target, app: app, guardWait: guardWait)
            try tvSmokeFocus(neighbor, app: app, guardWait: guardWait)
            try tvSmokeSelect(target, app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "album selected") {
                Self.tvSmokeIsSelected($0.nodes[target])
            }
            try tvSmokePress(.menu, guardWait: guardWait)
            try tvSmokeSelect("filterSummary.startPlayback.button", app: app, guardWait: guardWait)
            try tvSmokeExpectPlayback(app, guardWait: guardWait)
        }
    }

    @MainActor
    func testBackgroundReturn() throws {
        try tvSmokeRunFlow { app, guardWait in
            try tvSmokeChooseMode("random", app: app, guardWait: guardWait)
            try tvSmokeExpectPlayback(app, guardWait: guardWait)
            try tvSmokePress(.home, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "Home leaves playback") { _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }
            try tvSmokePerform("activate", guardWait: guardWait) { app.activate() }
            try tvSmokeExpectPlayback(app, guardWait: guardWait)
            try tvSmokeWakeControls(app, guardWait: guardWait)
            try tvSmokeSelect(playPauseID, app: app, guardWait: guardWait)
            try tvSmokeExpectState("play", app: app, guardWait: guardWait)
        }
    }

    @MainActor
    func testDirectionalWake() throws {
        try tvSmokeRunFlow(shouldInjectConfiguration: true) { app, guardWait in
            try tvSmokeChooseMode("random", app: app, guardWait: guardWait)
            for direction: XCUIRemote.Button in [.up, .down, .left, .right] {
                try tvSmokeExpect(app, guardWait: guardWait, step: "controls hide before directional wake") {
                    $0.nodes[playPauseID] == nil && $0.nodes[wakeID]?.hasFocus == true
                }
                try tvSmokePress(direction, guardWait: guardWait)
                try tvSmokeExpect(app, guardWait: guardWait, step: "direction wakes operable Play/Pause") {
                    $0.nodes[playPauseID]?.hasFocus == true && $0.nodes[playPauseID]?.isEnabled == true
                }
                try tvSmokePress(.select, guardWait: guardWait)
                try tvSmokeExpectState("play", app: app, guardWait: guardWait)
                try tvSmokePress(.playPause, guardWait: guardWait)
                try tvSmokeExpectState("pause", app: app, guardWait: guardWait)
            }
        }
    }

    @MainActor
    func testFirstBoot() throws {
        try tvSmokeRunFlow { app, guardWait in
            try tvSmokeExpect(app, guardWait: guardWait, step: "saved server reaches mode default focus") {
                $0.nodes["mode.random.button"]?.hasFocus == true
            }
            try tvSmokePerform("terminate", guardWait: guardWait) { app.terminate() }
            try tvSmokePerform("launch", guardWait: guardWait) { app.launch() }
            try tvSmokeExpectPlayback(app, guardWait: guardWait)
            try tvSmokeWakeControls(app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "cold playback has usable default focus") {
                $0.nodes[playPauseID]?.hasFocus == true && $0.nodes[playPauseID]?.isEnabled == true
            }
            try tvSmokePress(.select, guardWait: guardWait)
            try tvSmokeExpectState("play", app: app, guardWait: guardWait)
        }
    }

    @MainActor
    func testPauseResume() throws {
        try tvSmokeRunFlow { app, guardWait in
            try tvSmokeChooseMode("random", app: app, guardWait: guardWait)
            try tvSmokeExpectPlayback(app, guardWait: guardWait)
            try tvSmokeSelect(playPauseID, app: app, guardWait: guardWait)
            try tvSmokeExpectState("play", app: app, guardWait: guardWait)
            let before = try tvSmokePlaybackIndex(app, guardWait: guardWait)
            try tvSmokeSelect("slideshow.control.next.button", app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "Next advances while paused") {
                Self.tvSmokeIndex($0.nodes[indexID]) != nil && Self.tvSmokeIndex($0.nodes[indexID]) != before
                    && Self.tvSmokeValue($0.nodes[playPauseID]).lowercased() == "play"
            }
            try tvSmokePress(.playPause, guardWait: guardWait)
            try tvSmokeWakeControls(app, guardWait: guardWait)
            try tvSmokeExpectState("pause", app: app, guardWait: guardWait)
        }
    }

    @MainActor
    func testPersonSelection() throws {
        try tvSmokeRunFlow(shouldInjectConfiguration: true) { app, guardWait in
            try tvSmokeChooseMode("filtered", app: app, guardWait: guardWait)
            try tvSmokeSelect("filterSummary.person.button", app: app, guardWait: guardWait)
            let target = "personFilter.person.person-a-solo.button"
            try tvSmokeFocus("personFilter.person.person-a-normal.button", app: app, guardWait: guardWait)
            try tvSmokeSelect(target, app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "person selected in normal mode") {
                Self.tvSmokeIsSelected($0.nodes[target]) && !Self.tvSmokeIsSolo($0.nodes[target])
            }
            try tvSmokePress(.playPause, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "physical Play/Pause selects solo mode") {
                Self.tvSmokeIsSelected($0.nodes[target]) && Self.tvSmokeIsSolo($0.nodes[target])
            }
            try tvSmokePress(.menu, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "person picker returns to startable summary") {
                $0.nodes["filterSummary.startPlayback.button"]?.isEnabled == true
                    && $0.nodes["filterSummary.person.button"] != nil
            }
        }
    }

    @MainActor
    func testPinGate() throws {
        // The existing Debug reset path selects synthetic PIN storage, never production Keychain proof.
        try tvSmokeRunFlow(shouldInjectConfiguration: true) { app, guardWait in
            try tvSmokeChooseMode("random", app: app, guardWait: guardWait)
            try tvSmokeOpenSettings(app, guardWait: guardWait)
            try tvSmokeSelect("settings.item.accessProtection", app: app, guardWait: guardWait)
            try tvSmokeSelect("settings.pin.input.enable", app: app, guardWait: guardWait)
            try tvSmokeEnterPIN(digit: 1, app: app, guardWait: guardWait)
            try tvSmokeSelect("settings.pin.input.enableConfirm", app: app, guardWait: guardWait)
            try tvSmokeEnterPIN(digit: 1, app: app, guardWait: guardWait)
            try tvSmokeSelect("settings.pin.enable.button", app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "synthetic PIN enabled") {
                $0.nodes["settings.pin.disable.button"] != nil
            }
            try tvSmokeReturnToPlayback(app, guardWait: guardWait)
            try tvSmokeOpenSettingsGate(app, guardWait: guardWait)
            try tvSmokeEnterPIN(digit: 0, app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "wrong PIN keeps Settings locked") {
                $0.nodes["pinEntry.error.message"] != nil && $0.nodes["settings.item.playback"] == nil
            }
            try tvSmokeEnterPIN(digit: 1, app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "correct synthetic PIN opens Settings") {
                $0.nodes["settings.item.playback"] != nil && $0.nodes["pinEntry.close.button"] == nil
            }
        }
    }

    @MainActor
    func testPlaybackControls() throws {
        try tvSmokeRunFlow(shouldInjectConfiguration: true, shouldExposeSceneProbe: true) { app, guardWait in
            try tvSmokeChooseMode("random", app: app, guardWait: guardWait)
            let initial = try tvSmokeSettledSceneReferences(app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "one eventual automatic scene advance") {
                guard let current = Self.tvSmokeSceneReferences($0) else { return false }
                return current != initial && Self.tvSmokeIsSettledScene($0)
            }
            try tvSmokeSelect(playPauseID, app: app, guardWait: guardWait)
            try tvSmokeExpectState("play", app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "paused navigation starts from a settled scene") {
                Self.tvSmokeIsSettledScene($0)
            }
            let beforeNext = try tvSmokeSettledSceneReferences(app, guardWait: guardWait)
            try tvSmokeSelect("slideshow.control.next.button", app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "remote Next advances scene") {
                guard let current = Self.tvSmokeSceneReferences($0) else { return false }
                return current != beforeNext && Self.tvSmokeIsSettledScene($0)
            }
            try tvSmokeSelect("slideshow.control.previous.button", app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "remote Previous returns to scene") {
                Self.tvSmokeSceneReferences($0) == beforeNext && Self.tvSmokeIsSettledScene($0)
            }
        }
    }

    @MainActor
    func testServerSwitch() throws {
        let peer = try requireStrictE2EPeerServerURL()
        let input = try requireStrictE2EInput()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var phase = "direct-switch"
        var phaseStartedAt = startedAt
        var lastPublicExif: [Int] = []
        var nextPresses = 0
        defer {
            print(
                "Smoke TV server switch phase=\(phase) elapsed_seconds=\(ProcessInfo.processInfo.systemUptime - phaseStartedAt) last_public_exif_indices=\(lastPublicExif) next_presses=\(nextPresses)"
            )
        }
        try tvSmokeRunFlow { app, guardWait in
            let fixtures = try tvSmokeSwitchFixtureMetadata(guardWait: guardWait)
            try tvSmokeChooseMode("random", app: app, guardWait: guardWait)
            try tvSmokeExpectPlayback(app, guardWait: guardWait)
            try tvSmokeOpenSettings(app, guardWait: guardWait)
            try tvSmokeSelect("settings.item.playback", app: app, guardWait: guardWait)
            try tvSmokeSelectPlaybackOption("displayMode", option: "singlePhoto", app: app, guardWait: guardWait)
            try tvSmokeReturnToPlayback(app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "server A photo is playing before switch") {
                lastPublicExif = Self.tvSmokePublicExifIndices($0)
                return lastPublicExif.contains { (1...5).contains($0) }
            }
            try tvSmokeOpenSettings(app, guardWait: guardWait)
            try tvSmokeSelect("settings.item.server", app: app, guardWait: guardWait)
            try tvSmokeSaveServer(
                StrictE2EInput(serverURL: peer, publicKey: input.publicKey), app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "server B save succeeds") {
                $0.nodes["settings.server.feedback.save.success"] != nil
            }
            peerExifLabels = fixtures.uniqueExifLabels
            try tvSmokeReturnToPlayback(app, guardWait: guardWait)
            // A healthy single-photo pool exposes every B candidate within one bounded traversal.
            for _ in 0..<fixtures.photoCount {
                if didObservePeerPhoto { break }
                let before = try tvSmokePlaybackIndex(app, guardWait: guardWait)
                if didObservePeerPhoto { break }
                try tvSmokeSelect("slideshow.control.next.button", app: app, guardWait: guardWait)
                nextPresses += 1
                try tvSmokeExpect(app, guardWait: guardWait, step: "server B playback advances") {
                    lastPublicExif = Self.tvSmokePublicExifIndices($0)
                    guard let current = Self.tvSmokeIndex($0.nodes[indexID]) else { return false }
                    return didObservePeerPhoto || current != before
                }
            }
            if !didObservePeerPhoto {
                try tvSmokeFail(
                    "a B-exclusive photo must appear within the bounded Next path", file: #filePath, line: #line)
            }
            print(
                "Smoke TV server switch phase=direct-switch elapsed_seconds=\(ProcessInfo.processInfo.systemUptime - startedAt)"
            )
            phase = "filter-lists"
            phaseStartedAt = ProcessInfo.processInfo.systemUptime
            // Changing mode before the B-photo proof could hide the stale source reported in the switch defect.
            try tvSmokeOpenSettings(app, guardWait: guardWait)
            try tvSmokeSelect("settings.item.playback", app: app, guardWait: guardWait)
            try tvSmokeSelect("settings.playback.mode.link", app: app, guardWait: guardWait)
            try tvSmokeSelect("settings.playback.mode.filtered.button", app: app, guardWait: guardWait)
            try tvSmokeConfirmFilterSetup(app, guardWait: guardWait)
            try tvSmokeSelect("filter.editor.album.entry", app: app, guardWait: guardWait)
            try tvSmokeExpectFixtureBList(
                "albumFilter.album.", target: "album-b-target", app: app, guardWait: guardWait)
            try tvSmokePress(.menu, guardWait: guardWait)
            try tvSmokeSelect("filter.editor.person.entry", app: app, guardWait: guardWait)
            try tvSmokeExpectFixtureBList(
                "personFilter.person.", target: "person-b-normal", app: app, guardWait: guardWait)
            try tvSmokePress(.menu, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "B lists return to filter editor") {
                $0.nodes["filter.editor.done.button"] != nil
            }
        }
    }

    @MainActor
    func testSettingsRelaunch() throws {
        try tvSmokeRunFlow { app, guardWait in
            try tvSmokeChooseMode("random", app: app, guardWait: guardWait)
            try tvSmokeOpenSettings(app, guardWait: guardWait)
            try tvSmokeSelect("settings.item.playback", app: app, guardWait: guardWait)
            try tvSmokeSelectPlaybackOption("autoPlay", option: "off", app: app, guardWait: guardWait)
            try tvSmokeReturnToPlayback(app, guardWait: guardWait)
            try tvSmokeExpectState("play", app: app, guardWait: guardWait)
            try tvSmokePerform("terminate", guardWait: guardWait) { app.terminate() }
            try tvSmokePerform("launch", guardWait: guardWait) { app.launch() }
            try tvSmokeExpectPlayback(app, guardWait: guardWait)
            try tvSmokeOpenSettings(app, guardWait: guardWait)
            try tvSmokeSelect("settings.item.playback", app: app, guardWait: guardWait)
            try tvSmokeSelect("settings.playback.autoPlay.link", app: app, guardWait: guardWait)
            try tvSmokeExpect(app, guardWait: guardWait, step: "relaunch retains autoplay off") {
                Self.tvSmokeIsSelected($0.nodes["settings.playback.autoPlay.off.button"])
            }
            try tvSmokeReturnToPlayback(app, guardWait: guardWait)
            try tvSmokeExpectState("play", app: app, guardWait: guardWait)
        }
    }

}
#endif
