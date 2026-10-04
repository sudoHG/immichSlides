#if os(tvOS)
import SwiftUI
import UIKit

extension SlideShowViewTV {
    #if DEBUG
    @ViewBuilder
    func smartFillMotionFrameProbeOverlay() -> some View {
        if shouldExposeSmartFillMotionFrameProbeForTesting {
            ZStack {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.smartfill.motionFrame.summary")
                    .accessibilityLabel(smartFillMotionFrameProbeRows.joined(separator: "\n"))
                    .focusable(false)
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.smartfill.productTransition.summary")
                    .accessibilityLabel(smartFillProductTransitionProbeLabel())
                    .focusable(false)
                smartFillMotionTraceProbeOverlay()
            }
            .task {
                await collectSmartFillMotionTraceIfNeeded()
            }
            .allowsHitTesting(false)
        }
    }

    private func smartFillProductTransitionProbeLabel() -> String {
        let snapshot = viewModel.sceneRenderSnapshot
        let layers = snapshot.layers
        let transitionLayers = smartFillTransitionLayers(in: layers)
        let transitionScenes = transitionLayers.compactMap { viewModel.scene(for: $0) }
        let roles =
            transitionLayers
            .map { smartFillProductTransitionRoleProbeValue(for: $0.role) }
            .joined(separator: "|")
        let sceneTypes =
            transitionScenes
            .map { smartFillProductSceneTypeProbeValue(for: $0) }
            .joined(separator: "|")
        let scopes =
            transitionScenes
            .map { smartFillProductSceneScopeProbeValue(for: $0) }
            .joined(separator: "|")
        let acceptedTransitionActive = isAcceptedSmartFillMotionTransitionActive(
            in: layers,
            snapshot: snapshot
        )
        return [
            "eventType=productTransition",
            "activeTransition=\(isScenePresentationTransitionActive(snapshot))",
            "productTransitionActive=\(acceptedTransitionActive)",
            "acceptedMotionTransitionActive=\(acceptedTransitionActive)",
            "productBlackBackingActive=\(smartFillProductTransitionBlackBacking(in: layers, snapshot: snapshot))",
            "blackBackingActive=\(smartFillProductTransitionBlackBacking(in: layers, snapshot: snapshot))",
            "transitionLayerCount=\(transitionLayers.count)",
            "transitionLayerRoles=\(roles.isEmpty ? "none" : roles)",
            "transitionLayerSceneTypes=\(sceneTypes.isEmpty ? "none" : sceneTypes)",
            "transitionLayerScopes=\(scopes.isEmpty ? "none" : scopes)"
        ].joined(separator: ";")
    }

    private func smartFillProductTransitionRoleProbeValue(
        for role: PlaybackSessionEngine.ScenePresentationLayerRole
    ) -> String {
        switch role {
        case .outgoing:
            return "outgoing"
        case .incoming:
            return "incoming"
        case .stable:
            return "settled"
        }
    }

    private func smartFillProductSceneTypeProbeValue(for scene: PlaybackScene) -> String {
        switch scene.smartFillReadback?.sceneType {
        case .double:
            return "double"
        case .triple:
            return "triple"
        case .single:
            return "single"
        case .fallback:
            return "fallback"
        case nil:
            return "legacy"
        }
    }

    private func smartFillProductSceneScopeProbeValue(for scene: PlaybackScene) -> String {
        switch scene.smartFillReadback?.sceneType {
        case .double, .triple, .single:
            return "acceptedMotion"
        case .fallback:
            return "smartFillNoMotion"
        case nil:
            return viewModel.isSmartFillPresentationModeActive ? "smartFillLegacyNoMotion" : "legacy"
        }
    }

    @ViewBuilder
    private func smartFillMotionTraceProbeOverlay() -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("slideshow.smartfill.motionFrame.trace.status")
            .accessibilityLabel(smartFillMotionTraceStatusLabel)
            .focusable(false)

        ForEach(Array(smartFillMotionTraceChunks().enumerated()), id: \.offset) { index, chunk in
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("slideshow.smartfill.motionFrame.trace.chunk.\(index)")
                .accessibilityLabel(chunk)
                .focusable(false)
        }
    }

    private var shouldCollectSmartFillMotionTraceForTesting: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_COLLECT_SMARTFILL_MOTION_TRACE"] == "1"
    }

    private var smartFillMotionTraceStatusLabel: String {
        [
            "eventType=motionTraceStatus",
            "status=\(smartFillMotionTraceStatus)",
            "lineCount=\(smartFillMotionTraceLineCount)",
            "chunkCount=\(smartFillMotionTraceChunks().count)",
            "tracePath=\(smartFillMotionTraceFilePath.isEmpty ? "missing" : smartFillMotionTraceFilePath)",
            "sampleIntervalSeconds=\(String(format: "%.6f", smartFillMotionTraceSampleIntervalSeconds()))",
            "startTimeoutSeconds=\(String(format: "%.6f", smartFillMotionTraceStartTimeoutSeconds()))",
            "durationSeconds=\(String(format: "%.6f", smartFillMotionTraceDurationSeconds()))",
            "collectionStartedUptimeSeconds=\(String(format: "%.6f", smartFillMotionTraceCollectionStartedAt))"
        ].joined(separator: ";")
    }

    private func smartFillMotionTraceChunks() -> [String] {
        let maxChunkLength = 12_000
        var chunks: [String] = []
        var current = ""
        for line in smartFillMotionTraceLines {
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.count > maxChunkLength, !current.isEmpty {
                chunks.append(current)
                current = line
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    @MainActor
    private func collectSmartFillMotionTraceIfNeeded() async {
        guard shouldCollectSmartFillMotionTraceForTesting, !hasSmartFillMotionTraceStarted else { return }
        hasSmartFillMotionTraceStarted = true
        smartFillMotionTraceStatus = "waiting-for-accepted-motion-frame"
        smartFillMotionTraceLines = []
        smartFillMotionTraceBuffer.reset()
        smartFillMotionTraceFilePath = ""
        smartFillMotionTraceLineCount = 0
        smartFillMotionTraceWaitStartedAt = ProcessInfo.processInfo.systemUptime
        smartFillMotionTraceCollectionStartedAt = 0
        smartFillMotionTraceNextSampleIndex = 0

        let waitTimeout = smartFillMotionTraceStartTimeoutSeconds()
        let duration = smartFillMotionTraceDurationSeconds()
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            appendSmartFillMotionTraceSampleIfNeeded(rows: smartFillMotionFrameProbeRows, now: now)
            switch smartFillMotionTraceStatus {
            case "waiting-for-accepted-motion-frame":
                if now - smartFillMotionTraceWaitStartedAt >= waitTimeout {
                    smartFillMotionTraceStatus = "missing-accepted-motion-frame"
                    return
                }
            case "collecting":
                if now - smartFillMotionTraceCollectionStartedAt >= duration {
                    finishSmartFillMotionTraceCollection()
                    return
                }
            default:
                return
            }
            try? await Task.sleep(nanoseconds: smartFillMotionTraceMonitorSleepNanoseconds())
            guard !Task.isCancelled else {
                smartFillMotionTraceStatus = "cancelled"
                return
            }
        }
    }

    @MainActor
    private func appendSmartFillMotionTraceSampleIfNeeded(
        rows: [String],
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard shouldCollectSmartFillMotionTraceForTesting,
            hasSmartFillMotionTraceStarted,
            smartFillMotionTraceStatus == "waiting-for-accepted-motion-frame"
                || smartFillMotionTraceStatus == "collecting"
        else {
            return
        }
        let traceRows = smartFillMotionTraceRowsForCurrentOverlay(rows)
        let hasAcceptedAvailableMotionRow = traceRows.contains { row in
            row.contains("acceptedMotionScope=true") && row.contains("progressFrameStatus=available")
        }
        let hasCleanSettledMotionRow = traceRows.contains { row in
            row.contains("acceptedMotionScope=true") && row.contains("progressFrameStatus=available")
                && row.contains("appOverlayPollution=none") && row.contains("renderRole=settled")
        }
        let canSample =
            smartFillMotionTraceStatus == "collecting"
            ? hasAcceptedAvailableMotionRow
            : hasCleanSettledMotionRow
        guard canSample else {
            return
        }

        if smartFillMotionTraceStatus == "waiting-for-accepted-motion-frame" {
            smartFillMotionTraceStatus = "collecting"
            smartFillMotionTraceCollectionStartedAt = now
            smartFillMotionTraceLines = []
            smartFillMotionTraceBuffer.reset()
            smartFillMotionTraceNextSampleIndex = 0
        }

        let elapsed = now - smartFillMotionTraceCollectionStartedAt
        guard elapsed <= smartFillMotionTraceDurationSeconds() else {
            finishSmartFillMotionTraceCollection()
            return
        }
        let sampleInterval = smartFillMotionTraceSampleIntervalSeconds()
        while true {
            let nextSampleElapsed = TimeInterval(smartFillMotionTraceNextSampleIndex) * sampleInterval
            guard elapsed + 0.0005 >= nextSampleElapsed else { return }

            let prefix = [
                "sampleIndex=\(smartFillMotionTraceNextSampleIndex)",
                "elapsedSeconds=\(String(format: "%.6f", nextSampleElapsed))",
                "captureElapsedSeconds=\(String(format: "%.6f", elapsed))"
            ].joined(separator: ";")
            if let productSceneLabel = smartFillProductSceneSequenceTraceLabel() {
                smartFillMotionTraceBuffer.append("\(prefix);\(productSceneLabel)")
            }
            smartFillMotionTraceBuffer.append(contentsOf: traceRows.map { "\(prefix);\($0)" })
            smartFillMotionTraceNextSampleIndex += 1
        }
    }

    private func smartFillProductSceneSequenceTraceLabel() -> String? {
        let snapshot = viewModel.sceneRenderSnapshot
        guard
            let visibleLayer = snapshot.layers.last(where: {
                $0.opacity > 0 && ($0.role == .stable || $0.role == .incoming)
            }),
            let scene = viewModel.scene(for: visibleLayer)
        else {
            return nil
        }
        let sceneFields = [
            "sceneId=\(MotionTransformResolver.diagnosticIdentityToken(scene.id))",
            "sceneType=\(smartFillProductSceneTypeProbeValue(for: scene))",
            "slotCount=\(scene.photoSlots.count)",
            "slotRefs=\(scene.diagnosticSlotReferences(separator: "|"))"
        ]
        let transitionFields = smartFillTraceFields(from: smartFillProductTransitionProbeLabel())
            .filter { $0 != "eventType=productTransition" }
        return (["eventType=productSceneSequence"] + sceneFields + transitionFields)
            .joined(separator: ";")
    }

    private func smartFillTraceFields(from raw: String) -> [String] {
        raw.split(separator: ";", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func smartFillMotionTraceRowsForCurrentOverlay(_ rows: [String]) -> [String] {
        rows.map { row in
            let retainedFields = smartFillTraceFields(from: row).filter { field in
                !field.hasPrefix("controlBarVisible=") && !field.hasPrefix("appOverlayPollution=")
            }
            let hostOverlayFields = [
                "controlBarVisible=\(isControlBarVisible ? "true" : "false")",
                "appOverlayPollution=\(isControlBarVisible ? "controlBar" : "none")"
            ]
            return (retainedFields + hostOverlayFields).joined(separator: ";")
        }
    }

    @MainActor
    private func finishSmartFillMotionTraceCollection() {
        guard smartFillMotionTraceStatus == "collecting" else { return }
        let collected = smartFillMotionTraceBuffer.lines
        smartFillMotionTraceLineCount = collected.count
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartfill-motion-trace-\(UUID().uuidString).txt")
        do {
            try collected.joined(separator: "\n").write(to: traceURL, atomically: true, encoding: .utf8)
            smartFillMotionTraceFilePath = traceURL.path
            smartFillMotionTraceLines = []
            smartFillMotionTraceBuffer.reset()
        } catch {
            smartFillMotionTraceFilePath = "write-failed"
            smartFillMotionTraceLines = collected
        }
        smartFillMotionTraceStatus = "complete"
    }

    private func smartFillMotionTraceMonitorSleepNanoseconds() -> UInt64 {
        UInt64((min(smartFillMotionTraceSampleIntervalSeconds(), 0.025) * 1_000_000_000).rounded())
    }

    private func smartFillMotionTraceSampleIntervalSeconds() -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        let rawValue = env["UI_TEST_SMARTFILL_MOTION_TRACE_SAMPLE_INTERVAL_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 0.025
        }
        return min(value, 0.05)
    }

    private func smartFillMotionTraceDurationSeconds() -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        let rawValue = env["UI_TEST_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 18
        }
        return value
    }

    private func smartFillMotionTraceStartTimeoutSeconds() -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        let rawValue = env["UI_TEST_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 60
        }
        return value
    }
    #else
    @ViewBuilder
    func smartFillMotionFrameProbeOverlay() -> some View {
        EmptyView()
    }
    #endif
}
#endif
