//
//  SlideShowViewModelVisibleSceneIdentityTests.swift
//  immichSlidesTests
//
//  After switching to the next photo, a late load of the previous one must not write the old asset back
//  into the visible scene. The old hook cases only record the hook-bypass path; they do not count as
//  coverage of the real loadPhoto.
//

import CryptoKit
import Foundation
import SDWebImage
import Testing
import UIKit
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedPlaybackRuntimeIsolation)
struct SlideShowViewModelVisibleSceneIdentityTests {

    @Test
    func `a late load completing for the previous asset after switching to B does not revert identity to A`()
        async throws
    {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }

        let urlA = URL(fileURLWithPath: "/tmp/immichslides-visible-scene-asset-a.jpg")
        let urlB = URL(fileURLWithPath: "/tmp/immichslides-visible-scene-asset-b.jpg")
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ]
        vm.loadAssetsHookForTesting = { _ in assets }
        setCachedURL(urlB, assetId: "asset-b", size: .fullsize, in: vm.downloadManager)

        var finishStaleLoadForA: CheckedContinuation<Void, Never>?
        // Once released, a late hook call must not park: nothing would resume it.
        var isStaleLoadReleased = false
        vm.initialPhotoLoadHookForTesting = { assetId in
            if assetId == "asset-a", finishStaleLoadForA == nil, !isStaleLoadReleased {
                await withCheckedContinuation { pending in
                    finishStaleLoadForA = pending
                }
            }
            setCachedURL(urlA, assetId: "asset-a", size: .fullsize, in: vm.downloadManager)
            vm.downloadManager.assetStates["asset-a"] = .readyToPlay
            vm.downloadManager.assetPreviewStates["asset-a"] = .readyToPlay
        }
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            let url = assetId == "asset-a" ? urlA : urlB
            setCachedURL(url, assetId: assetId, size: size, in: vm.downloadManager)
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        #if DEBUG
        _ = vm.downloadManager.seedRunningPhotoLoadForTesting(
            assetId: "asset-a",
            size: .fullsize,
            priority: .high
        )
        defer {
            vm.downloadManager.clearSeededRunningPhotoLoadForTesting(
                assetId: "asset-a",
                size: .fullsize
            )
        }
        #endif

        let firstPreloadTask = Task {
            await vm.firstPreload()
        }
        // On assertion failure, release the hold first so firstPreload does not hang on the continuation.
        defer {
            isStaleLoadReleased = true
            finishStaleLoadForA?.resume()
            finishStaleLoadForA = nil
            firstPreloadTask.cancel()
        }
        // Shared 30 s deadline; this file's 1 s default loses to main-actor stalls from parallel suites.
        let didHoldStaleA = await waitUntil(pollInterval: .milliseconds(2)) {
            finishStaleLoadForA != nil && vm.safeCurrentScene?.primaryAssetId == "asset-a"
        }
        try #require(didHoldStaleA)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a")

        vm.requestNextScene()
        completeCurrentScenePresentation(vm)

        let visibleSceneAfterNext = vm.safeCurrentScene
        #expect(visibleSceneAfterNext?.primaryAssetId == "asset-b")
        let sceneIdentityAfterNext = visibleSceneAfterNext?.id
        #expect(sceneIdentityAfterNext != nil)

        isStaleLoadReleased = true
        if let pending = finishStaleLoadForA {
            finishStaleLoadForA = nil
            pending.resume()
        }
        await firstPreloadTask.value

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-b")
        #expect(vm.safeCurrentScene?.id == sceneIdentityAfterNext)
        #expect(vm.downloadManager.findURL(assetId: "asset-b", size: .fullsize) != urlA)
        #expect(vm.downloadManager.findURL(assetId: "asset-a", size: .fullsize) == urlA)
    }

    @Test
    func `a request from the real loadPhoto path is intercepted by the local fixture, not a hook bypass`() async throws
    {
        try await runRealPathProbe { fixture, assetId in
            await AssetsDownloadManager.shared.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
            #expect(fixture.enteredCount(assetId: assetId) > 0)
            #expect(fixture.completedCount(assetId: assetId) > 0)
            #expect(AssetsDownloadManager.shared.isReady(assetId: assetId, size: .fullsize))
        }
    }

    @Test
    func `stub save success does not mean the singleton read the key before reload sends the test key only`()
        async throws
    {
        try await ServerConfigurationTestIsolation.run {
            let fixture = LateLoadLocalHTTPFixture()
            defer {
                fixture.releaseAll()
                fixture.stop()
            }
            try await fixture.start()
            #expect(fixture.isListeningOnLoopbackOnly)
            #expect(fixture.boundHost == LateLoadRealPathFixture.loopbackHost)
            #expect(fixture.isUsingSystemAssignedPort)
            #expect(fixture.port > 0)

            ImmichServer.clearSavedConfiguration()
            ImmichAPIService.shared.reloadServerConfiguration()
            let keyBeforeSave = ImmichAPIService.shared.getApiKey() ?? ""

            var didStubWriterRun = false
            let server = ImmichServer(
                immichURL: ImmichServer.normalizeServerURL(
                    "http://\(LateLoadRealPathFixture.loopbackHost):\(fixture.port)"
                ),
                immichApiKey: LateLoadRealPathFixture.fixtureCredential
            )
            let didSave = server.save { _ in
                didStubWriterRun = true
                return true
            }
            #expect(didSave)
            #expect(didStubWriterRun)
            // Compute the Bool first so #expect does not expand the environment key or the getApiKey() literal.
            let isKeyUnchangedAfterStubSave =
                (ImmichAPIService.shared.getApiKey() ?? "") == keyBeforeSave
            #expect(isKeyUnchangedAfterStubSave)

            ImmichAPIService.shared.reloadServerConfiguration()
            #expect(isLoadedKeyFixtureCredential())
            if let envKey = ProcessInfo.processInfo.environment["IMMICH_TEST_API_KEY"], !envKey.isEmpty {
                let isUsingEnvironmentKey = ImmichAPIService.shared.getApiKey() == envKey
                #expect(!isUsingEnvironmentKey)
            }
            if let loadedURL = ImmichServer.load()?.immichURL {
                #expect(loadedURL.contains("\(LateLoadRealPathFixture.loopbackHost):\(fixture.port)"))
            } else {
                Issue.record("Test server URL still cannot be read after reload")
            }

            let assetId = "late-load-auth-\(UUID().uuidString)"
            prepareRealLoadPhoto(assetId: assetId, port: fixture.port)
            await AssetsDownloadManager.shared.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)

            let recorded = fixture.completedRequests()
            #expect(!recorded.isEmpty)
            let isEveryHostLoopback = recorded.allSatisfy { request in
                (request.host ?? "").hasPrefix(LateLoadRealPathFixture.loopbackHost)
            }
            #expect(isEveryHostLoopback)
            let didSeeFixtureCredential = recorded.contains { $0.apiKey == LateLoadRealPathFixture.fixtureCredential }
            #expect(didSeeFixtureCredential)
            let hasNoForeignCredential = !recorded.contains { request in
                guard let apiKey = request.apiKey, !apiKey.isEmpty else { return false }
                return apiKey != LateLoadRealPathFixture.fixtureCredential
            }
            #expect(hasNoForeignCredential)
        }
    }

    @Test
    func `interception still works after AssetsDownloadManager and SDWebImage singletons are already initialized`()
        async throws
    {
        _ = AssetsDownloadManager.shared
        _ = SDWebImageManager.shared
        _ = SDWebImageDownloader.shared
        _ = ImmichAPIService.shared
        try await runRealPathProbe { fixture, assetId in
            await AssetsDownloadManager.shared.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
            #expect(fixture.enteredCount(assetId: assetId) > 0)
            #expect(fixture.completedCount(assetId: assetId) > 0)
        }
    }

    @Test
    func
        `releasing a pending real request for A after B becomes current keeps identity on B without A polluting its URL`()
        async throws
    {
        try await ServerConfigurationTestIsolation.run {
            let fixture = LateLoadLocalHTTPFixture()
            var firstPreloadTask: Task<Void, Never>?
            do {
                try await fixture.start()
                #expect(fixture.isListeningOnLoopbackOnly)
                let didInstall = LateLoadRealPathTestSupport.installIsolatedFixtureServer(
                    port: fixture.port,
                    credential: LateLoadRealPathFixture.fixtureCredential
                )
                #expect(didInstall)
                #expect(isLoadedKeyFixtureCredential())

                let assetA = "late-load-real-a-\(UUID().uuidString)"
                let assetB = "late-load-real-b-\(UUID().uuidString)"
                if let jpegA = LateLoadLocalHTTPFixture.makeJPEG(red: 0.9, green: 0.1, blue: 0.1) {
                    fixture.setJPEG(jpegA, for: assetA)
                }
                if let jpegB = LateLoadLocalHTTPFixture.makeJPEG(red: 0.1, green: 0.2, blue: 0.9) {
                    fixture.setJPEG(jpegB, for: assetB)
                }
                fixture.hold(assetIds: [assetA])

                let urlA = try #require(
                    LateLoadRealPathFixture.thumbnailURL(port: fixture.port, assetId: assetA, size: .fullsize)
                )
                let urlB = try #require(
                    LateLoadRealPathFixture.thumbnailURL(port: fixture.port, assetId: assetB, size: .fullsize)
                )
                LateLoadRealPathTestSupport.resetDownloadManager(AssetsDownloadManager.shared)
                LateLoadRealPathTestSupport.clearImageCache(for: [urlA, urlB])

                let vm = SlideShowViewModel(source: .random)
                vm.scenePresentationTimestampProviderForTesting = { 0 }
                vm.backgroundPreloadHookForTesting = { _, _, _ in }
                vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
                vm.loadAssetsHookForTesting = { _ in
                    [self.makeAsset(id: assetA), self.makeAsset(id: assetB)]
                }

                firstPreloadTask = Task {
                    await vm.firstPreload()
                }
                let didHoldA = await waitUntilForTesting {
                    fixture.enteredCount(assetId: assetA) > 0 && vm.safeCurrentScene?.primaryAssetId == assetA
                }
                try #require(didHoldA)
                #expect(fixture.completedCount(assetId: assetA) == 0)

                completeCurrentScenePresentation(vm)
                vm.requestNextScene()

                let didFinishB = await fixture.waitUntilCompleted(assetId: assetB)
                try #require(didFinishB)
                let didBecomeReadyB = await waitUntilForTesting {
                    vm.downloadManager.isReady(assetId: assetB, size: .fullsize)
                }
                try #require(didBecomeReadyB, "B not ready; stop the test, do not go on to synthesize the presentation")
                completeCurrentScenePresentation(vm)

                let visibleAfterNext = vm.safeCurrentScene
                #expect(visibleAfterNext?.primaryAssetId == assetB)
                let sceneIdentityAfterNext = visibleAfterNext?.id
                #expect(sceneIdentityAfterNext != nil)

                fixture.release(assetId: assetA)
                if let firstPreloadTask {
                    await firstPreloadTask.value
                }
                let didFinishLoadPhotoA = vm.downloadManager.isReady(assetId: assetA, size: .fullsize)
                #expect(didFinishLoadPhotoA)

                #expect(fixture.enteredCount(assetId: assetA) > 0)
                #expect(fixture.completedCount(assetId: assetA) > 0)
                #expect(fixture.enteredCount(assetId: assetB) > 0)
                #expect(fixture.completedCount(assetId: assetB) > 0)
                #expect(vm.safeCurrentScene?.primaryAssetId == assetB)
                #expect(vm.safeCurrentScene?.id == sceneIdentityAfterNext)
                #expect(vm.downloadManager.findURL(assetId: assetB, size: .fullsize) != urlA)
                #expect(vm.downloadManager.findURL(assetId: assetB, size: .fullsize) == urlB)
                #expect(vm.downloadManager.findURL(assetId: assetA, size: .fullsize) == urlA)
                fixture.releaseAll()
                fixture.stop()
            } catch {
                // Release the hold before waiting for the Task, so it does not stay parked on the fixture continuation
                // after cancel.
                fixture.releaseAll()
                firstPreloadTask?.cancel()
                if let firstPreloadTask {
                    await firstPreloadTask.value
                }
                fixture.stop()
                throw error
            }
        }
    }

    @Test
    func `current scene B completing its own load keeps identity on B and findURL for B returns B's URL`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }

        let urlA = URL(fileURLWithPath: "/tmp/immichslides-visible-scene-current-a.jpg")
        let urlB = URL(fileURLWithPath: "/tmp/immichslides-visible-scene-current-b.jpg")
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ]
        setCachedURL(urlA, assetId: "asset-a", size: .fullsize, in: vm.downloadManager)
        setCachedURL(urlB, assetId: "asset-b", size: .fullsize, in: vm.downloadManager)
        markReady(assetId: "asset-a", size: .fullsize, in: vm.downloadManager)
        markReady(assetId: "asset-a", size: .preview, in: vm.downloadManager)

        var finishCurrentLoadForB: CheckedContinuation<Void, Never>?
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            if assetId == "asset-b", size == .fullsize, finishCurrentLoadForB == nil {
                await withCheckedContinuation { pending in
                    finishCurrentLoadForB = pending
                }
            }
            let url = assetId == "asset-a" ? urlA : urlB
            setCachedURL(url, assetId: assetId, size: size, in: vm.downloadManager)
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a")

        vm.requestNextScene()
        let visibleSceneAfterNext = vm.safeCurrentScene
        #expect(visibleSceneAfterNext?.primaryAssetId == "asset-b")
        let sceneIdentityAfterNext = visibleSceneAfterNext?.id
        #expect(sceneIdentityAfterNext != nil)

        _ = await waitUntilForTesting { finishCurrentLoadForB != nil }
        finishCurrentLoadForB?.resume()
        completeCurrentScenePresentation(vm)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-b")
        #expect(vm.safeCurrentScene?.id == sceneIdentityAfterNext)
        #expect(vm.downloadManager.findURL(assetId: "asset-b", size: .fullsize) == urlB)
        #expect(vm.downloadManager.findURL(assetId: "asset-b", size: .fullsize) != urlA)
    }
}
