//
//  PlaybackPoolResolverLiveIntegrationTests.swift
//  immichSlidesTests
//
//  Live server integration tests: skipped without a test server config. Configured live solo
//  tests can execute the real Vision approval path.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedRuntimeIsolation)
struct PlaybackPoolResolverLiveIntegrationTests {

    private nonisolated static let liveConfiguration = TestServerConfiguration.current
    private nonisolated static let liveEnabled = liveConfiguration != nil

    private func configureLiveServer() {
        guard let configuration = Self.liveConfiguration else { return }
        let server = ImmichServer(
            immichURL: ImmichServer.normalizeServerURL(configuration.serverURL),
            immichApiKey: configuration.apiKey
        )
        server.save()
        ImmichAPIService.shared.reloadServerConfiguration()
    }

    private func runWithIsolatedLiveServer<T>(_ body: @escaping () async throws -> T) async rethrows -> T {
        try await ServerConfigurationTestIsolation.run {
            configureLiveServer()
            return try await body()
        }
    }

    private func overlapCount(_ a: [Asset], _ b: [Asset]) -> Int {
        let sa = Set(a.map { $0.id })
        let sb = Set(b.map { $0.id })
        return sa.intersection(sb).count
    }

    private func containsSelectedPerson(_ asset: Asset, personId: String) -> Bool {
        asset.people?.contains { $0.id == personId } == true
    }

    private func isSoloQualified(_ asset: Asset, personId: String) -> Bool {
        guard let people = asset.people else { return false }
        guard people.count == 1 else { return false }
        guard asset.unassignedFaces?.isEmpty ?? true else { return false }
        return people[0].id == personId
    }

    // Asset has no albumId, so membership is checked with read-only albums?assetId= against an independent getAsset.
    private func albumIDsContaining(assetID: String) async throws -> Set<String> {
        let server = try #require(ImmichServer.load())
        let encodedID = assetID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? assetID
        guard let urlString = server.getAPIURL(endpoint: "albums?assetId=\(encodedID)"),
            let url = URL(string: urlString),
            let headerKey = server.immichApiKey,
            headerKey.isEmpty == false
        else {
            throw ImmichError.serverNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        ImmichHTTPHeaders.applyAPIKey(headerKey, to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            throw ImmichError.unknownError(
                NSError(
                    domain: "PlaybackPoolResolverLiveIntegrationTests",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "album membership probe HTTP \(statusCode)"]
                )
            )
        }

        return Set(try ImmichAPIService.decodeAlbumList(from: data).map(\.id))
    }

    private func independentlyLoadedAssets(
        from result: [Asset],
        api: ImmichAPIService
    ) async throws -> [Asset] {
        let ids = result.map(\.id)
        let loaded = try await api.getAssets(ids: ids)
        #expect(loaded.map(\.id) == ids)
        return loaded
    }

    // Read-only evidence for an empty solo pool: find which stage emptied it (random fetch / metadata pre-filter /
    // download and decode / Vision).
    private func diagnoseEmptySoloPool(
        resolver: PlaybackPoolResolver,
        api: ImmichAPIService,
        personId: String,
        emptyReason: PlaybackPoolEmptyReason?
    ) async -> String {
        var fetched = 0
        var localQualified = 0
        var visionApproved = 0
        var batchCount = 0
        for event in resolver.strictSoloDebugEventsForTesting {
            guard
                case let .strictSoloBatch(
                    _,
                    randomReturnedCount,
                    afterExclusionCount,
                    visionApprovedCount,
                    _
                ) = event
            else {
                continue
            }
            fetched += randomReturnedCount
            localQualified += afterExclusionCount
            visionApproved += visionApprovedCount
            batchCount += 1
        }

        var probeFinished = -1
        var probeFailed = -1
        var probeIncomplete = -1
        var probeApproved = -1
        var stage = "unknown"

        if fetched == 0 {
            stage = "random_fetch_empty"
        } else if localQualified == 0 {
            stage = "local_metadata_filter"
        } else if visionApproved > 0 {
            stage = "official_vision_approved_but_final_empty"
        } else {
            do {
                let probeCandidates = try await api.getRandomAsset(
                    size: 12,
                    albumIds: nil,
                    personIds: [personId]
                )
                let locallyQualified = probeCandidates.filter { isSoloQualified($0, personId: personId) }
                let probe = await SoloVisionPoolFilter.shared.approvalResult(
                    from: Array(locallyQualified.prefix(8)),
                    apiService: api,
                    acceptedLimit: 8
                )
                probeFinished = probe.finishedCount
                probeFailed = probe.failedCount
                probeIncomplete = probe.incompleteCount
                probeApproved = probe.approvedAssets.count

                if probeIncomplete > 0 && probeFinished == 0 && probeFailed == 0 {
                    stage = "vision_preview_download_or_decode_incomplete"
                } else if probeFailed > 0 && probeFinished == 0 {
                    stage = "vision_execution_failed"
                } else if probeFinished > 0 && probeApproved == 0 {
                    stage = "vision_finished_rejected_not_exactly_one_face"
                } else if probeApproved > 0 {
                    stage = "probe_vision_approved_official_still_empty"
                } else if emptyReason == .strictSoloVisionUnavailable {
                    stage = "official_strictSoloVisionUnavailable"
                } else {
                    stage = "official_vision_or_qualification_empty"
                }
            } catch {
                stage = "vision_probe_request_failed"
            }
        }

        return [
            "emptyReason=\(emptyReason?.rawValue ?? "none")",
            "stage=\(stage)",
            "fetched=\(fetched)",
            "localQualified=\(localQualified)",
            "visionApproved=\(visionApproved)",
            "batchCount=\(batchCount)",
            "probeFinished=\(probeFinished)",
            "probeFailed=\(probeFailed)",
            "probeIncomplete=\(probeIncomplete)",
            "probeApproved=\(probeApproved)"
        ].joined(separator: "; ")
    }

    @Test(
        .enabled(if: liveEnabled, "No local live config; a skip does not mean live membership was verified")
    )
    func `single album rule independently verifies every asset belongs to the selected album with no duplicates`()
        async throws
    {
        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let resolver = PlaybackPoolResolver(apiService: api)

            let albums = try await api.getAllAlbums(size: 10)
            let albumId = try #require(albums.first?.id)

            let selection = FilterSelection(
                albumIds: [albumId], personFilters: [], tagIds: [], rating: nil, isFavorite: nil)
            let result = try await resolver.resolve(selection: selection, targetCount: 100)

            #expect(result.count <= 100)
            #expect(Set(result.map { $0.id }).count == result.count)
            guard result.isEmpty == false else {
                try Test.cancel("BLOCKED_DATA: album rule returned 0 assets; empty pool is not membership evidence")
            }

            let loaded = try await independentlyLoadedAssets(from: result, api: api)
            for asset in loaded {
                let containingAlbumIDs = try await albumIDsContaining(assetID: asset.id)
                #expect(
                    containingAlbumIDs.contains(albumId),
                    "independently fetched asset is not a member of the selected album"
                )
            }
        }
    }

    @Test(
        .enabled(if: liveEnabled, "No local live config; a skip does not mean live membership was verified")
    )
    func
        `normal person rule independently verifies every asset's people include the selected person with no duplicates`()
        async throws
    {
        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let resolver = PlaybackPoolResolver(apiService: api)

            let people = try await api.getAllPeople(size: 10)
            let personId = try #require(people.first?.id)

            let selection = FilterSelection(
                albumIds: [],
                personFilters: [PersonFilter(personId: personId, matchMode: .normal)],
                tagIds: [],
                rating: nil,
                isFavorite: nil
            )

            let result = try await resolver.resolve(selection: selection, targetCount: 100)
            #expect(result.count <= 100)
            #expect(Set(result.map { $0.id }).count == result.count)
            guard result.isEmpty == false else {
                try Test.cancel(
                    "BLOCKED_DATA: ordinary person rule returned 0 assets; empty pool is not membership evidence")
            }

            let loaded = try await independentlyLoadedAssets(from: result, api: api)
            for asset in loaded {
                #expect(
                    containsSelectedPerson(asset, personId: personId),
                    "independently fetched asset people does not contain the selected person"
                )
            }
        }
    }

    @Test(
        .enabled(if: liveEnabled, "No local live config; a skip does not mean live membership was verified")
    )
    func `solo rule returns only qualified assets when non-empty, and an empty result never counts as passing`()
        async throws
    {
        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let resolver = PlaybackPoolResolver(apiService: api)

            let people = try await api.getAllPeople(size: 10)
            let personId = try #require(people.first?.id)

            let selection = FilterSelection(
                albumIds: [],
                personFilters: [PersonFilter(personId: personId, matchMode: .soloOnly)],
                tagIds: [],
                rating: nil,
                isFavorite: nil
            )

            let detailed = try await resolver.resolveDetailed(selection: selection, targetCount: 100)
            let result = detailed.assets
            #expect(result.count <= 100)
            #expect(Set(result.map { $0.id }).count == result.count)
            guard result.isEmpty == false else {
                let diagnosis = await diagnoseEmptySoloPool(
                    resolver: resolver,
                    api: api,
                    personId: personId,
                    emptyReason: detailed.emptyReason
                )
                try Test.cancel(
                    "BLOCKED_DATA: soloOnly rule returned 0 assets; empty pool is not qualification evidence; \(diagnosis)"
                )
            }

            let loaded = try await independentlyLoadedAssets(from: result, api: api)
            for asset in loaded {
                #expect(isSoloQualified(asset, personId: personId))
            }
        }
    }

    @Test(
        .enabled(if: liveEnabled, "No local live config; a skip does not mean live membership was verified")
    )
    func `when the same person is filtered as both normal and soloOnly, a non-empty result must qualify by soloOnly`()
        async throws
    {
        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let resolver = PlaybackPoolResolver(apiService: api)

            let people = try await api.getAllPeople(size: 10)
            let personId = try #require(people.first?.id)

            let selection = FilterSelection(
                albumIds: [],
                personFilters: [
                    PersonFilter(personId: personId, matchMode: .normal),
                    PersonFilter(personId: personId, matchMode: .soloOnly)
                ],
                tagIds: [],
                rating: nil,
                isFavorite: nil
            )

            let detailed = try await resolver.resolveDetailed(selection: selection, targetCount: 100)
            let result = detailed.assets
            guard result.isEmpty == false else {
                let diagnosis = await diagnoseEmptySoloPool(
                    resolver: resolver,
                    api: api,
                    personId: personId,
                    emptyReason: detailed.emptyReason
                )
                try Test.cancel(
                    "BLOCKED_DATA: normal+soloOnly rule returned 0 assets; empty pool is not qualification evidence; \(diagnosis)"
                )
            }

            let loaded = try await independentlyLoadedAssets(from: result, api: api)
            for asset in loaded {
                #expect(isSoloQualified(asset, personId: personId))
            }
        }
    }

    @Test(
        .enabled(if: liveEnabled, "No local live config; a skip does not mean live membership was verified")
    )
    func `album and person union rule requires every asset in the album or with the person, with no duplicates`()
        async throws
    {
        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let resolver = PlaybackPoolResolver(apiService: api)

            let albums = try await api.getAllAlbums(size: 10)
            let people = try await api.getAllPeople(size: 10)
            let albumId = try #require(albums.first?.id)
            let personId = try #require(people.first?.id)

            let selection = FilterSelection(
                albumIds: [albumId],
                personFilters: [PersonFilter(personId: personId, matchMode: .normal)],
                tagIds: [],
                rating: nil,
                isFavorite: nil
            )

            let result = try await resolver.resolve(selection: selection, targetCount: 100)
            #expect(result.count <= 100)
            #expect(Set(result.map { $0.id }).count == result.count)
            guard result.isEmpty == false else {
                try Test.cancel("BLOCKED_DATA: union rule returned 0 assets; empty pool is not membership evidence")
            }

            let loaded = try await independentlyLoadedAssets(from: result, api: api)
            for asset in loaded {
                let inSelectedAlbum = try await albumIDsContaining(assetID: asset.id).contains(albumId)
                let inSelectedPerson = containsSelectedPerson(asset, personId: personId)
                #expect(
                    inSelectedAlbum || inSelectedPerson,
                    "independently fetched asset belongs to neither selected album nor selected person"
                )
            }
        }
    }

    @Test(
        .enabled(if: liveEnabled, "No local live config; a skip does not mean live membership was verified")
    )
    func `the cooling pool blocks on too few samples and reduces overlap once the pool is large enough`() async throws {
        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let resolver = PlaybackPoolResolver(apiService: api)

            let people = try await api.getAllPeople(size: 10)
            let personId = try #require(people.first?.id)
            let selection = FilterSelection(
                albumIds: [],
                personFilters: [PersonFilter(personId: personId, matchMode: .normal)],
                tagIds: [],
                rating: nil,
                isFavorite: nil
            )

            let first = try await resolver.resolve(selection: selection, targetCount: 100)
            let second = try await resolver.resolve(selection: selection, targetCount: 100)

            let overlap = overlapCount(first, second)
            let minCount = min(first.count, second.count)
            guard minCount >= 20 else {
                try Test.cancel(
                    "BLOCKED_DATA: cooling sample too small (minCount=\(minCount)); insufficient overlap evidence")
            }

            let loadedFirst = try await independentlyLoadedAssets(from: first, api: api)
            let loadedSecond = try await independentlyLoadedAssets(from: second, api: api)
            #expect(loadedFirst.allSatisfy { containsSelectedPerson($0, personId: personId) })
            #expect(loadedSecond.allSatisfy { containsSelectedPerson($0, personId: personId) })
            #expect(overlap < minCount)
        }
    }
}
