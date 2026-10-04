//
//  PlaybackSequenceDebugRecorderTests.swift
//  immichSlidesTests
//
//  DEBUG playback sequence evidence may only record stable hashes, used to verify repeat regressions; it must
//  not leak raw asset identities.
//

import Foundation
import Testing
@testable import immichSlides

#if DEBUG
@Suite
struct PlaybackSequenceDebugRecorderTests {

    @Test
    func `recorder writes stable id JSONL lines and marks recent window duplicates`() throws {
        let evidenceDirectory = try makeTemporaryEvidenceDirectory("stable-jsonl")
        var timestamp = 1_000.0
        var uptime = 20.0
        var recorder = PlaybackSequenceDebugRecorder(
            isEnabled: true,
            evidenceDirectoryURL: evidenceDirectory,
            launchIdentifier: "unit-launch",
            recentWindowLimit: 2,
            maxRecordCount: 10,
            maxFileBytes: 8_192,
            timestampProvider: { timestamp },
            uptimeProvider: { uptime }
        )

        let firstResult = recorder.record(makeInput(assetId: "raw-asset-a", sceneId: "raw-scene-a"))
        let first = try #require(firstResult)
        timestamp += 1
        uptime += 1
        let secondResult = recorder.record(makeInput(assetId: "raw-asset-b", sceneId: "raw-scene-b"))
        _ = try #require(secondResult)
        timestamp += 1
        uptime += 1
        let repeatedResult = recorder.record(makeInput(assetId: "raw-asset-a", sceneId: "raw-scene-c"))
        let repeated = try #require(repeatedResult)

        #expect(first.record.sequenceNumber == 1)
        #expect(repeated.record.sequenceNumber == 3)
        #expect(repeated.record.duplicateInRecentWindow)
        #expect(
            repeated.record.recentWindowStableIds == [
                PlaybackSequenceDebugRecorder.stableId(for: "raw-asset-a"),
                PlaybackSequenceDebugRecorder.stableId(for: "raw-asset-b")
            ])
        #expect(
            repeated.record.windowDuplicateSummary == "\(PlaybackSequenceDebugRecorder.stableId(for: "raw-asset-a")):2")
        #expect(
            repeated.record.slotAssetStableIds == [
                PlaybackSequenceDebugRecorder.stableId(for: "raw-asset-a"),
                PlaybackSequenceDebugRecorder.stableId(for: "raw-secondary-secret")
            ])
        #expect(repeated.osLogLine.hasPrefix("qa_playback_sequence "))
        #expect(repeated.evidenceRelativePath == "PlaybackSequenceDebug/qa_playback_sequence-unit-launch.jsonl")

        let jsonlURL = evidenceDirectory.appending(path: "qa_playback_sequence-unit-launch.jsonl")
        let body = try String(contentsOf: jsonlURL, encoding: .utf8)
        #expect(body.split(separator: "\n").count == 3)
        #expect(body.contains("\"schemaVersion\":1"))
        #expect(body.contains("\"displayedAssetStableId\""))
        #expect(body.contains("raw-asset-a") == false)
        #expect(body.contains("raw-scene-a") == false)
        #expect(body.contains("raw-secondary-secret") == false)
    }

    @Test
    func `recorder stops writing the file after the record limit but keeps returning OSLog records`() throws {
        let evidenceDirectory = try makeTemporaryEvidenceDirectory("record-limit")
        var recorder = PlaybackSequenceDebugRecorder(
            isEnabled: true,
            evidenceDirectoryURL: evidenceDirectory,
            launchIdentifier: "limited-launch",
            recentWindowLimit: 4,
            maxRecordCount: 2,
            maxFileBytes: 8_192,
            timestampProvider: { 10 },
            uptimeProvider: { 2 }
        )

        let firstResult = recorder.record(makeInput(assetId: "raw-asset-a", sceneId: "raw-scene-a"))
        let first = try #require(firstResult)
        let secondResult = recorder.record(makeInput(assetId: "raw-asset-b", sceneId: "raw-scene-b"))
        let second = try #require(secondResult)
        let thirdResult = recorder.record(makeInput(assetId: "raw-asset-c", sceneId: "raw-scene-c"))
        let third = try #require(thirdResult)

        #expect(first.didWriteFile)
        #expect(second.didWriteFile)
        #expect(third.didWriteFile == false)
        #expect(third.record.sequenceNumber == 3)
        #expect(third.osLogLine.contains("assetStableId=asset_"))
        #expect(recorder.hasReachedFileLimit)

        let jsonlURL = evidenceDirectory.appending(path: "qa_playback_sequence-limited-launch.jsonl")
        let body = try String(contentsOf: jsonlURL, encoding: .utf8)
        #expect(body.split(separator: "\n").count == 2)
        #expect(body.contains("raw-asset-c") == false)
    }

    @Test
    func `recorder writes load-more events without raw asset ids`() throws {
        let evidenceDirectory = try makeTemporaryEvidenceDirectory("load-more-events")
        var timestamp = 3_000.0
        var recorder = PlaybackSequenceDebugRecorder(
            isEnabled: true,
            evidenceDirectoryURL: evidenceDirectory,
            launchIdentifier: "events-launch",
            maxRecordCount: 10,
            maxFileBytes: 8_192,
            timestampProvider: {
                defer { timestamp += 1 }
                return timestamp
            },
            uptimeProvider: { 99 }
        )

        let decisionResult = recorder.recordEvent(
            .loadMoreDecision(
                assetCount: 12,
                candidateCursorIndex: 10,
                candidateProgressIndexForLoadMore: 9,
                soloOnly: true,
                isLoadingMore: false,
                shouldTrigger: true,
                currentIndex: 9,
                targetIndex: 10,
                displayedAssetCount: 19
            ))
        let decision = try #require(decisionResult)

        let resultEvent = recorder.recordEvent(
            .loadMoreResult(
                sourceSummary: "filtered(albums=0,people=1,solo=1,normal=0,tags=0,rating=nil,favorite=nil)",
                oldCount: 12,
                targetCount: 24,
                returnedCount: 0,
                unseenCount: 0,
                dedupedCount: 0,
                finalCount: 12
            ))
        let result = try #require(resultEvent)
        let strictBatchEvent = recorder.recordEvent(
            .strictSoloBatch(
                batchNumber: 1,
                randomReturnedCount: 12,
                afterExclusionCount: 0,
                visionApprovedCount: 0,
                accumulatedResultCount: 0
            ))
        let strictBatch = try #require(strictBatchEvent)

        #expect(decision.record.eventType == "loadMoreDecision")
        #expect(decision.record.assetCount == 12)
        #expect(decision.record.shouldTrigger == true)
        #expect(decision.record.displayedAssetCount == 19)
        #expect(result.record.eventType == "loadMoreResult")
        #expect(result.record.oldCount == 12)
        #expect(result.record.finalCount == 12)
        #expect(strictBatch.record.eventType == "strictSoloBatch")
        #expect(strictBatch.record.batchNumber == 1)
        #expect(strictBatch.record.randomReturnedCount == 12)
        #expect(strictBatch.record.afterExclusionCount == 0)
        #expect(decision.osLogLine.contains("qa_playback_sequence_event eventType=loadMoreDecision"))

        let jsonlURL = evidenceDirectory.appending(path: "qa_playback_sequence-events-launch.jsonl")
        let body = try String(contentsOf: jsonlURL, encoding: .utf8)
        #expect(body.split(separator: "\n").count == 3)
        #expect(body.contains("\"eventType\":\"loadMoreDecision\""))
        #expect(body.contains("\"eventType\":\"loadMoreResult\""))
        #expect(body.contains("\"eventType\":\"strictSoloBatch\""))
        #expect(body.contains("raw-asset") == false)
        #expect(body.contains("apiKey") == false)
        #expect(body.contains("serverURL") == false)
    }

    @Test
    func `a disabled recorder does not create an evidence file`() throws {
        let evidenceDirectory = try makeTemporaryEvidenceDirectory("disabled")
        var recorder = PlaybackSequenceDebugRecorder(
            isEnabled: false,
            evidenceDirectoryURL: evidenceDirectory,
            launchIdentifier: "disabled-launch"
        )

        let result = recorder.record(makeInput(assetId: "raw-asset-a", sceneId: "raw-scene-a"))

        #expect(result == nil)
        #expect(FileManager.default.fileExists(atPath: evidenceDirectory.path) == false)
    }

    private func makeInput(assetId: String, sceneId: String) -> PlaybackSequenceDebugRecordInput {
        PlaybackSequenceDebugRecordInput(
            sceneId: sceneId,
            displayedAssetId: assetId,
            primaryAssetId: assetId,
            slotAssetIds: [assetId, "raw-secondary-secret"],
            assetCount: 42,
            soloOnly: true,
            displayMode: "smartFill",
            sourceSummary: "filtered(people=1,solo=1)"
        )
    }

    private func makeTemporaryEvidenceDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "immichSlidesPlaybackSequenceDebugRecorderTests")
            .appending(path: "\(name)-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }
}
#endif
