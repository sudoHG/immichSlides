//
//  PlaybackImageRequestLifecycleDiagnosticsTests.swift
//  immichSlidesTests
//
//  Lifecycle diagnostics record request facts only; summaries and gates consume those facts
//  without changing load behavior.
//

import Foundation
import SDWebImage
import Testing
@testable import immichSlides

#if DEBUG
@MainActor
@Suite
struct PlaybackImageRequestLifecycleDiagnosticsTests {

    @Test
    func `cache persistence snapshot encodes the fixed schema and every stored field`() throws {
        let snapshot = PlaybackImageCachePersistenceSnapshot(
            checkSequence: 7,
            activeTaskCount: 2,
            readyFullsizeCount: 9,
            diskReadyFullsizeCount: 4,
            readyPreviewCount: 7,
            diskReadyPreviewCount: 5
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(snapshot)
        let expected = """
            {"activeTaskCount":2,"checkSequence":7,"diskReadyFullsizeCount":4,"diskReadyPreviewCount":5,"isPersisted":false,"missingReadyFullsizeCount":5,"missingReadyPreviewCount":2,"readyFullsizeCount":9,"readyPreviewCount":7,"schemaVersion":"playback-image-cache-persistence-snapshot-v1"}
            """

        #expect(encoded == Data(expected.utf8))
    }

    @Test
    func `cache persistence snapshot decoding ignores schema input and preserves stored fields`() throws {
        // Decoding has always trusted the stored fields, including values the initializer would recompute.
        let fields = """
            "activeTaskCount":2,"checkSequence":7,"diskReadyFullsizeCount":4,"diskReadyPreviewCount":5,"isPersisted":true,"missingReadyFullsizeCount":123,"missingReadyPreviewCount":456,"readyFullsizeCount":9,"readyPreviewCount":7
            """
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let expected = """
            {\(fields),"schemaVersion":"playback-image-cache-persistence-snapshot-v1"}
            """

        for schemaField in [
            "", #","schemaVersion":"other-schema""#, #","schemaVersion":37"#, #","schemaVersion":null"#
        ] {
            let payload = Data("{\(fields)\(schemaField)}".utf8)
            let decoded = try JSONDecoder().decode(PlaybackImageCachePersistenceSnapshot.self, from: payload)

            #expect(decoded.schemaVersion == "playback-image-cache-persistence-snapshot-v1")
            #expect(try encoder.encode(decoded) == Data(expected.utf8))
        }
    }

    @Test
    func `evidence summary writes to disk only on an explicit flush`() throws {
        let evidenceDirectory = try makeEvidenceDirectory(name: "flush-summary")
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(
            isEnabled: true,
            environment: ["UI_TEST_EVIDENCE_DIR": evidenceDirectory.path]
        )
        let token = UUID()

        diagnostics.record(
            .requestStarted(
                requestId: "request",
                source: .assetManagerLoadPhoto,
                assetId: "asset-a",
                size: .fullsize,
                mode: .single,
                role: .current,
                cacheKeyHash: "cache-a",
                contextHash: "manager",
                navigationToken: token,
                sceneId: "scene-a",
                timestamp: 1
            ))

        let eventsURL = evidenceDirectory.appending(path: "playback-request-lifecycle-events.jsonl")
        let summaryURL = evidenceDirectory.appending(path: "playback-request-lifecycle-summary.json")
        #expect(FileManager.default.fileExists(atPath: eventsURL.path))
        #expect(!FileManager.default.fileExists(atPath: summaryURL.path))

        let eventText = try String(contentsOf: eventsURL, encoding: .utf8)
        let event = try #require(
            JSONSerialization.jsonObject(with: Data(eventText.utf8)) as? [String: Any])
        #expect(event["assetId"] as? String == PlaybackImageRequestLifecycleDiagnostics.redactedHash("asset-a"))
        #expect(event["sceneId"] as? String == PlaybackImageRequestLifecycleDiagnostics.redactedHash("scene-a"))
        #expect(!eventText.contains("asset-a"))
        #expect(!eventText.contains("scene-a"))
        #expect(event["requestId"] as? String == "request")

        diagnostics.flushPlaybackImageRequestLifecycleEvidence()

        #expect(FileManager.default.fileExists(atPath: summaryURL.path))
        let summaryData = try Data(contentsOf: summaryURL)
        let summary = try JSONDecoder().decode(PlaybackImageRequestLifecycleSummary.self, from: summaryData)
        #expect(summary.total.requestCount == 1)
    }

    @Test
    func `reading the summary does not trigger a flush or write the summary file`() throws {
        let evidenceDirectory = try makeEvidenceDirectory(name: "summary-read-no-flush")
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(
            isEnabled: true,
            environment: ["UI_TEST_EVIDENCE_DIR": evidenceDirectory.path]
        )
        diagnostics.record(
            .requestStarted(
                requestId: "request",
                source: .assetManagerLoadPhoto,
                assetId: "asset-a",
                size: .fullsize,
                mode: .single,
                role: .current,
                cacheKeyHash: "cache-a",
                contextHash: "manager",
                navigationToken: UUID(),
                sceneId: "scene-a",
                timestamp: 1
            ))

        let summaryURL = evidenceDirectory.appending(path: "playback-request-lifecycle-summary.json")
        for _ in 0..<5 {
            let summary = diagnostics.makeSummary()
            #expect(summary.total.requestCount == 1)
            #expect(summary.evidenceFlushCount == 0)
            #expect(!FileManager.default.fileExists(atPath: summaryURL.path))
        }

        diagnostics.flushPlaybackImageRequestLifecycleEvidence()

        let flushedSummary = diagnostics.makeSummary()
        #expect(flushedSummary.evidenceFlushCount == 1)
        let summaryData = try Data(contentsOf: summaryURL)
        let writtenSummary = try JSONDecoder().decode(PlaybackImageRequestLifecycleSummary.self, from: summaryData)
        #expect(writtenSummary.evidenceFlushCount == 1)
    }

    @Test
    func `marking a late result still waits for flush before writing the summary`() throws {
        let evidenceDirectory = try makeEvidenceDirectory(name: "flush-late")
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(
            isEnabled: true,
            environment: ["UI_TEST_EVIDENCE_DIR": evidenceDirectory.path]
        )
        let oldToken = UUID()

        diagnostics.record(
            .requestStarted(
                requestId: "old",
                source: .rendererSingleFullsize,
                assetId: "asset-old",
                size: .fullsize,
                mode: .single,
                role: .incoming,
                cacheKeyHash: "cache-old",
                contextHash: "foreground",
                navigationToken: oldToken,
                sceneId: "scene-old",
                timestamp: 1
            ))
        diagnostics.record(
            .loadFinished(
                requestId: "old",
                cacheResult: .disk,
                imagePixelWidth: nil,
                imagePixelHeight: nil,
                timestamp: 2
            ))
        diagnostics.markLateResults(currentNavigationToken: UUID())

        let summaryURL = evidenceDirectory.appending(path: "playback-request-lifecycle-summary.json")
        #expect(!FileManager.default.fileExists(atPath: summaryURL.path))

        diagnostics.flushPlaybackImageRequestLifecycleEvidence()

        let summaryData = try Data(contentsOf: summaryURL)
        let summary = try JSONDecoder().decode(PlaybackImageRequestLifecycleSummary.self, from: summaryData)
        #expect(summary.total.lateResultCount == 1)
    }

    @Test
    func `request sources are tallied separately, foreground and background never merge`() {
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let token = UUID()

        diagnostics.record(
            .requestStarted(
                requestId: "foreground",
                source: .rendererSingleFullsize,
                assetId: "asset-a",
                size: .fullsize,
                mode: .single,
                role: .current,
                cacheKeyHash: "cache-a",
                contextHash: "foreground-context",
                navigationToken: token,
                sceneId: "scene-a",
                timestamp: 1
            ))
        diagnostics.record(
            .requestStarted(
                requestId: "background",
                source: .rendererSingleBackground,
                assetId: "asset-a",
                size: .fullsize,
                mode: .single,
                role: .current,
                cacheKeyHash: "cache-a",
                contextHash: "background-context",
                navigationToken: token,
                sceneId: "scene-a",
                timestamp: 2
            ))

        let summary = diagnostics.makeSummary()

        #expect(summary.total.requestCount == 2)
        #expect(summary.total.uniqueRequestKeyCount == 2)
        #expect(summary.total.duplicateRequestCount == 0)
        #expect(summary.counter(for: .rendererSingleFullsize).requestCount == 1)
        #expect(summary.counter(for: .rendererSingleBackground).requestCount == 1)
    }

    @Test
    func `visible latency derives p50, p95 and max by role and source`() {
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let token = UUID()

        for (index, consumedAt) in [1.10, 1.20, 1.30].enumerated() {
            let requestId = "current-\(index)"
            diagnostics.record(
                .requestStarted(
                    requestId: requestId,
                    source: .rendererSingleFullsize,
                    assetId: "asset-current-\(index)",
                    size: .fullsize,
                    mode: .single,
                    role: .current,
                    cacheKeyHash: "cache-current-\(index)",
                    contextHash: "foreground",
                    navigationToken: token,
                    sceneId: "scene-current-\(index)",
                    timestamp: 1.0
                ))
            diagnostics.record(.consumed(requestId: requestId, timestamp: consumedAt))
        }

        diagnostics.record(
            .requestStarted(
                requestId: "previous",
                source: .rendererSingleFullsize,
                assetId: "asset-previous",
                size: .fullsize,
                mode: .single,
                role: .previous,
                cacheKeyHash: "cache-previous",
                contextHash: "foreground",
                navigationToken: token,
                sceneId: "scene-previous",
                timestamp: 2.0
            ))
        diagnostics.record(.consumed(requestId: "previous", timestamp: 2.50))

        let summary = diagnostics.makeSummary()
        let currentStats = summary.latency.requestToConsumedByRole[PlaybackImageRequestLifecycleRole.current.rawValue]
        let previousStats = summary.latency.requestToConsumedByRole[PlaybackImageRequestLifecycleRole.previous.rawValue]
        let sourceStats = summary.latency.requestToConsumedBySource[
            PlaybackImageRequestLifecycleSource.rendererSingleFullsize.rawValue]

        #expect(currentStats?.count == 3)
        #expect(currentStats?.p50Milliseconds == 200)
        #expect(currentStats?.p95Milliseconds == 300)
        #expect(currentStats?.maxMilliseconds == 300)
        #expect(previousStats?.count == 1)
        #expect(previousStats?.p95Milliseconds == 500)
        #expect(sourceStats?.count == 4)
        #expect(sourceStats?.maxMilliseconds == 500)
    }

    @Test
    func `load latency derives from loadEntered to loadFinished`() {
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let token = UUID()

        diagnostics.record(
            .requestStarted(
                requestId: "manager",
                source: .assetManagerLoadPhoto,
                assetId: "asset-a",
                size: .fullsize,
                mode: .single,
                role: .current,
                cacheKeyHash: "cache-a",
                contextHash: "manager",
                navigationToken: token,
                sceneId: "scene-a",
                timestamp: 1
            ))
        diagnostics.record(.loadEntered(requestId: "manager", timestamp: 2.00))
        diagnostics.record(
            .loadFinished(
                requestId: "manager",
                cacheResult: .disk,
                imagePixelWidth: 1200,
                imagePixelHeight: 800,
                timestamp: 2.25
            ))

        let summary = diagnostics.makeSummary()
        let roleStats = summary.latency.loadEnteredToFinishedByRole[PlaybackImageRequestLifecycleRole.current.rawValue]
        let sourceStats = summary.latency.loadEnteredToFinishedBySource[
            PlaybackImageRequestLifecycleSource.assetManagerLoadPhoto.rawValue]

        #expect(roleStats?.count == 1)
        #expect(roleStats?.p50Milliseconds == 250)
        #expect(roleStats?.p95Milliseconds == 250)
        #expect(sourceStats?.count == 1)
        #expect(sourceStats?.maxMilliseconds == 250)
    }

    @Test
    func `the p95 gate hard stops only when both sides have enough samples and the regression exceeds the threshold`() {
        let evaluation = PlaybackImageRequestLifecycleLatencyGate.evaluate(
            base: latencyStats(count: 20, p95Milliseconds: 100),
            candidate: latencyStats(count: 20, p95Milliseconds: 157)
        )

        #expect(PlaybackImageRequestLifecycleLatencyGate.minimumComparableSampleCount == 20)
        #expect(evaluation.status == .fail)
        #expect(evaluation.triggersHardStop)
        #expect(evaluation.deltaPercent == 57.0)
    }

    @Test
    func `the p95 gate reports an evidence gap and does not hard stop when either side lacks samples`() {
        let evaluation = PlaybackImageRequestLifecycleLatencyGate.evaluate(
            base: latencyStats(count: 2, p95Milliseconds: 93),
            candidate: latencyStats(count: 2, p95Milliseconds: 146)
        )

        #expect(evaluation.status == .insufficientSamples)
        #expect(!evaluation.triggersHardStop)
        #expect(evaluation.deltaPercent == 57.0)
    }

    @Test
    func `the p95 gate passes when both sides have enough samples and the regression stays within the threshold`() {
        let evaluation = PlaybackImageRequestLifecycleLatencyGate.evaluate(
            base: latencyStats(count: 26, p95Milliseconds: 100),
            candidate: latencyStats(count: 24, p95Milliseconds: 109)
        )

        #expect(evaluation.status == .pass)
        #expect(!evaluation.triggersHardStop)
        #expect(evaluation.deltaPercent == 9.0)
    }

    @Test
    func
        `real latency evidence reclassifies incoming rows as pass and current, previous rows as insufficient samples with no failure`()
        throws
    {
        let rows = [
            ("single next60", "loadEnteredToFinishedByRole", "current", 2, 93.0, 2, 146.0),
            ("single next60", "loadEnteredToFinishedByRole", "incoming", 41, 312.0, 27, 213.0),
            ("single next60", "requestToConsumedByRole", "incoming", 26, 14.0, 24, 14.0),
            ("smartfill next60", "loadEnteredToFinishedByRole", "current", 1, 99.0, 3, 83.0),
            ("smartfill next60", "requestToConsumedByRole", "current", 1, 109.0, 1, 62.0),
            ("smartfill next60", "requestToConsumedByRole", "incoming", 236, 144.0, 236, 151.0),
            ("single previous30", "loadEnteredToFinishedByRole", "current", 4, 306.0, 0, 0.0),
            ("single previous30", "requestToConsumedByRole", "incoming", 105, 394.0, 103, 338.0),
            ("smartfill previous30", "requestToConsumedByRole", "current", 2, 97.0, 2, 74.0),
            ("smartfill previous30", "requestToConsumedByRole", "incoming", 236, 9630.0, 221, 9714.0),
            ("all flows", "roleCoverage", "previous", 0, 0.0, 0, 0.0)
        ].map { row in
            (
                flow: row.0,
                metric: row.1,
                role: row.2,
                evaluation: PlaybackImageRequestLifecycleLatencyGate.evaluate(
                    base: latencyStats(count: row.3, p95Milliseconds: row.4),
                    candidate: latencyStats(count: row.5, p95Milliseconds: row.6)
                )
            )
        }

        let comparableIncomingRows = rows.filter { row in
            row.role == PlaybackImageRequestLifecycleRole.incoming.rawValue
                && row.evaluation.status != .insufficientSamples
        }
        #expect(!comparableIncomingRows.isEmpty)
        #expect(comparableIncomingRows.allSatisfy { $0.evaluation.status == .pass })

        let currentPreviousRows = rows.filter { row in
            row.role == PlaybackImageRequestLifecycleRole.current.rawValue
                || row.role == PlaybackImageRequestLifecycleRole.previous.rawValue
        }
        #expect(!currentPreviousRows.isEmpty)
        #expect(currentPreviousRows.allSatisfy { $0.evaluation.status == .insufficientSamples })
        #expect(rows.allSatisfy { !$0.evaluation.triggersHardStop })

        let formerHardStop = try #require(
            rows.first {
                $0.flow == "single next60" && $0.metric == "loadEnteredToFinishedByRole"
                    && $0.role == PlaybackImageRequestLifecycleRole.current.rawValue
            })
        #expect(formerHardStop.evaluation.status == .insufficientSamples)
        #expect(formerHardStop.evaluation.deltaPercent == 57.0)
    }

    @Test
    func `a second request with the same source and key counts as a duplicate candidate`() {
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let token = UUID()

        for index in 1...2 {
            diagnostics.record(
                .requestStarted(
                    requestId: "slot-\(index)",
                    source: .rendererSmartFillSlot,
                    assetId: "asset-slot",
                    size: .fullsize,
                    mode: .smartfill,
                    role: .incoming,
                    cacheKeyHash: "slot-cache",
                    contextHash: "slot-context",
                    navigationToken: token,
                    sceneId: "scene-smartfill",
                    timestamp: TimeInterval(index)
                ))
        }

        let summary = diagnostics.makeSummary()

        #expect(summary.total.requestCount == 2)
        #expect(summary.total.uniqueRequestKeyCount == 1)
        #expect(summary.total.duplicateRequestCount == 1)
        #expect(summary.counter(for: .rendererSmartFillSlot).duplicateRequestCount == 1)
    }

    @Test
    func `SDWebImage's all cache hit is never treated as a decoded memory hit`() {
        #expect(PlaybackImageRequestLifecycleCacheResult(sdImageCacheType: .memory) == .memory)
        #expect(PlaybackImageRequestLifecycleCacheResult(sdImageCacheType: .disk) == .disk)
        #expect(PlaybackImageRequestLifecycleCacheResult(sdImageCacheType: .none) == .miss)
        #expect(PlaybackImageRequestLifecycleCacheResult(sdImageCacheType: .all) == .unknown)
    }

    @Test
    func `cache semantics record memory, disk, miss and unknown and expose a semantic status`() {
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: true)

        diagnostics.record(.cacheChecked(requestId: "memory", result: .memory, timestamp: 1))
        diagnostics.record(.cacheChecked(requestId: "disk", result: .disk, timestamp: 2))
        diagnostics.record(.cacheChecked(requestId: "miss", result: .miss, timestamp: 3))
        diagnostics.record(.cacheChecked(requestId: "unknown", result: .unknown, timestamp: 4))

        let summary = diagnostics.makeSummary()

        #expect(summary.total.memoryHitCount == 1)
        #expect(summary.total.diskHitCount == 1)
        #expect(summary.total.missCount == 1)
        #expect(summary.total.unknownCacheCount == 1)
        #expect(summary.memoryHitSemantics == .verifiedByMemoryCacheQuery)
    }

    @Test
    func `a finished request not consumed by current visible content counts as a wasted candidate`() {
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let token = UUID()

        diagnostics.record(
            .requestStarted(
                requestId: "request",
                source: .assetManagerLoadPhoto,
                assetId: "asset-a",
                size: .fullsize,
                mode: .single,
                role: .incoming,
                cacheKeyHash: "cache-a",
                contextHash: "manager-context",
                navigationToken: token,
                sceneId: "scene-a",
                timestamp: 1
            ))
        diagnostics.record(
            .loadFinished(
                requestId: "request",
                cacheResult: .disk,
                imagePixelWidth: 1600,
                imagePixelHeight: 1200,
                timestamp: 2
            ))

        let summary = diagnostics.makeSummary()

        #expect(summary.total.finishedCount == 1)
        #expect(summary.total.consumedCount == 0)
        #expect(summary.total.wastedDecodeCandidateCount == 1)
    }

    @Test
    func `a completion under a stale navigation token counts as a late result`() {
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let oldToken = UUID()
        let currentToken = UUID()

        diagnostics.record(
            .requestStarted(
                requestId: "old",
                source: .rendererSingleFullsize,
                assetId: "asset-old",
                size: .fullsize,
                mode: .single,
                role: .incoming,
                cacheKeyHash: "cache-old",
                contextHash: "foreground",
                navigationToken: oldToken,
                sceneId: "scene-old",
                timestamp: 1
            ))
        diagnostics.record(
            .loadFinished(
                requestId: "old",
                cacheResult: .disk,
                imagePixelWidth: nil,
                imagePixelHeight: nil,
                timestamp: 2
            ))
        diagnostics.markLateResults(currentNavigationToken: currentToken)

        let summary = diagnostics.makeSummary()

        #expect(summary.total.lateResultCount == 1)
        #expect(summary.counter(for: .rendererSingleFullsize).lateResultCount == 1)
    }

    @Test
    func `the unknown source ratio is computed so the gate can judge whether a fix can proceed`() {
        var diagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let token = UUID()

        diagnostics.record(
            .requestStarted(
                requestId: "known",
                source: .assetManagerLoadPhoto,
                assetId: "asset-a",
                size: .fullsize,
                mode: .single,
                role: .current,
                cacheKeyHash: "known",
                contextHash: "manager",
                navigationToken: token,
                sceneId: "scene-a",
                timestamp: 1
            ))
        diagnostics.record(
            .requestStarted(
                requestId: "unknown",
                source: .unknown,
                assetId: "asset-b",
                size: .fullsize,
                mode: .single,
                role: .unknown,
                cacheKeyHash: "unknown",
                contextHash: "unknown",
                navigationToken: token,
                sceneId: "scene-b",
                timestamp: 2
            ))

        let summary = diagnostics.makeSummary()

        #expect(summary.total.requestCount == 2)
        #expect(summary.counter(for: .unknown).requestCount == 1)
        #expect(summary.unknownSourceRatio == 0.5)
    }

    private func makeEvidenceDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "immichSlides-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func latencyStats(
        count: Int,
        p95Milliseconds: Double
    ) -> PlaybackImageRequestLifecycleLatencyStats {
        PlaybackImageRequestLifecycleLatencyStats(
            count: count,
            p50Milliseconds: p95Milliseconds,
            p95Milliseconds: p95Milliseconds,
            maxMilliseconds: p95Milliseconds
        )
    }
}
#endif
