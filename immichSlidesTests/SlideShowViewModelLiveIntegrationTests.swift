//
//  SlideShowViewModelLiveIntegrationTests.swift
//  immichSlidesTests
//
//  Live server integration tests: skipped without IMMICH_TEST_* or env.xcconfig; a skip is not a pass.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedRuntimeIsolation)
struct SlideShowViewModelLiveIntegrationTests {

    private nonisolated static let liveConfiguration = TestServerConfiguration.current
    private nonisolated static let liveEnabled = liveConfiguration != nil
    private nonisolated static let personWindowEvidencePath = resolvePersonWindowEvidencePath(
        environment: ProcessInfo.processInfo.environment,
        temporaryDirectory: FileManager.default.temporaryDirectory
    )
    private nonisolated static let requiredAdvanceCount = 21
    private nonisolated static let recentStableIdWindowSize = 20

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

    @Test(.enabled(if: liveEnabled))
    @MainActor
    func `random mode loadAssets finishes loading and returns assets`() async {

        await runWithIsolatedLiveServer {
            let vm = SlideShowViewModel(source: .random)
            await vm.loadAssets()

            #expect(vm.isLoading == false)
            #expect(vm.assets.count > 0)
            #expect(vm.currentIndex == 0)
            #expect(vm.targetIndex == 0)
        }
    }

    @Test(.enabled(if: liveEnabled))
    @MainActor
    func `filtered mode loadAssets finishes loading and returns assets`() async throws {

        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let albums = try await api.getAllAlbums(size: 5)
            let albumId = try #require(albums.first?.id)

            let selection = FilterSelection(
                albumIds: [albumId], personFilters: [], tagIds: [], rating: nil, isFavorite: nil)
            let vm = SlideShowViewModel(source: .filtered(selection))

            await vm.loadAssets()

            #expect(vm.isLoading == false)
            #expect(vm.assets.count > 0)
            #expect(vm.currentIndex == 0)
            #expect(vm.targetIndex == 0)
        }
    }

    @Test(.enabled(if: liveEnabled))
    @MainActor
    func `random mode prepareInitialAssets finishes preloading the first frame`() async {

        await runWithIsolatedLiveServer {
            let vm = SlideShowViewModel(source: .random)
            await vm.prepareInitialAssets()

            #expect(vm.assets.count > 0)
            #expect(vm.didFirstPreload)
        }
    }

    @Test(.enabled(if: liveEnabled))
    @MainActor
    func `live qa_playback_sequence evidence is sanitized`() async throws {
        try await runWithIsolatedLiveServer {
            let evidencePath =
                ProcessInfo.processInfo.environment["IMMICHSLIDES_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH"]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_IMMICHSLIDES_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH"]
            let vm = SlideShowViewModel(source: .random)
            var capturedLines: [String] = []
            vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
            vm.qaPlaybackSequenceOSLogEmitterForTesting = { capturedLines.append($0) }

            await vm.prepareInitialAssets()
            try reportInitialSceneVisibleForQA(vm)

            let firstRawAssetId = try #require(vm.assets.first?.id)
            let firstLine = try #require(capturedLines.first)
            #expect(firstLine.hasPrefix("qa_playback_sequence "))
            #expect(firstLine.contains("assetStableId=asset_"))
            #expect(firstLine.contains("sceneStableId=asset_"))
            #expect(firstLine.contains("duplicateInWindow="))
            #expect(firstLine.contains("windowDuplicateSummary="))
            #expect(firstLine.contains(firstRawAssetId) == false)
            #expect(firstLine.contains(Self.liveConfiguration?.serverURL ?? "unused-live-url") == false)
            #expect(firstLine.contains(Self.liveConfiguration?.apiKey ?? "unused-live-key") == false)

            if let evidencePath, evidencePath.isEmpty == false {
                let body = """
                    # live qa_playback_sequence sanitized evidence

                    status=PASS
                    lineCount=\(capturedLines.count)
                    rawAssetIdPresent=false
                    serverURLPresent=false
                    apiKeyPresent=false

                    ## lines
                    \(capturedLines.joined(separator: "\n"))

                    """
                try body.write(toFile: evidencePath, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Like history, QA displayed evidence may only be committed by a real visible tick of the full scene-root.
    private func reportInitialSceneVisibleForQA(_ vm: SlideShowViewModel) throws {
        let loadingSnapshot = vm.sceneRenderSnapshot
        let targetLayer = try #require(
            loadingSnapshot.layers.last(where: { $0.role == .incoming || $0.role == .stable })
        )
        let scene = try #require(vm.scene(for: targetLayer))
        for slot in scene.photoSlots {
            vm.rendererDecoded(
                SceneRendererIdentity(
                    generation: targetLayer.identity.generation,
                    attemptID: vm.scenePresentationRendererAttemptID(for: targetLayer),
                    sceneID: targetLayer.identity.sceneID,
                    slotID: slot.id,
                    assetID: slot.asset.id
                )
            )
        }

        var readySnapshot = vm.sceneRenderSnapshot
        if readySnapshot.phase == .transition,
            readySnapshot.layers.last(where: { $0.identity == targetLayer.identity })?.isPresentationReady == false,
            let transitionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        {
            vm.scenePresentationTimestampProviderForTesting = { transitionDeadline }
            readySnapshot = vm.sceneRenderSnapshot
        }
        let visibleLayer = try #require(
            readySnapshot.layers.last(where: {
                $0.identity == targetLayer.identity
                    && ($0.role == .incoming || $0.role == .stable) && $0.isPresentationReady
            })
        )
        if visibleLayer.role == .incoming {
            let visibleTime = (visibleLayer.fadeStartTime ?? ProcessInfo.processInfo.systemUptime) + 0.5
            vm.scenePresentationTimestampProviderForTesting = { visibleTime }
        }
        let displayedLayer = try #require(
            vm.sceneRenderSnapshot.layers.last(where: { $0.identity == visibleLayer.identity })
        )
        // Paused startup settles directly to stable; both roles still need the scene-root visibility boundary.
        let candidate = SceneVisibleFrameCandidate(
            layerIdentity: ScenePresentationLayerIdentity(
                generation: displayedLayer.identity.generation,
                sceneID: displayedLayer.identity.sceneID,
                layerID: "scene-root"
            ),
            role: displayedLayer.role,
            opacity: displayedLayer.opacity,
            isBarrierComplete: vm.isScenePresentationBarrierComplete(for: displayedLayer),
            isSceneRoot: true
        )
        var reporter = SceneVisibleFrameReporter()
        let didCompleteTransaction = reporter.transactionCompleted(candidate: candidate)
        try #require(didCompleteTransaction)
        let reportedIdentity = reporter.consumeDisplayTick(currentCandidate: candidate)
        let visibleIdentity = try #require(reportedIdentity)
        vm.incomingBecameVisible(visibleIdentity)
        if visibleLayer.role == .incoming,
            let completionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        {
            vm.scenePresentationTimestampProviderForTesting = { completionDeadline }
        }
    }

    @Test
    func `window dedup selects the smallest personId among unique-named eligible people, not people.first`() {
        let firstPerson = Self.makeWindowDedupPerson(id: "p-z", name: "Zed")
        let people = [
            firstPerson,
            Self.makeWindowDedupPerson(id: "p-a", name: "Ann"),
            Self.makeWindowDedupPerson(id: "p-b", name: "Bob"),
            Self.makeWindowDedupPerson(id: "p-c", name: "Cal"),
            Self.makeWindowDedupPerson(id: "p-d", name: "   "),
            Self.makeWindowDedupPerson(id: "p-x", name: "Dup"),
            Self.makeWindowDedupPerson(id: "p-y", name: "Dup")
        ]
        let selected = Self.selectDeterministicWindowDedupPerson(
            from: people,
            minimumAssetCount: Self.recentStableIdWindowSize,
            assetCountByPersonId: [
                "p-z": 100,
                "p-a": 25,
                "p-b": 5,
                "p-c": 80,
                "p-d": 50,
                "p-x": 90,
                "p-y": 90
            ]
        )

        #expect(selected?.personId == "p-a")
        #expect(selected?.assetCount == 25)
        #expect(selected?.uniqueNamedCount == 4)
        #expect(selected?.eligibleCount == 3)
        #expect(selected?.personId != firstPerson.id)
    }

    @Test
    func `window dedup selection returns nil when no person is both uniquely named and has enough assets`() {
        let people = [
            Self.makeWindowDedupPerson(id: "p-a", name: "Ann"),
            Self.makeWindowDedupPerson(id: "p-b", name: "Ann")
        ]
        let selected = Self.selectDeterministicWindowDedupPerson(
            from: people,
            minimumAssetCount: Self.recentStableIdWindowSize,
            assetCountByPersonId: [
                "p-a": 100,
                "p-b": 100
            ]
        )
        #expect(selected == nil)
    }

    @Test
    func
        `person-filter window qa_playback_sequence evidence path uses explicit path, historical env, or a temp fallback`()
    {
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/immichSlides-tests", isDirectory: true)

        #expect(
            Self.resolvePersonWindowEvidencePath(
                environment: [:],
                temporaryDirectory: temporaryDirectory
            ) == "/tmp/immichSlides-tests/immichSlidesEvidence/qa_playback_sequence_person_window.txt")

        #expect(
            Self.resolvePersonWindowEvidencePath(
                environment: [
                    "IMMICHSLIDES_PERSON_WINDOW_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH": "/tmp/custom-person-window.txt"
                ],
                temporaryDirectory: temporaryDirectory
            ) == "/tmp/custom-person-window.txt")

        #expect(
            Self.resolvePersonWindowEvidencePath(
                environment: ["IMMICHSLIDES_AUGUSTO_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH": "/tmp/historical-augusto.txt"],
                temporaryDirectory: temporaryDirectory
            ) == "/tmp/historical-augusto.txt")

        #expect(
            Self.resolvePersonWindowEvidencePath(
                environment: [
                    "IMMICHSLIDES_PERSON_WINDOW_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH": "",
                    "TEST_RUNNER_IMMICHSLIDES_AUGUSTO_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH": "/tmp/runner-historical.txt"
                ],
                temporaryDirectory: temporaryDirectory
            ) == "/tmp/runner-historical.txt")
    }

    @Test(
        .enabled(if: liveEnabled, "No local live config; a skip does not mean live dedup was verified")
    )
    @MainActor
    func `live person filter qa_playback_sequence recent 20 entries have no duplicates`() async throws {
        let configuration = try #require(Self.liveConfiguration)

        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let people = try await api.getAllPeople(size: 1000)
            let assetCountByPersonId = try await Self.assetCountsByPersonId(
                for: people,
                api: api
            )
            let selected = Self.selectDeterministicWindowDedupPerson(
                from: people,
                minimumAssetCount: Self.recentStableIdWindowSize,
                assetCountByPersonId: assetCountByPersonId
            )
            guard let selected else {
                try writePersonWindowPlaybackSequenceEvidence(
                    status: "BLOCKED_DATA",
                    skipped: true,
                    reason:
                        "no unique-named person with statistics.assets>=\(Self.recentStableIdWindowSize); uniqueNamed=\(assetCountByPersonId.count)",
                    capturedLines: [],
                    latestStableIds: [],
                    committedAdvanceCount: 0,
                    initialAssetCount: 0,
                    selection: nil
                )
                try Test.cancel(
                    "BLOCKED_DATA: no unique-named person with statistics.assets>=\(Self.recentStableIdWindowSize)"
                )
            }

            let selection = FilterSelection(
                albumIds: [],
                personFilters: [PersonFilter(personId: selected.personId, matchMode: .normal)],
                tagIds: [],
                rating: nil,
                isFavorite: nil
            )
            let vm = SlideShowViewModel(source: .filtered(selection))
            var capturedLines: [String] = []
            vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
            vm.qaPlaybackSequenceOSLogEmitterForTesting = { capturedLines.append($0) }
            vm.initialPhotoLoadHookForTesting = { _ in }
            vm.backgroundPreloadHookForTesting = { _, _, _ in }
            vm.indexChangePhotoLoadHookForTesting = { _, _ in }

            await vm.prepareInitialAssets()

            guard vm.assets.count >= Self.recentStableIdWindowSize else {
                try writePersonWindowPlaybackSequenceEvidence(
                    status: "BLOCKED_DATA",
                    skipped: true,
                    reason:
                        "deterministic person filter returned \(vm.assets.count) assets; need at least \(Self.recentStableIdWindowSize) for latest-20 uniqueness evidence",
                    capturedLines: capturedLines,
                    latestStableIds: stableAssetIds(from: capturedLines.suffix(Self.recentStableIdWindowSize)),
                    committedAdvanceCount: max(0, capturedLines.count - 1),
                    initialAssetCount: vm.assets.count,
                    rawAssetIds: vm.assets.map(\.id),
                    configuration: configuration,
                    selection: selected
                )
                try Test.cancel(
                    "BLOCKED_DATA: deterministic person filter returned \(vm.assets.count) assets; need at least \(Self.recentStableIdWindowSize)"
                )
            }

            let loaded = try await independentlyLoadedAssets(from: vm.assets, api: api)
            for asset in loaded {
                #expect(
                    asset.people?.contains { $0.id == selected.personId } == true,
                    "independently fetched asset people does not contain the selected personId"
                )
            }

            // QA lines are committed only on a real visible scene-root tick; same seam as this file's sanitized test.
            try reportInitialSceneVisibleForQA(vm)

            _ = try #require(
                capturedLines.first,
                "filtered prepareInitialAssets completed but qa_playback_sequence produced no initial line"
            )

            var committedAdvanceCount = 0
            for _ in 0..<Self.requiredAdvanceCount {
                let previousStableCount = stableAssetIds(from: capturedLines).count
                vm.requestNextScene()
                await vm.handleTransitionChange(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
                try reportInitialSceneVisibleForQA(vm)

                let nextStableCount = stableAssetIds(from: capturedLines).count
                if nextStableCount > previousStableCount {
                    committedAdvanceCount += nextStableCount - previousStableCount
                }
            }

            // The latest 20 stable IDs; event lines such as loadMore are not counted in the window.
            let latestStableIds = Array(
                stableAssetIds(from: capturedLines).suffix(Self.recentStableIdWindowSize)
            )
            let latestStableIdSet = Set(latestStableIds)
            let hasEnoughAdvances = committedAdvanceCount >= Self.requiredAdvanceCount
            let hasLatestWindow = latestStableIds.count == Self.recentStableIdWindowSize
            let hasNoLatestDuplicates = latestStableIdSet.count == latestStableIds.count

            guard hasEnoughAdvances && hasLatestWindow else {
                try writePersonWindowPlaybackSequenceEvidence(
                    status: "BLOCKED_DATA",
                    skipped: true,
                    reason:
                        "committedAdvanceCount=\(committedAdvanceCount), latestStableIds=\(latestStableIds.count); need \(Self.requiredAdvanceCount) advances and \(Self.recentStableIdWindowSize) stable ids",
                    capturedLines: capturedLines,
                    latestStableIds: latestStableIds,
                    committedAdvanceCount: committedAdvanceCount,
                    initialAssetCount: vm.assets.count,
                    rawAssetIds: vm.assets.map(\.id),
                    configuration: configuration,
                    selection: selected
                )
                try Test.cancel(
                    "BLOCKED_DATA: committedAdvanceCount=\(committedAdvanceCount), latestStableIds=\(latestStableIds.count); insufficient window for uniqueness"
                )
            }

            try writePersonWindowPlaybackSequenceEvidence(
                status: hasNoLatestDuplicates ? "PASS" : "FAIL",
                skipped: false,
                reason: hasNoLatestDuplicates
                    ? nil
                    : "committedAdvanceCount=\(committedAdvanceCount), latestStableIds=\(latestStableIds.count), uniqueLatestStableIds=\(latestStableIdSet.count)",
                capturedLines: capturedLines,
                latestStableIds: latestStableIds,
                committedAdvanceCount: committedAdvanceCount,
                initialAssetCount: vm.assets.count,
                rawAssetIds: vm.assets.map(\.id),
                configuration: configuration,
                selection: selected
            )

            #expect(hasNoLatestDuplicates)
        }
    }

    @Test(.enabled(if: liveEnabled))
    @MainActor
    func `calling firstPreload repeatedly is idempotent`() async {
        await runWithIsolatedLiveServer {
            let vm = SlideShowViewModel(source: .random)
            await vm.firstPreload()
            let firstCount = vm.assets.count
            let firstFlag = vm.didFirstPreload

            await vm.firstPreload()

            #expect(firstFlag)
            #expect(vm.didFirstPreload)
            #expect(vm.assets.count >= firstCount)
        }
    }

    @Test(.enabled(if: liveEnabled))
    @MainActor
    func `loadMoreAssets never shrinks the asset count`() async {
        await runWithIsolatedLiveServer {
            let vm = SlideShowViewModel(source: .random)
            await vm.loadAssets()
            let before = vm.assets.count

            await vm.loadMoreAssets()
            let after = vm.assets.count

            #expect(after >= before)
        }
    }

    private struct WindowDedupPersonSelection: Equatable {
        let personId: String
        let displayName: String
        let assetCount: Int
        let uniqueNamedCount: Int
        let eligibleCount: Int
    }

    private nonisolated static func makeWindowDedupPerson(id: String, name: String) -> People {
        People(id: id, name: name, isHidden: false, isFavorite: false)
    }

    // Deterministic person pick: unique non-empty name + enough assets + smallest personId. Does not rely on
    // server ordering or hard-code a display name.
    private static func selectDeterministicWindowDedupPerson(
        from people: [People],
        minimumAssetCount: Int,
        assetCountByPersonId: [String: Int]
    ) -> WindowDedupPersonSelection? {
        var nameCounts: [String: Int] = [:]
        for person in people {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { continue }
            nameCounts[name, default: 0] += 1
        }

        var uniqueNamedCount = 0
        var eligible: [(People, Int)] = []
        for person in people {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false, nameCounts[name] == 1 else { continue }
            uniqueNamedCount += 1
            guard let assetCount = assetCountByPersonId[person.id], assetCount >= minimumAssetCount else {
                continue
            }
            eligible.append((person, assetCount))
        }

        guard let chosen = eligible.min(by: { $0.0.id < $1.0.id }) else {
            return nil
        }
        return WindowDedupPersonSelection(
            personId: chosen.0.id,
            displayName: chosen.0.name.trimmingCharacters(in: .whitespacesAndNewlines),
            assetCount: chosen.1,
            uniqueNamedCount: uniqueNamedCount,
            eligibleCount: eligible.count
        )
    }

    private static func assetCountsByPersonId(
        for people: [People],
        api: ImmichAPIService
    ) async throws -> [String: Int] {
        var nameCounts: [String: Int] = [:]
        for person in people {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { continue }
            nameCounts[name, default: 0] += 1
        }

        var counts: [String: Int] = [:]
        for person in people {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false, nameCounts[name] == 1 else { continue }
            counts[person.id] = try await api.getPersonAssetsCount(id: person.id)
        }
        return counts
    }

    private func independentlyLoadedAssets(
        from assets: [Asset],
        api: ImmichAPIService
    ) async throws -> [Asset] {
        let ids = assets.map(\.id)
        let loaded = try await api.getAssets(ids: ids)
        #expect(loaded.map(\.id) == ids)
        return loaded
    }

    private func stableAssetIds<S: Sequence>(from lines: S) -> [String] where S.Element == String {
        lines.compactMap { line in
            line.split(separator: " ")
                .first { $0.hasPrefix("assetStableId=") }
                .map { String($0.dropFirst("assetStableId=".count)) }
        }
    }

    private func writePersonWindowPlaybackSequenceEvidence(
        status: String,
        skipped: Bool,
        reason: String?,
        capturedLines: [String],
        latestStableIds: [String],
        committedAdvanceCount: Int,
        initialAssetCount: Int,
        rawAssetIds: [String] = [],
        configuration: TestServerConfiguration? = nil,
        selection: WindowDedupPersonSelection?
    ) throws {
        let evidenceDirectory = URL(fileURLWithPath: Self.personWindowEvidencePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        let selectionRule =
            "uniqueNonEmptyName AND statistics.assets>=\(Self.recentStableIdWindowSize) AND min(personId)"
        let body = """
            # person-filter window qa_playback_sequence live evidence

            status=\(status)
            skipped=\(skipped ? "true" : "false")
            reason=\(reason ?? "none")
            selectionRule=\(selectionRule)
            selectedDisplayName=\(selection?.displayName ?? "none")
            selectedAssetCount=\(selection.map { String($0.assetCount) } ?? "none")
            uniqueNamedCount=\(selection.map { String($0.uniqueNamedCount) } ?? "none")
            eligibleCount=\(selection.map { String($0.eligibleCount) } ?? "none")
            playbackSource=filtered
            personMatchMode=normal
            requiredCommittedAdvanceCount=\(Self.requiredAdvanceCount)
            committedAdvanceCount=\(committedAdvanceCount)
            initialAssetCount=\(initialAssetCount)
            lineCount=\(capturedLines.count)
            latestStableIdWindowSize=\(Self.recentStableIdWindowSize)
            latestStableIdCount=\(latestStableIds.count)
            latestStableIdUniqueCount=\(Set(latestStableIds).count)
            latestStableIds=\(latestStableIds.joined(separator: ","))
            rawAssetIdPresent=false
            serverURLPresent=false
            apiKeyPresent=false

            ## qa_playback_sequence lines
            \(capturedLines.joined(separator: "\n"))

            """

        let rawAssetIdPresent =
            rawAssetIds
            .filter { $0.count >= 8 }
            .contains { body.contains($0) }
        let serverURLPresent = [
            configuration?.serverURL, configuration.map { ImmichServer.normalizeServerURL($0.serverURL) }
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .contains { body.contains($0) }
        let selectedPersonIdPresent: Bool
        if let personId = selection?.personId, personId.count >= 8 {
            selectedPersonIdPresent = body.contains(personId)
        } else {
            selectedPersonIdPresent = false
        }
        let apiKeyPresent: Bool
        if let apiKey = configuration?.apiKey, apiKey.count >= 8 {
            apiKeyPresent = body.contains(apiKey)
        } else {
            apiKeyPresent = false
        }

        if rawAssetIdPresent || serverURLPresent || apiKeyPresent || selectedPersonIdPresent {
            let privacyFailureBody = """
                # person-filter window qa_playback_sequence live evidence

                status=FAIL_PRIVACY_CHECK
                skipped=false
                reason=evidence body would include private values; sanitized lines were not written
                rawAssetIdPresent=\(rawAssetIdPresent)
                serverURLPresent=\(serverURLPresent)
                apiKeyPresent=\(apiKeyPresent)
                selectedPersonIdPresent=\(selectedPersonIdPresent)

                """
            try privacyFailureBody.write(toFile: Self.personWindowEvidencePath, atomically: true, encoding: .utf8)
            #expect(rawAssetIdPresent == false)
            #expect(serverURLPresent == false)
            #expect(apiKeyPresent == false)
            #expect(selectedPersonIdPresent == false)
            return
        }

        try body.write(toFile: Self.personWindowEvidencePath, atomically: true, encoding: .utf8)
    }

    private nonisolated static func resolvePersonWindowEvidencePath(
        environment: [String: String],
        temporaryDirectory: URL
    ) -> String {
        if let explicitPath = firstNonEmptyEnvironmentValue([
            environment["IMMICHSLIDES_PERSON_WINDOW_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH"],
            environment["TEST_RUNNER_IMMICHSLIDES_PERSON_WINDOW_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH"],
            environment["IMMICHSLIDES_AUGUSTO_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH"],
            environment["TEST_RUNNER_IMMICHSLIDES_AUGUSTO_QA_PLAYBACK_SEQUENCE_EVIDENCE_PATH"]
        ]) {
            return explicitPath
        }

        // By default live evidence goes to a temp directory writable by the test process, not tied to a macOS user.
        return
            temporaryDirectory
            .appendingPathComponent("immichSlidesEvidence", isDirectory: true)
            .appendingPathComponent("qa_playback_sequence_person_window.txt")
            .path
    }

    private nonisolated static func firstNonEmptyEnvironmentValue(_ values: [String?]) -> String? {
        values
            .compactMap { $0 }
            .first { $0.isEmpty == false }
    }
}
