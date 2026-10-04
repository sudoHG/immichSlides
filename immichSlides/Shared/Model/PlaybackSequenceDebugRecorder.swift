//
//  PlaybackSequenceDebugRecorder.swift
//  immichSlides
//
//  DEBUG playback sequence evidence is only for regression acceptance and takes no part in production playback
//  decisions.
//

import CryptoKit
import Foundation

#if DEBUG
struct PlaybackSequenceDebugRecordInput {
    let sceneId: String
    let displayedAssetId: String
    let primaryAssetId: String?
    let slotAssetIds: [String]
    let assetCount: Int
    let soloOnly: Bool
    let displayMode: String
    let sourceSummary: String
}

struct PlaybackSequenceDebugRecord: Codable, Equatable {
    let schemaVersion: Int
    let sequenceNumber: Int
    let timestamp: TimeInterval
    let uptime: TimeInterval
    let sceneStableId: String
    let displayedAssetStableId: String
    let primaryAssetStableId: String?
    let slotAssetStableIds: [String]
    let duplicateInRecentWindow: Bool
    let recentWindowStableIds: [String]
    let windowDuplicateSummary: String
    let assetCount: Int
    let soloOnly: Bool
    let displayMode: String
    let sourceSummary: String
}

enum PlaybackSequenceDebugEventInput: Equatable {
    case loadMoreDecision(
        assetCount: Int,
        candidateCursorIndex: Int,
        candidateProgressIndexForLoadMore: Int,
        soloOnly: Bool,
        isLoadingMore: Bool,
        shouldTrigger: Bool,
        currentIndex: Int,
        targetIndex: Int,
        displayedAssetCount: Int
    )
    case loadMoreBegin(
        sourceSummary: String,
        oldCount: Int,
        targetCount: Int?,
        excludedCount: Int
    )
    case loadMoreResult(
        sourceSummary: String,
        oldCount: Int,
        targetCount: Int?,
        returnedCount: Int,
        unseenCount: Int,
        dedupedCount: Int,
        finalCount: Int
    )
    case loadMoreSaturated(
        sourceSummary: String,
        oldCount: Int,
        targetCount: Int?,
        returnedCount: Int,
        unseenCount: Int
    )
    case loadMoreFailure(
        sourceSummary: String,
        oldCount: Int,
        targetCount: Int?,
        errorKind: String
    )
    case strictSoloResolveBegin(
        desiredCount: Int,
        excludedCount: Int
    )
    case strictSoloRandomBegin(
        batchNumber: Int,
        fetchSize: Int,
        accumulatedResultCount: Int
    )
    case strictSoloRandomEnd(
        batchNumber: Int,
        randomReturnedCount: Int,
        durationMs: Int
    )
    case strictSoloLocalFilterEnd(
        batchNumber: Int,
        randomReturnedCount: Int,
        afterExclusionCount: Int,
        durationMs: Int
    )
    case strictSoloVisionBegin(
        batchNumber: Int,
        candidateCount: Int,
        acceptedLimit: Int,
        accumulatedResultCount: Int
    )
    case strictSoloVisionEnd(
        batchNumber: Int,
        visionApprovedCount: Int,
        durationMs: Int,
        accumulatedResultCount: Int
    )
    case strictSoloResolveEnd(
        desiredCount: Int,
        returnedCount: Int,
        durationMs: Int
    )
    case strictSoloResolveFailure(
        stageName: String,
        errorKind: String
    )
    case strictSoloBatch(
        batchNumber: Int,
        randomReturnedCount: Int,
        afterExclusionCount: Int,
        visionApprovedCount: Int,
        accumulatedResultCount: Int
    )

    var eventType: String {
        switch self {
        case .loadMoreDecision:
            return "loadMoreDecision"
        case .loadMoreBegin:
            return "loadMoreBegin"
        case .loadMoreResult:
            return "loadMoreResult"
        case .loadMoreSaturated:
            return "loadMoreSaturated"
        case .loadMoreFailure:
            return "loadMoreFailure"
        case .strictSoloResolveBegin:
            return "strictSoloResolveBegin"
        case .strictSoloRandomBegin:
            return "strictSoloRandomBegin"
        case .strictSoloRandomEnd:
            return "strictSoloRandomEnd"
        case .strictSoloLocalFilterEnd:
            return "strictSoloLocalFilterEnd"
        case .strictSoloVisionBegin:
            return "strictSoloVisionBegin"
        case .strictSoloVisionEnd:
            return "strictSoloVisionEnd"
        case .strictSoloResolveEnd:
            return "strictSoloResolveEnd"
        case .strictSoloResolveFailure:
            return "strictSoloResolveFailure"
        case .strictSoloBatch:
            return "strictSoloBatch"
        }
    }

    func record(
        schemaVersion: Int,
        sequenceNumber: Int,
        timestamp: TimeInterval,
        uptime: TimeInterval
    ) -> PlaybackSequenceDebugEventRecord {
        switch self {
        case let .loadMoreDecision(
            assetCount,
            candidateCursorIndex,
            candidateProgressIndexForLoadMore,
            soloOnly,
            isLoadingMore,
            shouldTrigger,
            currentIndex,
            targetIndex,
            displayedAssetCount
        ):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                assetCount: assetCount,
                candidateCursorIndex: candidateCursorIndex,
                candidateProgressIndexForLoadMore: candidateProgressIndexForLoadMore,
                soloOnly: soloOnly,
                isLoadingMore: isLoadingMore,
                shouldTrigger: shouldTrigger,
                currentIndex: currentIndex,
                targetIndex: targetIndex,
                displayedAssetCount: displayedAssetCount
            )

        case let .loadMoreBegin(sourceSummary, oldCount, targetCount, excludedCount):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                sourceSummary: sourceSummary,
                oldCount: oldCount,
                targetCount: targetCount,
                excludedCount: excludedCount
            )

        case let .loadMoreResult(
            sourceSummary, oldCount, targetCount, returnedCount, unseenCount, dedupedCount, finalCount):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                sourceSummary: sourceSummary,
                oldCount: oldCount,
                targetCount: targetCount,
                returnedCount: returnedCount,
                unseenCount: unseenCount,
                dedupedCount: dedupedCount,
                finalCount: finalCount
            )

        case let .loadMoreSaturated(sourceSummary, oldCount, targetCount, returnedCount, unseenCount):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                sourceSummary: sourceSummary,
                oldCount: oldCount,
                targetCount: targetCount,
                returnedCount: returnedCount,
                unseenCount: unseenCount
            )

        case let .loadMoreFailure(sourceSummary, oldCount, targetCount, errorKind):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                sourceSummary: sourceSummary,
                oldCount: oldCount,
                targetCount: targetCount,
                errorKind: errorKind
            )

        case let .strictSoloResolveBegin(desiredCount, excludedCount):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                desiredCount: desiredCount,
                excludedCount: excludedCount
            )

        case let .strictSoloRandomBegin(batchNumber, fetchSize, accumulatedResultCount):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                batchNumber: batchNumber,
                fetchSize: fetchSize,
                accumulatedResultCount: accumulatedResultCount
            )

        case let .strictSoloRandomEnd(batchNumber, randomReturnedCount, durationMs):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                batchNumber: batchNumber,
                randomReturnedCount: randomReturnedCount,
                durationMs: durationMs
            )

        case let .strictSoloLocalFilterEnd(batchNumber, randomReturnedCount, afterExclusionCount, durationMs):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                batchNumber: batchNumber,
                randomReturnedCount: randomReturnedCount,
                afterExclusionCount: afterExclusionCount,
                durationMs: durationMs
            )

        case let .strictSoloVisionBegin(batchNumber, candidateCount, acceptedLimit, accumulatedResultCount):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                batchNumber: batchNumber,
                candidateCount: candidateCount,
                acceptedLimit: acceptedLimit,
                accumulatedResultCount: accumulatedResultCount
            )

        case let .strictSoloVisionEnd(batchNumber, visionApprovedCount, durationMs, accumulatedResultCount):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                batchNumber: batchNumber,
                visionApprovedCount: visionApprovedCount,
                durationMs: durationMs,
                accumulatedResultCount: accumulatedResultCount
            )

        case let .strictSoloResolveEnd(desiredCount, returnedCount, durationMs):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                desiredCount: desiredCount,
                returnedCount: returnedCount,
                durationMs: durationMs
            )

        case let .strictSoloResolveFailure(stageName, errorKind):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                stageName: stageName,
                errorKind: errorKind
            )

        case let .strictSoloBatch(
            batchNumber,
            randomReturnedCount,
            afterExclusionCount,
            visionApprovedCount,
            accumulatedResultCount
        ):
            return PlaybackSequenceDebugEventRecord(
                schemaVersion: schemaVersion,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                uptime: uptime,
                eventType: eventType,
                batchNumber: batchNumber,
                randomReturnedCount: randomReturnedCount,
                afterExclusionCount: afterExclusionCount,
                visionApprovedCount: visionApprovedCount,
                accumulatedResultCount: accumulatedResultCount
            )
        }
    }
}

struct PlaybackSequenceDebugEventRecord: Codable, Equatable {
    let schemaVersion: Int
    let sequenceNumber: Int
    let timestamp: TimeInterval
    let uptime: TimeInterval
    let eventType: String
    let sourceSummary: String?
    let assetCount: Int?
    let candidateCursorIndex: Int?
    let candidateProgressIndexForLoadMore: Int?
    let soloOnly: Bool?
    let isLoadingMore: Bool?
    let shouldTrigger: Bool?
    let currentIndex: Int?
    let targetIndex: Int?
    let displayedAssetCount: Int?
    let oldCount: Int?
    let targetCount: Int?
    let excludedCount: Int?
    let returnedCount: Int?
    let unseenCount: Int?
    let dedupedCount: Int?
    let finalCount: Int?
    let batchNumber: Int?
    let randomReturnedCount: Int?
    let afterExclusionCount: Int?
    let visionApprovedCount: Int?
    let accumulatedResultCount: Int?
    let desiredCount: Int?
    let fetchSize: Int?
    let candidateCount: Int?
    let acceptedLimit: Int?
    let durationMs: Int?
    let stageName: String?
    let errorKind: String?

    init(
        schemaVersion: Int,
        sequenceNumber: Int,
        timestamp: TimeInterval,
        uptime: TimeInterval,
        eventType: String,
        sourceSummary: String? = nil,
        assetCount: Int? = nil,
        candidateCursorIndex: Int? = nil,
        candidateProgressIndexForLoadMore: Int? = nil,
        soloOnly: Bool? = nil,
        isLoadingMore: Bool? = nil,
        shouldTrigger: Bool? = nil,
        currentIndex: Int? = nil,
        targetIndex: Int? = nil,
        displayedAssetCount: Int? = nil,
        oldCount: Int? = nil,
        targetCount: Int? = nil,
        desiredCount: Int? = nil,
        excludedCount: Int? = nil,
        returnedCount: Int? = nil,
        unseenCount: Int? = nil,
        dedupedCount: Int? = nil,
        finalCount: Int? = nil,
        batchNumber: Int? = nil,
        fetchSize: Int? = nil,
        randomReturnedCount: Int? = nil,
        afterExclusionCount: Int? = nil,
        visionApprovedCount: Int? = nil,
        durationMs: Int? = nil,
        candidateCount: Int? = nil,
        acceptedLimit: Int? = nil,
        accumulatedResultCount: Int? = nil,
        stageName: String? = nil,
        errorKind: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.uptime = uptime
        self.eventType = eventType
        self.sourceSummary = sourceSummary
        self.assetCount = assetCount
        self.candidateCursorIndex = candidateCursorIndex
        self.candidateProgressIndexForLoadMore = candidateProgressIndexForLoadMore
        self.soloOnly = soloOnly
        self.isLoadingMore = isLoadingMore
        self.shouldTrigger = shouldTrigger
        self.currentIndex = currentIndex
        self.targetIndex = targetIndex
        self.displayedAssetCount = displayedAssetCount
        self.oldCount = oldCount
        self.targetCount = targetCount
        self.excludedCount = excludedCount
        self.returnedCount = returnedCount
        self.unseenCount = unseenCount
        self.dedupedCount = dedupedCount
        self.finalCount = finalCount
        self.batchNumber = batchNumber
        self.randomReturnedCount = randomReturnedCount
        self.afterExclusionCount = afterExclusionCount
        self.visionApprovedCount = visionApprovedCount
        self.accumulatedResultCount = accumulatedResultCount
        self.desiredCount = desiredCount
        self.fetchSize = fetchSize
        self.candidateCount = candidateCount
        self.acceptedLimit = acceptedLimit
        self.durationMs = durationMs
        self.stageName = stageName
        self.errorKind = errorKind
    }
}

struct PlaybackSequenceDebugRecordResult: Equatable {
    let record: PlaybackSequenceDebugRecord
    let osLogLine: String
    let evidenceRelativePath: String
    let didWriteFile: Bool
    let didCreateEvidenceFile: Bool
}

struct PlaybackSequenceDebugEventResult: Equatable {
    let record: PlaybackSequenceDebugEventRecord
    let osLogLine: String
    let evidenceRelativePath: String
    let didWriteFile: Bool
    let didCreateEvidenceFile: Bool
}

struct PlaybackSequenceDebugRecorder {
    private static let displaySchemaVersion = 1
    private static let eventSchemaVersion = 2
    private static let evidenceDirectoryName = "PlaybackSequenceDebug"
    private static let defaultMaxRecordCount = 2_000
    private static let defaultMaxFileBytes = 2 * 1024 * 1024

    private let isEnabled: Bool
    private let evidenceDirectoryURL: URL
    private let evidenceFileURL: URL
    private let evidenceRelativePath: String
    private let recentWindowLimit: Int
    private let maxRecordCount: Int
    private let maxFileBytes: Int
    private let writesFile: Bool
    private let timestampProvider: () -> TimeInterval
    private let uptimeProvider: () -> TimeInterval
    private var recentWindowStableIds: [String] = []
    private var sequenceNumber: Int = 0
    private(set) var displayedAssetRecordCount = 0
    private var writtenRecordCount: Int = 0
    private var writtenByteCount: Int = 0
    private var evidenceFileCreated = false
    private(set) var hasReachedFileLimit = false

    init(
        isEnabled: Bool,
        evidenceDirectoryURL: URL? = nil,
        launchIdentifier: String = UUID().uuidString,
        recentWindowLimit: Int = 12,
        maxRecordCount: Int = Self.defaultMaxRecordCount,
        maxFileBytes: Int = Self.defaultMaxFileBytes,
        writesFile: Bool = true,
        timestampProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.isEnabled = isEnabled
        let directory = evidenceDirectoryURL ?? Self.defaultEvidenceDirectoryURL()
        self.evidenceDirectoryURL = directory
        let fileName = "qa_playback_sequence-\(Self.sanitizedLaunchIdentifier(launchIdentifier)).jsonl"
        self.evidenceFileURL = directory.appendingPathComponent(fileName)
        self.evidenceRelativePath = "\(Self.evidenceDirectoryName)/\(fileName)"
        self.recentWindowLimit = max(1, recentWindowLimit)
        self.maxRecordCount = max(1, maxRecordCount)
        self.maxFileBytes = max(1, maxFileBytes)
        self.writesFile = writesFile
        self.timestampProvider = timestampProvider
        self.uptimeProvider = uptimeProvider
    }

    mutating func record(_ input: PlaybackSequenceDebugRecordInput) -> PlaybackSequenceDebugRecordResult? {
        guard isEnabled else { return nil }

        sequenceNumber += 1
        let displayedAssetStableId = Self.stableId(for: input.displayedAssetId)
        let windowWithDisplayedAsset = recentWindowStableIds + [displayedAssetStableId]
        let record = PlaybackSequenceDebugRecord(
            schemaVersion: Self.displaySchemaVersion,
            sequenceNumber: sequenceNumber,
            timestamp: timestampProvider(),
            uptime: uptimeProvider(),
            sceneStableId: Self.stableId(for: input.sceneId),
            displayedAssetStableId: displayedAssetStableId,
            primaryAssetStableId: input.primaryAssetId.map(Self.stableId(for:)),
            slotAssetStableIds: input.slotAssetIds.map(Self.stableId(for:)),
            duplicateInRecentWindow: recentWindowStableIds.contains(displayedAssetStableId),
            recentWindowStableIds: recentWindowStableIds,
            windowDuplicateSummary: Self.duplicateSummary(in: windowWithDisplayedAsset),
            assetCount: input.assetCount,
            soloOnly: input.soloOnly,
            displayMode: input.displayMode,
            sourceSummary: input.sourceSummary
        )
        let osLogLine = Self.osLogLine(for: record)
        let writeResult = writeJSONLineIfPossible(record)

        recentWindowStableIds = Array(windowWithDisplayedAsset.suffix(recentWindowLimit))
        displayedAssetRecordCount += 1

        return PlaybackSequenceDebugRecordResult(
            record: record,
            osLogLine: osLogLine,
            evidenceRelativePath: evidenceRelativePath,
            didWriteFile: writeResult.didWrite,
            didCreateEvidenceFile: writeResult.didCreateFile
        )
    }

    mutating func recordEvent(_ input: PlaybackSequenceDebugEventInput) -> PlaybackSequenceDebugEventResult? {
        guard isEnabled else { return nil }

        sequenceNumber += 1
        let record = input.record(
            schemaVersion: Self.eventSchemaVersion,
            sequenceNumber: sequenceNumber,
            timestamp: timestampProvider(),
            uptime: uptimeProvider()
        )
        let osLogLine = Self.osLogLine(for: record)
        let writeResult = writeJSONLineIfPossible(record)

        return PlaybackSequenceDebugEventResult(
            record: record,
            osLogLine: osLogLine,
            evidenceRelativePath: evidenceRelativePath,
            didWriteFile: writeResult.didWrite,
            didCreateEvidenceFile: writeResult.didCreateFile
        )
    }

    nonisolated static func stableId(for rawId: String) -> String {
        let digest = SHA256.hash(data: Data(rawId.utf8))
        let hashText = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "asset_\(hashText)"
    }

    nonisolated static func duplicateSummary(in stableIds: [String]) -> String {
        let duplicateParts = Dictionary(grouping: stableIds, by: { $0 })
            .mapValues(\.count)
            .filter { $0.value > 1 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
        return duplicateParts.isEmpty ? "none" : duplicateParts.joined(separator: ",")
    }

    nonisolated static func osLogLine(for record: PlaybackSequenceDebugRecord) -> String {
        let recentWindow =
            record.recentWindowStableIds.isEmpty ? "empty" : record.recentWindowStableIds.joined(separator: ",")
        return [
            "qa_playback_sequence",
            "assetStableId=\(record.displayedAssetStableId)",
            "sceneStableId=\(record.sceneStableId)",
            "recentWindow=\(recentWindow)",
            "duplicateInWindow=\(record.duplicateInRecentWindow ? "true" : "false")",
            "windowDuplicateSummary=\(record.windowDuplicateSummary)"
        ].joined(separator: " ")
    }

    nonisolated static func osLogLine(for record: PlaybackSequenceDebugEventRecord) -> String {
        var parts = [
            "qa_playback_sequence_event",
            "eventType=\(record.eventType)"
        ]
        if let shouldTrigger = record.shouldTrigger {
            parts.append("shouldTrigger=\(shouldTrigger ? "true" : "false")")
        }
        if let oldCount = record.oldCount {
            parts.append("oldCount=\(oldCount)")
        }
        if let finalCount = record.finalCount {
            parts.append("finalCount=\(finalCount)")
        }
        if let unseenCount = record.unseenCount {
            parts.append("unseenCount=\(unseenCount)")
        }
        if let returnedCount = record.returnedCount {
            parts.append("returnedCount=\(returnedCount)")
        }
        if let batchNumber = record.batchNumber {
            parts.append("batch=\(batchNumber)")
        }
        if let afterExclusionCount = record.afterExclusionCount {
            parts.append("afterExclusion=\(afterExclusionCount)")
        }
        if let errorKind = record.errorKind {
            parts.append("errorKind=\(errorKind)")
        }
        if let stageName = record.stageName {
            parts.append("stage=\(stageName)")
        }
        if let durationMs = record.durationMs {
            parts.append("durationMs=\(durationMs)")
        }
        return parts.joined(separator: " ")
    }

    private mutating func writeJSONLineIfPossible<T: Encodable>(_ record: T) -> (didWrite: Bool, didCreateFile: Bool) {
        guard writesFile else { return (false, false) }
        guard !hasReachedFileLimit else { return (false, false) }
        guard writtenRecordCount < maxRecordCount else {
            hasReachedFileLimit = true
            return (false, false)
        }

        do {
            let data = try Self.encodedJSONLine(for: record)
            guard writtenByteCount + data.count <= maxFileBytes else {
                hasReachedFileLimit = true
                return (false, false)
            }

            try FileManager.default.createDirectory(at: evidenceDirectoryURL, withIntermediateDirectories: true)
            let didCreateFile = !evidenceFileCreated && !FileManager.default.fileExists(atPath: evidenceFileURL.path)
            if !FileManager.default.fileExists(atPath: evidenceFileURL.path) {
                FileManager.default.createFile(atPath: evidenceFileURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: evidenceFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)

            evidenceFileCreated = true
            writtenRecordCount += 1
            writtenByteCount += data.count
            return (true, didCreateFile)
        } catch {
            hasReachedFileLimit = true
            return (false, false)
        }
    }

    private static func encodedJSONLine<T: Encodable>(for record: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    private static func defaultEvidenceDirectoryURL() -> URL {
        let cachesDirectory =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDirectory.appendingPathComponent(evidenceDirectoryName, isDirectory: true)
    }

    private static func sanitizedLaunchIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? UUID().uuidString : sanitized
    }
}
#endif
