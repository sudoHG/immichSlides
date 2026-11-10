import Foundation
import XCTest

enum StrictE2ESceneCapture {
    static func hasProgressingPublicationFacts(
        firstTransition: [String: String], before: [String: String], after: [String: String]
    ) -> Bool {
        guard [before, after].allSatisfy(hasCompletePublicationFacts) else { return false }
        let previousRender = SharedSceneEvidenceManifest.parseKeyValueFields(before["render"] ?? "")
        let lastRender = SharedSceneEvidenceManifest.parseKeyValueFields(after["render"] ?? "")
        let firstRender = SharedSceneEvidenceManifest.parseKeyValueFields(firstTransition["render"] ?? "")
        guard previousRender["playbackPaused"] == "false", lastRender["playbackPaused"] == "false",
            let layerIDs = firstRender["layerIDs"], layerIDs == lastRender["layerIDs"],
            layerIDs.components(separatedBy: "|").count == 2,
            layerIDs.components(separatedBy: "|").allSatisfy({ !$0.isEmpty }),
            let firstProgress = fadeProgress(firstRender), let lastProgress = fadeProgress(lastRender)
        else { return false }
        let minimumFadeProgressAdvance = 0.01
        return lastProgress - firstProgress >= minimumFadeProgressAdvance
    }

    private static func fadeProgress(_ render: [String: String]) -> Double? {
        guard render["phase"] == "transition", render["layerRoles"] == "outgoing|incoming",
            let opacities = render["layerOpacities"]?.components(separatedBy: "|"), opacities.count == 2,
            let outgoing = Double(opacities[0]), let incoming = Double(opacities[1]),
            (0...1).contains(outgoing), (0...1).contains(incoming)
        else { return nil }
        return (1 - outgoing) + incoming
    }

    static func hasCompletePublicationFacts(_ observation: [String: String]) -> Bool {
        let manifest = SharedSceneEvidenceManifest.parseKeyValueFields(observation["manifest"] ?? "")
        guard let slotCount = Int(manifest["slotCount"] ?? ""), slotCount > 0,
            let readiness = manifest["slotReadiness"]?.components(separatedBy: ","),
            readiness.count == slotCount, readiness.allSatisfy({ $0 == "ready" }),
            let references = manifest["ledgerSceneAssets"]?.components(separatedBy: ","),
            references.count == slotCount,
            references.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            Double(manifest["canvasCoverage"] ?? "") == 1, Double(manifest["emptyCanvasRatio"] ?? "") == 0,
            Int(manifest["gapPixelCount"] ?? "") == 0, Int(manifest["overlapPixelCount"] ?? "") == 0,
            SharedSceneEvidenceManifest.manifestObservation(from: observation["manifest"] ?? "")?
                .isCompleteVisibleScene == true
        else { return false }
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
        guard render["loadingVisible"] == "false", let roles = render["layerRoles"]?.components(separatedBy: "|"),
            !roles.isEmpty, let opacities = render["layerOpacities"]?.components(separatedBy: "|"),
            let progress = render["motionRawProgress"]?.components(separatedBy: "|"),
            opacities.count == roles.count, progress.count == roles.count,
            opacities.allSatisfy({ Double($0).map { (0...1).contains($0) } == true }),
            progress.allSatisfy({ Double($0).map { $0.isFinite && $0 >= 0 } == true })
        else { return false }
        if render["phase"] == "stablePhoto" { return isStableWindow(observation) }
        return render["phase"] == "transition" && roles == ["outgoing", "incoming"]
    }

    static func referencesMatch(before: [String: String], after: [String: String]) -> Bool {
        let beforeRefs = SharedSceneEvidenceManifest.parseKeyValueFields(before["manifest"] ?? "")["ledgerSceneAssets"]
        let afterRefs = SharedSceneEvidenceManifest.parseKeyValueFields(after["manifest"] ?? "")["ledgerSceneAssets"]
        return beforeRefs?.isEmpty == false && beforeRefs == afterRefs
    }

    static func isStableWindow(_ observation: [String: String]) -> Bool {
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
        guard render["phase"] == "stablePhoto", render["layerRoles"] == "stable",
            render["loadingVisible"] == "false",
            let opacity = Double(render["layerOpacities"] ?? ""), opacity == 1,
            let progress = Double(render["motionRawProgress"] ?? ""), (0...1).contains(progress)
        else { return false }
        return SharedSceneEvidenceManifest.manifestObservation(from: observation["manifest"] ?? "")?
            .isCompleteVisibleScene == true
    }

    /// Failure diagnostics only: the stable-window judge above remains authoritative.
    static func stableWindowRejections(_ observation: [String: String]) -> [String] {
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
        var reasons: [String] = []
        if render["phase"] != "stablePhoto" { reasons.append("phase") }
        if render["layerRoles"] != "stable" { reasons.append("layer-roles") }
        if render["loadingVisible"] != "false" { reasons.append("loading-visible") }
        let opacities = render["layerOpacities"].map { $0.components(separatedBy: "|") } ?? []
        if opacities.count != 1 { reasons.append("opacity-count") }
        if opacities.count == 1, Double(opacities[0]) != 1 { reasons.append("opacity-value") }
        let progress = render["motionRawProgress"].map { $0.components(separatedBy: "|") } ?? []
        if progress.count != 1 { reasons.append("motion-progress-count") }
        if progress.count == 1, Double(progress[0]).map({ (0...1).contains($0) }) != true {
            reasons.append("motion-progress-range")
        }
        if SharedSceneEvidenceManifest.manifestObservation(from: observation["manifest"] ?? "")?
            .isCompleteVisibleScene != true
        {
            reasons.append("manifest")
        }
        return reasons
    }
}

/// Bounded timing of existing reads. No observation, delay or verdict is introduced here.
struct AlbumCaptureDiagnostics {
    private static let maximumPolls = 16
    let startedAtUptime: TimeInterval
    let windowSeconds: TimeInterval
    let settleSeconds: TimeInterval
    let site: String
    let probe: String
    private(set) var pollCount = 0
    private var polls: [[Double]] = []

    init(
        startedAtUptime: TimeInterval, windowSeconds: TimeInterval, settleSeconds: TimeInterval,
        site: String, probe: String
    ) {
        self.startedAtUptime = startedAtUptime
        self.windowSeconds = windowSeconds
        self.settleSeconds = settleSeconds
        self.site = site
        self.probe = probe
    }

    mutating func observed(requestedAtUptime: TimeInterval, returnedAtUptime: TimeInterval) {
        pollCount += 1
        if polls.count == Self.maximumPolls { polls.removeFirst() }
        polls.append([requestedAtUptime - startedAtUptime, returnedAtUptime - startedAtUptime])
    }

    func projection(
        observation: [String: String], previousScene: [String: String]?,
        inputs: (fixture: String, labels: [String: String], pause: [String: Double])?
    ) -> [String: Any]? {
        guard ["album-play-1", "album-play-2", "album-play-3"].contains(site),
            ["frameSynchronized", "contract"].contains(probe),
            let inputs, ["a", "b"].contains(inputs.fixture),
            startedAtUptime.isFinite, startedAtUptime >= 0,
            (0...Int(Int32.max)).contains(pollCount), polls.count == min(pollCount, Self.maximumPolls),
            windowSeconds.isFinite, windowSeconds > 0, windowSeconds <= 86_400,
            settleSeconds.isFinite, settleSeconds >= 0, settleSeconds < windowSeconds
        else { return nil }
        var previousReturnSeconds = Double.zero
        for poll in polls {
            guard poll.count == 2, poll.allSatisfy({ $0.isFinite && (0...86_400).contains($0) }),
                previousReturnSeconds <= poll[0], poll[0] <= poll[1]
            else { return nil }
            previousReturnSeconds = poll[1]
        }
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
        let previous = SharedSceneEvidenceManifest.parseKeyValueFields(previousScene?["render"] ?? "")
        let manifest = SharedSceneEvidenceManifest.parseKeyValueFields(observation["manifest"] ?? "")
        let refs = manifest["ledgerSceneAssets"]?.components(separatedBy: ",") ?? []
        guard refs.count <= 64 else { return nil }
        let members = refs.compactMap { inputs.labels[$0] }
        let allowedMembers = Set((1...(inputs.fixture == "a" ? 5 : 8)).map { "A\($0)" })
        guard members.allSatisfy({ allowedMembers.contains($0) }) else { return nil }
        let historyBaseline =
            previousScene == nil
            ? "no-baseline"
            : (Int(previous["historyCount"] ?? "") != nil && Int(render["historyCount"] ?? "") != nil
                ? "valid" : "unreadable")
        let layersBaseline =
            previousScene == nil
            ? "no-baseline"
            : ([previous["layerIDs"], render["layerIDs"]].allSatisfy { $0?.isEmpty == false && $0 != "none" }
                ? "valid" : "unreadable")
        var pause: [String: Any] = [:]
        for key in ["requested_seconds", "returned_seconds", "observed_seconds"] {
            if let uptime = inputs.pause[key] {
                let offset = uptime - startedAtUptime
                guard offset.isFinite, (-86_400...86_400).contains(offset) else { return nil }
                pause[key] = offset
            } else {
                pause[key] = NSNull()
            }
        }
        if let returned = inputs.pause["returned_seconds"] {
            guard let requested = inputs.pause["requested_seconds"], requested <= returned else { return nil }
            if let observed = inputs.pause["observed_seconds"], returned > observed { return nil }
        }
        return [
            "schema_version": 1, "site": site, "probe": probe, "fixture": inputs.fixture,
            "rejections": StrictE2ESceneCapture.stableWindowRejections(observation),
            "poll_count": pollCount, "polls": polls, "polls_truncated": pollCount > Self.maximumPolls,
            "window_seconds": windowSeconds, "settle_seconds": settleSeconds,
            "baseline": ["history": historyBaseline, "layers": layersBaseline], "pause": pause,
            "members": members, "unmapped_member_count": refs.count - members.count
        ]
    }
}

struct StrictE2EInput {
    let serverURL: String
    let publicKey: String
}

struct StrictE2EPrivatePINInput {
    static let requiredPINLength: Int = 6
    let correct: String
    let wrong: String
}

private enum StrictE2ETestSupportError: LocalizedError {
    case missingInput(String)
    case invalidServerURL
    case nonPublicKey
    case invalidPINFormat(String)
    case pinsNotDistinct

    var errorDescription: String? {
        switch self {
        case .missingInput(let key):
            return "strict E2E runner is missing input key: \(key)"
        case .invalidServerURL:
            return "strict E2E only allows a 127.0.0.1/localhost /api server address."
        case .nonPublicKey:
            return "strict E2E only allows the public synthetic server key."
        case .invalidPINFormat(let key):
            return "strict E2E private PIN input has an invalid format: \(key)"
        case .pinsNotDistinct:
            return "strict E2E correct PIN and wrong PIN must differ"
        }
    }
}

extension XCTestCase {
    func requireStrictE2EInput(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StrictE2EInput {
        let urlKey = "STRICT_E2E_INPUT_SERVER_URL"
        let publicKeyKey = "STRICT_E2E_INPUT_PUBLIC_KEY"
        guard let serverURL = environment[urlKey], !serverURL.isEmpty else {
            throw StrictE2ETestSupportError.missingInput(urlKey)
        }
        guard let publicKey = environment[publicKeyKey], !publicKey.isEmpty else {
            throw StrictE2ETestSupportError.missingInput(publicKeyKey)
        }
        guard let url = URL(string: serverURL),
            url.scheme == "http",
            ["127.0.0.1", "localhost"].contains(url.host ?? ""),
            url.path == "/api"
        else {
            throw StrictE2ETestSupportError.invalidServerURL
        }
        let allowedPublicKeys = [
            "immichslides-public-e2e-key",
            "immichslides-public-e2e-wrong-key"
        ]
        guard allowedPublicKeys.contains(publicKey) else {
            throw StrictE2ETestSupportError.nonPublicKey
        }
        return StrictE2EInput(serverURL: serverURL, publicKey: publicKey)
    }

    func requireStrictE2EPeerServerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        // Either environment key can provide the peer-server URL; both are accepted for compatibility.
        let tvKey = "STRICT_E2E_INPUT_SERVER_B_URL"
        let iosKey = "STRICT_E2E_INPUT_SERVER_URL_B"
        let serverURL: String
        if let value = environment[tvKey], !value.isEmpty {
            serverURL = value
        } else if let value = environment[iosKey], !value.isEmpty {
            serverURL = value
        } else {
            throw StrictE2ETestSupportError.missingInput("\(tvKey)|\(iosKey)")
        }
        guard let url = URL(string: serverURL),
            url.scheme == "http",
            ["127.0.0.1", "localhost"].contains(url.host ?? ""),
            url.path == "/api"
        else {
            throw StrictE2ETestSupportError.invalidServerURL
        }
        return serverURL
    }

    // PINs are read only from the runner environment outside Git; source constants are not accepted, and errors
    // report only key names.
    func requirePrivatePINInput(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StrictE2EPrivatePINInput {
        let correctKey = "STRICT_E2E_INPUT_PIN"
        let wrongKey = "STRICT_E2E_INPUT_PIN_WRONG"
        guard let correct = firstEnvironmentValue(forKey: correctKey, environment: environment) else {
            throw StrictE2ETestSupportError.missingInput(correctKey)
        }
        guard let wrong = firstEnvironmentValue(forKey: wrongKey, environment: environment) else {
            throw StrictE2ETestSupportError.missingInput(wrongKey)
        }
        guard isPrivatePINFormat(correct) else {
            throw StrictE2ETestSupportError.invalidPINFormat(correctKey)
        }
        guard isPrivatePINFormat(wrong) else {
            throw StrictE2ETestSupportError.invalidPINFormat(wrongKey)
        }
        guard correct != wrong else {
            throw StrictE2ETestSupportError.pinsNotDistinct
        }
        return StrictE2EPrivatePINInput(correct: correct, wrong: wrong)
    }

    @MainActor
    func launchStrictE2EApp(
        recordSceneSequence: Bool = false, disablePlaybackEntryHint: Bool = false,
        playbackIntervalSeconds: Int? = nil, pauseOnInitialStableScene: Bool = false, recordReduceMotion: Bool = false
    ) throws
        -> XCUIApplication
    {
        let app = XCUIApplication()
        try prepareStrictE2ELaunch(
            app, recordSceneSequence: recordSceneSequence, disablePlaybackEntryHint: disablePlaybackEntryHint,
            playbackIntervalSeconds: playbackIntervalSeconds, pauseOnInitialStableScene: pauseOnInitialStableScene,
            recordReduceMotion: recordReduceMotion)
        FirstFailureContext.mark("launch-app", element: "app-window")
        FirstFailureContext.action("launch") { app.launch() }
        return app
    }

    // Cold relaunch reuses the same container and clears launchEnvironment so no UI_TEST_* / IMMICH_TEST_* keys linger.
    @MainActor
    func relaunchStrictE2EApp(_ app: XCUIApplication) throws {
        FirstFailureContext.action("terminate") { app.terminate() }
        try prepareStrictE2ELaunch(app)
        FirstFailureContext.mark("launch-app", element: "app-window")
        FirstFailureContext.action("launch") { app.launch() }
    }

    @MainActor
    func attachStrictE2EScreenshot(app: XCUIApplication, name: String) {
        FirstFailureContext.mark("capture-frame", element: "app-window")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func prepareStrictE2ELaunch(
        _ app: XCUIApplication, recordSceneSequence: Bool = false, disablePlaybackEntryHint: Bool = false,
        playbackIntervalSeconds: Int? = nil, pauseOnInitialStableScene: Bool = false, recordReduceMotion: Bool = false
    ) throws {
        app.launchEnvironment = [:]
        if recordReduceMotion, let directory = StrictE2EVisualEvidence.directory() {
            app.launchEnvironment["UI_TEST_REDUCE_MOTION_EVIDENCE_DIR"] = directory.path
        }
        if recordSceneSequence {
            // Read-only probes expose the rendered scene; onboarding still uses the real UI.
            app.launchEnvironment["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"] = "1"
        }
        if disablePlaybackEntryHint {
            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }
        if let playbackIntervalSeconds {
            app.launchEnvironment["UI_TEST_PLAYBACK_INTERVAL_SECONDS"] = String(playbackIntervalSeconds)
        }
        if pauseOnInitialStableScene {
            app.launchEnvironment["UI_TEST_PAUSE_ON_INITIAL_STABLE_SCENE"] = "1"
        }

        let audit = try JSONSerialization.data(
            withJSONObject: ["launch_environment_keys": app.launchEnvironment.keys.sorted()],
            options: [.prettyPrinted, .sortedKeys]
        )
        let attachment = XCTAttachment(data: audit, uniformTypeIdentifier: "public.json")
        attachment.name = "strict-e2e-app-launch-environment-audit"
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }

    @MainActor
    func strictSceneFrameObservation(app: XCUIApplication) -> [String: String] {
        FirstFailureContext.mark("query-element", element: "slideshow.scenePresentation.contract.summary")
        var values = ["manifest": "", "render": "", "index": ""]
        let identifiers = [
            "slideshow.smartfill.currentManifest.flag": "manifest",
            "slideshow.scenePresentation.contract.summary": "render",
            "slideshow.control.indexProbe": "index"
        ]
        func visit(_ node: XCUIElementSnapshot) {
            if let key = identifiers[node.identifier] {
                values[key] = key == "index" ? String(describing: node.value ?? "") : node.label
            }
            node.children.forEach(visit)
        }
        if let snapshot = try? app.snapshot() { visit(snapshot) }
        return values
    }

    func strictSceneCaptureDiagnostic(before: [String: String], after: [String: String], stable: Bool) -> String {
        "stable=\(stable) referencesMatch=\(StrictE2ESceneCapture.referencesMatch(before: before, after: after))"
    }

    func attachStrictSceneObservation(before: [String: String], after: [String: String], name: String) {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["before": before, "after": after], options: [.sortedKeys])
        else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func captureStrictSceneFrame(app: XCUIApplication, name: String, attachmentName: String) -> [String: Any] {
        FirstFailureContext.mark("capture-frame", element: "app-window")
        let before = strictSceneFrameObservation(app: app)
        FirstFailureContext.mark("capture-frame", element: "app-window")
        let png = app.screenshot().pngRepresentation
        let after = strictSceneFrameObservation(app: app)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
        StrictE2EVisualEvidence.writePNG(png, name: name)
        let identity = StrictE2EPhotoIdentity.classify(png: png)
        let stable = [before, after].allSatisfy { observation in
            let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
            return render["phase"] == "stablePhoto" && render["layerRoles"] == "stable"
                && render["loadingVisible"] == "false"
                && SharedSceneEvidenceManifest.manifestObservation(from: observation["manifest"] ?? "")?
                    .isCompleteVisibleScene == true
        }
        let refsBefore = SharedSceneEvidenceManifest.parseKeyValueFields(before["manifest"] ?? "")["ledgerSceneAssets"]
        let refsAfter = SharedSceneEvidenceManifest.parseKeyValueFields(after["manifest"] ?? "")["ledgerSceneAssets"]
        let payload: [String: Any] = ["before": before, "after": after]
        StrictE2EVisualEvidence.writeJSON(payload, name: "\(name).scene.json")
        FirstFailureContext.mark("capture-frame", element: "app-window")
        XCTAssertTrue(
            !png.isEmpty && identity.status != .black && identity.status != .blank
                && stable && refsBefore != nil && refsBefore == refsAfter,
            "Visual ID failed \(name): \(identity.status.rawValue) \(identity.notes.joined(separator: " ")) \(strictSceneCaptureDiagnostic(before: before, after: after, stable: stable))"
        )
        return payload
    }

    private func firstEnvironmentValue(
        forKey key: String,
        environment: [String: String]
    ) -> String? {
        for candidate in [environment[key], environment["TEST_RUNNER_\(key)"]] {
            if let value = candidate, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func isPrivatePINFormat(_ pin: String) -> Bool {
        pin.count == StrictE2EPrivatePINInput.requiredPINLength && pin.allSatisfy(\.isNumber)
    }
}
