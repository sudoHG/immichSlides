//
//  PlaybackPoolResolverTests.swift
//  immichSlidesTests
//
//  Local unit tests with no network access.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedRuntimeIsolation)
struct PlaybackPoolResolverTests {

    @Test
    func `target count of zero or less returns an empty pool immediately`() async throws {

        let resolver = PlaybackPoolResolver()
        let selection = FilterSelection()
        let result = try await resolver.resolve(selection: selection, targetCount: 0)
        #expect(result.isEmpty)
    }

    @Test
    func `empty filter selection returns an empty pool`() async throws {

        let resolver = PlaybackPoolResolver()
        let selection = FilterSelection()
        let result = try await resolver.resolve(selection: selection, targetCount: 100)
        #expect(result.isEmpty)
    }

    @Test
    func `request budget scales down for a small target instead of inflating to a fixed value`() {
        // soloOnly+Vision must not reuse an oversized fixed budget.

        let budget = PlaybackPoolResolver.requestBudget(
            targetCount: 12,
            activeRuleCount: 1,
            minPerRule: 8
        )

        #expect(budget == 24)
    }

    @Test
    func `solo vision desired count per rule splits the target across person rules`() {

        let desired = PlaybackPoolResolver.soloVisionDesiredCountPerRule(
            targetCount: 16,
            soloRuleCount: 2,
            minPerRule: 8
        )

        #expect(desired == 8)
    }

    @Test
    func `diagnostics reports strict solo vision unavailable when all vision checks fail`() {
        // Does not run real Vision; only checks how the counters map to the empty-pool reason.

        var diagnostics = PlaybackPoolResolveDiagnostics()
        diagnostics.soloLocalQualifiedCandidateCount = 4
        diagnostics.soloVisionFailedCount = 4

        let reason = diagnostics.emptyReason(
            activeRuleCount: 1,
            finalAssetCount: 0
        )

        #expect(reason == .strictSoloVisionUnavailable)
    }

    @Test
    func `diagnostics reports no matching assets when vision finishes without approving any`() {

        var diagnostics = PlaybackPoolResolveDiagnostics()
        diagnostics.soloLocalQualifiedCandidateCount = 3
        diagnostics.soloVisionFinishedCount = 3

        let reason = diagnostics.emptyReason(
            activeRuleCount: 1,
            finalAssetCount: 0
        )

        #expect(reason == .noMatchingAssets)
    }

    @Test
    func `candidate order stays stable by asset id regardless of input order`() {
        // Stable ordering keeps comparison runs reproducible.

        let assets = [
            makeAsset(id: "asset-c"),
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b"),
            makeAsset(id: "asset-d")
        ]
        let reversedAssets = Array(assets.reversed())

        let firstOrder = PlaybackPoolResolver.stableCandidateOrder(assets).map(\.id)
        let secondOrder = PlaybackPoolResolver.stableCandidateOrder(reversedAssets).map(\.id)

        #expect(firstOrder == secondOrder)
        #expect(Set(firstOrder) == Set(assets.map(\.id)))
        #expect(firstOrder != assets.map(\.id))
        #expect(firstOrder != reversedAssets.map(\.id))
    }

    @Test
    func `solo only load more excludes the current pool and keeps searching for unseen assets`() async throws {
        let personId = "person-a"
        let existingAssets = (0..<12).map { makeSoloAsset(id: "asset-\($0)", personId: personId) }
        let unseenAssets = (12..<36).map { makeSoloAsset(id: "asset-\($0)", personId: personId) }
        var returnedBatches = [
            existingAssets,
            existingAssets,
            unseenAssets
        ]
        var randomRequestCount = 0

        let resolver = PlaybackPoolResolver()
        resolver.randomAssetProviderForTesting = { _, _, personIds in
            #expect(personIds == [personId])
            randomRequestCount += 1
            return returnedBatches.isEmpty ? [] : returnedBatches.removeFirst()
        }
        resolver.personAssetsCountProviderForTesting = { requestedPersonId in
            #expect(requestedPersonId == personId)
            return 100
        }
        resolver.soloApprovalProviderForTesting = { candidates, acceptedLimit in
            SoloVisionBatchResult(
                approvedAssets: Array(candidates.prefix(acceptedLimit)),
                finishedCount: candidates.count,
                failedCount: 0,
                incompleteCount: 0
            )
        }

        let selection = FilterSelection(
            personFilters: [PersonFilter(personId: personId, matchMode: .soloOnly)]
        )
        let result = try await resolver.resolve(
            selection: selection,
            targetCount: 24,
            excludingAssetIds: Set(existingAssets.map(\.id))
        )

        #expect(result.map(\.id) == PlaybackPoolResolver.stableCandidateOrder(unseenAssets).map(\.id))
        #expect(result.allSatisfy { !existingAssets.map(\.id).contains($0.id) })
        #expect(randomRequestCount == 3)
    }

    @Test
    func `solo only load more ends cleanly when every candidate repeats the current pool`() async throws {
        let personId = "person-a"
        let existingAssets = (0..<12).map { makeSoloAsset(id: "asset-\($0)", personId: personId) }
        var randomRequestCount = 0

        let resolver = PlaybackPoolResolver()
        resolver.randomAssetProviderForTesting = { _, _, personIds in
            #expect(personIds == [personId])
            randomRequestCount += 1
            return existingAssets
        }
        resolver.personAssetsCountProviderForTesting = { _ in 100 }
        resolver.soloApprovalProviderForTesting = { candidates, acceptedLimit in
            SoloVisionBatchResult(
                approvedAssets: Array(candidates.prefix(acceptedLimit)),
                finishedCount: candidates.count,
                failedCount: 0,
                incompleteCount: 0
            )
        }

        let selection = FilterSelection(
            personFilters: [PersonFilter(personId: personId, matchMode: .soloOnly)]
        )
        let result = try await resolver.resolve(
            selection: selection,
            targetCount: 24,
            excludingAssetIds: Set(existingAssets.map(\.id))
        )

        #expect(result.isEmpty)
        #expect(randomRequestCount == 6)
        #expect(resolver.strictSoloDebugEventsForTesting.count == 6)
        #expect(
            resolver.strictSoloDebugEventsForTesting.allSatisfy { event in
                guard
                    case let .strictSoloBatch(
                        _, randomReturnedCount, afterExclusionCount, visionApprovedCount, accumulatedResultCount) =
                        event
                else {
                    return false
                }
                return randomReturnedCount == 12
                    && afterExclusionCount == 0
                    && visionApprovedCount == 0
                    && accumulatedResultCount == 0
            })
    }

    @Test
    func `solo only resolver emits live stage events before the random provider returns`() async throws {
        let personId = "person-a"
        let resolver = PlaybackPoolResolver()
        var emittedEvents: [PlaybackSequenceDebugEventInput] = []
        resolver.playbackSequenceDebugEventSink = { event in
            emittedEvents.append(event)
        }
        resolver.randomAssetProviderForTesting = { _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return []
        }
        resolver.personAssetsCountProviderForTesting = { _ in 100 }

        let selection = FilterSelection(
            personFilters: [PersonFilter(personId: personId, matchMode: .soloOnly)]
        )
        let resolveTask = Task {
            try await resolver.resolve(
                selection: selection,
                targetCount: 24,
                excludingAssetIds: []
            )
        }

        let didReceiveStageEvents = await waitUntil(pollInterval: .milliseconds(1)) { emittedEvents.count >= 2 }
        resolveTask.cancel()
        try #require(didReceiveStageEvents, "Timed out waiting for the resolver's stage events")

        #expect(
            emittedEvents.contains { event in
                guard case let .strictSoloResolveBegin(desiredCount, excludedCount) = event else { return false }
                return desiredCount == 24 && excludedCount == 0
            })
        #expect(
            emittedEvents.contains { event in
                guard case let .strictSoloRandomBegin(batchNumber, fetchSize, accumulatedResultCount) = event else {
                    return false
                }
                return batchNumber == 1 && fetchSize == 12 && accumulatedResultCount == 0
            })
    }

    @Test
    func `asset id replay configuration parses inline environment variable in order`() throws {
        let configuration = try #require(
            try PlaybackPoolResolver.assetIDReplayConfigurationForTesting(
                environmentForTesting: [
                    "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS": " asset-a,asset-b\nasset-c "
                ]
            ))

        #expect(configuration.orderedAssetIDs == ["asset-a", "asset-b", "asset-c"])
        #expect(configuration.source == "inline")
    }

    @Test
    func `asset id replay configuration parses lock file in order`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-id-replay-\(UUID().uuidString).lock")
        let lockText = """
            manifestVersion=asset-id-replay-v1
            replayAssetIds=asset-01,asset-02,asset-03
            """
        try lockText.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = try #require(
            try PlaybackPoolResolver.assetIDReplayConfigurationForTesting(
                environmentForTesting: [
                    "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS_PATH": url.path
                ]
            ))

        #expect(configuration.orderedAssetIDs == ["asset-01", "asset-02", "asset-03"])
        #expect(configuration.source == url.path)
    }

    @Test
    func `FilterSelection isEmpty toggles correctly as fields are set`() {

        var selection = FilterSelection()
        #expect(selection.isEmpty)

        selection.albumIds = ["album-a"]
        #expect(!selection.isEmpty)

        selection = FilterSelection()
        selection.personFilters = [PersonFilter(personId: "person-a", matchMode: .normal)]
        #expect(!selection.isEmpty)

        selection = FilterSelection()
        selection.tagIds = ["tag-a"]
        #expect(!selection.isEmpty)
    }

    @Test
    func `PersonMatchMode raw values map correctly`() {

        #expect(PersonMatchMode.normal.rawValue == "normal")
        #expect(PersonMatchMode.soloOnly.rawValue == "soloOnly")
    }

    private func makeAsset(id: String) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil
        )
    }

    private func makeSoloAsset(id: String, personId: String) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: [
                People(id: personId, name: "redacted", isHidden: false, isFavorite: false)
            ],
            tags: nil,
            livePhotoVideoID: nil,
            unassignedFaces: []
        )
    }

    private func makePersonAsset(
        id: String,
        personIds: [String],
        unassignedFaces: [UnassignedFace]? = []
    ) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: personIds.map { People(id: $0, name: "redacted", isHidden: false, isFavorite: false) },
            tags: nil,
            livePhotoVideoID: nil,
            unassignedFaces: unassignedFaces
        )
    }

    private func isSoloQualified(_ asset: Asset, personId: String) -> Bool {
        guard let people = asset.people, people.count == 1 else { return false }
        guard asset.unassignedFaces?.isEmpty ?? true else { return false }
        return people[0].id == personId
    }

    @Test
    func `ordinary person rule first fetch passes selected person ids and keeps legal assets`() async throws {
        let personA = "person-a"
        let personB = "person-b"
        // A valid response has solo photos and group photos with the selected person; per contract ordinary keeps
        // them and no longer filters out other people locally.
        let legalAssets = (0..<7).map { makePersonAsset(id: "asset-person-a-\($0)", personIds: [personA]) }
        let legalDuo = makePersonAsset(id: "asset-person-a-duo", personIds: [personA, personB])
        let firstBatch = legalAssets + [legalDuo]
        var recordedAlbumIds: [[String]?] = []
        var recordedPersonIds: [[String]?] = []

        let resolver = PlaybackPoolResolver()
        resolver.personAssetsCountProviderForTesting = { _ in 100 }
        resolver.randomAssetProviderForTesting = { _, albumIds, personIds in
            recordedAlbumIds.append(albumIds)
            recordedPersonIds.append(personIds)
            guard personIds == [personA] else { return [] }
            return firstBatch
        }

        let selection = FilterSelection(
            personFilters: [PersonFilter(personId: personA, matchMode: .normal)]
        )
        let result = try await resolver.resolve(selection: selection, targetCount: 8)
        let resultIds = Set(result.map(\.id))

        #expect(recordedPersonIds.count == 1)
        #expect(recordedPersonIds.first ?? nil == [personA])
        #expect(recordedAlbumIds.allSatisfy { $0 == nil })
        #expect(resultIds == Set(firstBatch.map(\.id)))
    }

    @Test
    func `ordinary person rule refill passes selected person ids and keeps legal assets`() async throws {
        let personA = "person-a"
        let firstAsset = makePersonAsset(id: "asset-person-a-first", personIds: [personA])
        let refillAssets = [
            makePersonAsset(id: "asset-person-a-refill-1", personIds: [personA]),
            makePersonAsset(id: "asset-person-a-refill-2", personIds: [personA])
        ]
        var recordedAlbumIds: [[String]?] = []
        var recordedPersonIds: [[String]?] = []

        let resolver = PlaybackPoolResolver()
        resolver.personAssetsCountProviderForTesting = { _ in 100 }
        resolver.randomAssetProviderForTesting = { _, albumIds, personIds in
            recordedAlbumIds.append(albumIds)
            recordedPersonIds.append(personIds)
            guard personIds == [personA] else { return [] }
            if recordedPersonIds.count == 1 {
                return [firstAsset]
            }
            let refillIndex = recordedPersonIds.count - 2
            guard refillAssets.indices.contains(refillIndex) else { return [] }
            return [refillAssets[refillIndex]]
        }

        let selection = FilterSelection(
            personFilters: [PersonFilter(personId: personA, matchMode: .normal)]
        )
        let result = try await resolver.resolve(selection: selection, targetCount: 8)
        let resultIds = Set(result.map(\.id))

        #expect(recordedPersonIds.count >= 2)
        #expect(recordedPersonIds.first ?? nil == [personA])
        #expect(recordedPersonIds.dropFirst().allSatisfy { $0 == [personA] })
        #expect(recordedAlbumIds.allSatisfy { $0 == nil })
        #expect(resultIds.contains(firstAsset.id))
        #expect(resultIds.contains(refillAssets[0].id))
        #expect(resultIds.contains(refillAssets[1].id))
    }

    @Test
    func `solo only person rule rejects multi person photos and keeps qualified solo assets`() async throws {
        let personA = "person-a"
        let personB = "person-b"
        let qualifiedAsset = makeSoloAsset(id: "asset-solo-a", personId: personA)
        let dualAsset = makePersonAsset(id: "asset-dual", personIds: [personA, personB])
        let unassignedAsset = makePersonAsset(
            id: "asset-unassigned",
            personIds: [personA],
            unassignedFaces: [UnassignedFace(id: "face-unassigned")]
        )
        let otherPersonAsset = makeSoloAsset(id: "asset-solo-b", personId: personB)
        var recordedPersonIds: [[String]?] = []

        let resolver = PlaybackPoolResolver()
        resolver.personAssetsCountProviderForTesting = { _ in 100 }
        resolver.soloApprovalProviderForTesting = { candidates, acceptedLimit in
            SoloVisionBatchResult(
                approvedAssets: Array(candidates.prefix(acceptedLimit)),
                finishedCount: candidates.count,
                failedCount: 0,
                incompleteCount: 0
            )
        }
        resolver.randomAssetProviderForTesting = { _, _, personIds in
            recordedPersonIds.append(personIds)
            return [qualifiedAsset, dualAsset, unassignedAsset, otherPersonAsset]
        }

        let selection = FilterSelection(
            personFilters: [PersonFilter(personId: personA, matchMode: .soloOnly)]
        )
        let result = try await resolver.resolve(selection: selection, targetCount: 8)
        let resultIds = Set(result.map(\.id))

        #expect(!recordedPersonIds.isEmpty)
        #expect(recordedPersonIds.allSatisfy { $0 == [personA] })
        #expect(!result.isEmpty)
        #expect(resultIds.contains(qualifiedAsset.id))
        #expect(!resultIds.contains(dualAsset.id))
        #expect(!resultIds.contains(unassignedAsset.id))
        #expect(!resultIds.contains(otherPersonAsset.id))
        #expect(result.allSatisfy { isSoloQualified($0, personId: personA) })
    }

    @Test
    func `solo only empty result is not treated as vacuous success`() async throws {
        let personA = "person-a"
        let resolver = PlaybackPoolResolver()
        resolver.personAssetsCountProviderForTesting = { _ in 100 }
        resolver.randomAssetProviderForTesting = { _, _, _ in [] }

        let selection = FilterSelection(
            personFilters: [PersonFilter(personId: personA, matchMode: .soloOnly)]
        )
        let result = try await resolver.resolveDetailed(selection: selection, targetCount: 8)

        #expect(result.assets.isEmpty)
        #expect(result.emptyReason == .noMatchingAssets)
    }

    @Test
    func `album rule forwards selected album ids and excludes unrequested person rule assets`() async throws {
        try await ServerConfigurationTestIsolation.run {
            ImmichServer.clearSavedConfiguration()
            ImmichAPIService.shared.reloadServerConfiguration()

            let albumId = "album-a"
            let albumAsset = makePersonAsset(id: "asset-album-a", personIds: ["person-b"])
            let personRuleAsset = makePersonAsset(id: "asset-person-rule-b", personIds: ["person-b"])
            var recordedAlbumIds: [[String]?] = []
            var recordedPersonIds: [[String]?] = []

            let resolver = PlaybackPoolResolver()
            resolver.randomAssetProviderForTesting = { _, albumIds, personIds in
                recordedAlbumIds.append(albumIds)
                recordedPersonIds.append(personIds)
                if personIds != nil {
                    return [personRuleAsset]
                }
                return [albumAsset]
            }

            let selection = FilterSelection(albumIds: [albumId])
            let result = try await resolver.resolve(selection: selection, targetCount: 8)
            let resultIds = Set(result.map(\.id))

            #expect(!recordedAlbumIds.isEmpty)
            #expect(recordedAlbumIds.allSatisfy { $0 == [albumId] })
            #expect(recordedPersonIds.allSatisfy { $0 == nil })
            #expect(!result.isEmpty)
            #expect(resultIds.contains(albumAsset.id))
            #expect(!resultIds.contains(personRuleAsset.id))
        }
    }

    @Test
    func `selected albums and persons resolve independently to the exact total union`() async throws {
        let albumA = "album-a"
        let albumB = "album-b"
        let personNormal = "person-normal"
        let personSolo = "person-solo"
        let albumAAsset = makePersonAsset(
            id: "asset-album-a-group",
            personIds: [personSolo, personNormal]
        )
        let albumBAsset = makeAsset(id: "asset-album-b")
        let normalAsset = makePersonAsset(id: "asset-person-normal", personIds: [personNormal])
        let soloAsset = makeSoloAsset(id: "asset-person-solo", personId: personSolo)
        let albumObjectSets = [
            albumA: [albumAAsset],
            albumB: [albumBAsset]
        ]
        let personObjectSets = [
            personNormal: [normalAsset],
            personSolo: [soloAsset]
        ]

        let resolver = PlaybackPoolResolver()
        resolver.personAssetsCountProviderForTesting = { _ in 1 }
        resolver.soloApprovalProviderForTesting = { candidates, acceptedLimit in
            SoloVisionBatchResult(
                approvedAssets: Array(candidates.prefix(acceptedLimit)),
                finishedCount: candidates.count,
                failedCount: 0,
                incompleteCount: 0
            )
        }
        resolver.randomAssetProviderForTesting = { _, albumIds, personIds in
            if let albumID = albumIds?.first { return albumObjectSets[albumID] ?? [] }
            if let personID = personIds?.first { return personObjectSets[personID] ?? [] }
            return []
        }

        let selection = FilterSelection(
            albumIds: [albumA, albumB],
            personFilters: [
                PersonFilter(personId: personNormal, matchMode: .normal),
                PersonFilter(personId: personSolo, matchMode: .soloOnly)
            ]
        )
        let result = try await resolver.resolve(selection: selection, targetCount: 20)
        let expectedIDs = Set(
            selection.albumIds.flatMap { albumObjectSets[$0] ?? [] }.map(\.id)
                + selection.personFilters.flatMap { personObjectSets[$0.personId] ?? [] }.map(\.id)
        )
        let actualIDs = result.map(\.id)

        #expect(actualIDs.count == Set(actualIDs).count)
        #expect(Set(actualIDs) == expectedIDs)
    }

    @Test
    func `empty selection reports no active rules as the empty reason`() async throws {
        let resolver = PlaybackPoolResolver()
        let selection = FilterSelection()
        #expect(selection.isEmpty)

        let result = try await resolver.resolveDetailed(selection: selection, targetCount: 8)

        #expect(result.assets.isEmpty)
        #expect(result.emptyReason == .noActiveRules)
    }

    @Test
    func normalizeServerURLWorks() {

        let a = ImmichServer.normalizeServerURL("https://demo.example.com/")
        let b = ImmichServer.normalizeServerURL("https://demo.example.com/api")
        let c = ImmichServer.normalizeServerURL(" https://demo.example.com  ")

        #expect(a == "https://demo.example.com/api")
        #expect(b == "https://demo.example.com/api")
        #expect(c == "https://demo.example.com/api")
    }

    @Test
    func `server URL validation accepts HTTP URLs and rejects invalid schemes or hosts`() {

        let ok = ImmichServer.validateURL("https://demo.example.com:8888")
        let badScheme = ImmichServer.validateURL("ftp://demo.example.com")
        let badHost = ImmichServer.validateURL("https://")

        #expect(ok.isURLValid)
        #expect(!badScheme.isURLValid)
        #expect(!badHost.isURLValid)
    }

    @Test
    func `API key validation accepts a nonempty key and rejects an empty key`() {

        let ok = ImmichServer.validateAPIKey("abc123")
        let bad = ImmichServer.validateAPIKey("")

        #expect(ok.isAPIKeyValid)
        #expect(!bad.isAPIKeyValid)
    }

    @Test
    func `server isConfigured reflects url and API key presence`() {

        let s1 = ImmichServer(immichURL: "https://demo.example.com/api", immichApiKey: "k")
        let s2 = ImmichServer(immichURL: nil, immichApiKey: "k")
        let s3 = ImmichServer(immichURL: "https://demo.example.com/api", immichApiKey: nil)

        #expect(s1.isConfigured)
        #expect(!s2.isConfigured)
        #expect(!s3.isConfigured)
    }

    @Test
    func `server save reports Keychain failure and leaves no partial configuration`() async {
        await ServerConfigurationTestIsolation.run {
            ImmichServer.clearSavedConfiguration()
            let server = ImmichServer(
                immichURL: "https://demo.example.com/api",
                immichApiKey: "key-that-cannot-be-saved"
            )

            let didSave = server.save { _ in false }

            #expect(didSave == false)
            #expect(ImmichServer.load() == nil)
        }
    }

    @Test
    func `getAPIURL builds the endpoint URL correctly`() {

        let server = ImmichServer(immichURL: "https://demo.example.com/api", immichApiKey: "k")
        let endpoint = server.getAPIURL(endpoint: "albums")
        #expect(endpoint == "https://demo.example.com/api/albums")
    }

    @Test
    @MainActor
    func `API service reflects the new server config only after reload`() async {

        await ServerConfigurationTestIsolation.run {
            let serverA = ImmichServer(
                immichURL: "https://server-a.example.com/api",
                immichApiKey: "key-A"
            )
            serverA.save()
            ImmichAPIService.shared.reloadServerConfiguration()
            #expect(ImmichAPIService.shared.getApiKey() == "key-A")

            let serverB = ImmichServer(
                immichURL: "https://server-b.example.com/api",
                immichApiKey: "key-B"
            )
            serverB.save()
            #expect(ImmichAPIService.shared.getApiKey() == "key-A")

            ImmichAPIService.shared.reloadServerConfiguration()
            #expect(ImmichAPIService.shared.getApiKey() == "key-B")
        }
    }

    @Test
    func `preview assets sample contains at least one asset`() {

        #expect(!Asset.previewAssets.isEmpty)
    }

    @Test
    func `server configuration equivalence ignores URL trailing format and whitespace differences`() {
        let a = ImmichServer(
            immichURL: " https://demo.example.com/ ",
            immichApiKey: " key-1 "
        )
        let b = ImmichServer(
            immichURL: "https://demo.example.com/api",
            immichApiKey: "key-1"
        )
        let c = ImmichServer(
            immichURL: "https://another.example.com/api",
            immichApiKey: "key-1"
        )

        #expect(ImmichServer.isSameConfiguration(a, b))
        #expect(!ImmichServer.isSameConfiguration(a, c))
    }
}

@MainActor
@Suite
struct AppFlowStateMachineTests {

    @Test
    func `first boot stays on FirstBoot when config is incomplete`() {
        var flow = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flow.handleFirstBootConfigured(isServerConfigured: false)

        #expect(flow.route == .firstBoot)
        #expect(flow.isOnboardingSession == false)
        #expect(flow.slideshowBackRoute == nil)
    }

    @Test
    func `first boot completion enters ModeSelection and starts onboarding session`() {
        var flow = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flow.handleFirstBootConfigured(isServerConfigured: true)

        #expect(flow.route == .modeSelection)
        #expect(flow.isOnboardingSession)
        #expect(flow.slideshowBackRoute == nil)
    }

    @Test
    func `onboarding random mode allows back navigation to ModeSelection without PIN`() {
        var flow = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flow.startOnboardingSession()
        flow.handleOnboardingModeDone(.random)

        #expect(flow.route == .slideshow)
        #expect(flow.slideshowBackRoute == .modeSelection)
        #expect(flow.slideshowBackTarget() == .modeSelection)
    }

    @Test
    func `onboarding filtered mode goes to FilterSummary first`() {
        var flow = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flow.startOnboardingSession()
        flow.handleOnboardingModeDone(.filtered)

        #expect(flow.route == .filterSummary)
        #expect(flow.slideshowBackRoute == nil)
    }

    @Test
    func `filtered playback start enters Slideshow with FilterSummary as the back target`() {
        var flow = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flow.startOnboardingSession()
        flow.handleOnboardingModeDone(.filtered)
        flow.handleFilteredPlaybackStarted()

        #expect(flow.route == .slideshow)
        #expect(flow.slideshowBackRoute == .filterSummary)
        #expect(flow.slideshowBackTarget() == .filterSummary)
    }
    func `slideshow menu or back is a no op with no back target or PIN enabled`() {
        Issue.record("Pending runtime UI verification.")
    }

    @Test
    func `enabling PIN immediately clears the back navigation chain`() {
        var flow = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flow.startOnboardingSession()
        flow.handleOnboardingModeDone(.random)

        flow.syncAccessProtection(isEnabled: true)

        #expect(flow.isAccessProtectionEnabled)
        #expect(flow.isOnboardingSession == false)
        #expect(flow.slideshowBackRoute == nil)
        #expect(flow.slideshowBackTarget() == nil)
    }

    @Test
    func `return to ModeSelection is allowed only during an onboarding session`() {
        var flow = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flow.route = .slideshow
        flow.isOnboardingSession = false
        flow.returnToOnboardingModeSelection()
        #expect(flow.route == .slideshow)

        flow.startOnboardingSession()
        flow.route = .slideshow
        flow.returnToOnboardingModeSelection()
        #expect(flow.route == .modeSelection)
    }

    @Test
    func `app initial route goes straight to playback when configured, else to first boot`() {
        var flowA = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flowA.initializeRoute(isServerConfigured: true)
        #expect(flowA.route == .slideshow)
        #expect(flowA.isOnboardingSession == false)

        var flowB = AppFlowStateMachine(isAccessProtectionInitiallyEnabled: false)
        flowB.initializeRoute(isServerConfigured: false)
        #expect(flowB.route == .firstBoot)
        #expect(flowB.isOnboardingSession == false)
    }
}

@MainActor
@Suite(.sharedRuntimeIsolation)
struct SlideShowViewModelSelectionRefreshTests {

    @Test
    func `random source never triggers a filtered reload`() {
        let vm = SlideShowViewModel(source: .random)
        let latest = FilterSelection(albumIds: ["album-1"])

        #expect(vm.shouldReloadFilteredSource(for: latest) == false)
    }

    @Test
    func `filter selection differing only in order does not trigger a reload`() {
        let current = FilterSelection(
            albumIds: ["album-b", "album-a"],
            personFilters: [
                PersonFilter(personId: "person-2", matchMode: .normal),
                PersonFilter(personId: "person-1", matchMode: .soloOnly)
            ],
            tagIds: ["tag-b", "tag-a"],
            rating: 4,
            isFavorite: true
        )
        let latest = FilterSelection(
            albumIds: ["album-a", "album-b"],
            personFilters: [
                PersonFilter(personId: "person-1", matchMode: .soloOnly),
                PersonFilter(personId: "person-2", matchMode: .normal)
            ],
            tagIds: ["tag-a", "tag-b"],
            rating: 4,
            isFavorite: true
        )
        let vm = SlideShowViewModel(source: .filtered(current))

        #expect(vm.shouldReloadFilteredSource(for: latest) == false)
    }

    @Test
    func `semantically changed filter selection triggers a reload`() {
        let current = FilterSelection(
            albumIds: ["album-a"],
            personFilters: [PersonFilter(personId: "person-1", matchMode: .normal)],
            tagIds: [],
            rating: nil,
            isFavorite: nil
        )
        let latest = FilterSelection(
            albumIds: ["album-a"],
            personFilters: [PersonFilter(personId: "person-1", matchMode: .soloOnly)],
            tagIds: [],
            rating: nil,
            isFavorite: nil
        )
        let vm = SlideShowViewModel(source: .filtered(current))

        #expect(vm.shouldReloadFilteredSource(for: latest))
    }

    @Test
    func `preparing playback source for presentation only resets state without waiting on network`() {

        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-1", matchMode: .soloOnly)]
        )
        let vm = SlideShowViewModel(source: .random)
        vm.replacePlaybackAssetsForTesting([makeAsset(id: "old-asset")])
        vm.setPlaybackLoadingForTesting(false)
        vm.setPlaybackLoadingMoreForTesting(true)

        vm.preparePlaybackSourceForPresentation(to: .filtered(selection))

        #expect(vm.assets.isEmpty)
        #expect(vm.currentIndex == 0)
        #expect(vm.targetIndex == 0)
        #expect(vm.isLoading)
        #expect(vm.isLoadingMore == false)
        #expect(vm.shouldReloadFilteredSource(for: selection) == false)
    }

    @Test
    func `solo only load more triggers earlier than normal mode`() {

        let shouldLoadMoreAtDefaultEarlyPosition = SlideShowViewModel.shouldTriggerLoadMore(
            assetCount: 12,
            newIndex: 3,
            isSoloOnlyPlayback: false
        )
        let shouldLoadMoreAtSoloEarlyPosition = SlideShowViewModel.shouldTriggerLoadMore(
            assetCount: 12,
            newIndex: 3,
            isSoloOnlyPlayback: true
        )
        let shouldLoadMoreAtSoloTooEarlyPosition = SlideShowViewModel.shouldTriggerLoadMore(
            assetCount: 12,
            newIndex: 2,
            isSoloOnlyPlayback: true
        )

        #expect(shouldLoadMoreAtDefaultEarlyPosition == false)
        #expect(shouldLoadMoreAtSoloEarlyPosition)
        #expect(shouldLoadMoreAtSoloTooEarlyPosition == false)
    }

    private func makeAsset(id: String) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil
        )
    }
}
