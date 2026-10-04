//
//  ServerConfigurationTestIsolation.swift
//  immichSlidesTests
//
//  Serializes the shared server; explicitly restores playback settings, filters and the download singleton
//  when needed.
//

import Foundation
import SDWebImage
import Testing
@testable import immichSlides

private actor ServerConfigurationAsyncLock {
    // Async lock held across await; an NSLock cannot be held while suspended.

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        let nextWaiter = waiters.removeFirst()
        nextWaiter.resume()
    }
}

enum ServerConfigurationTestIsolation {
    private static let lock = ServerConfigurationAsyncLock()

    // In one test the suite trait and an explicit run nest one level; never wait on ourselves.
    @TaskLocal private static var isHeld = false

    static func run<T>(_ body: () async throws -> T) async rethrows -> T {
        try await run(capturingSharedRuntimeState: false, body)
    }

    // Only callers that opt into sharedPlaybackRuntimeIsolation (or runWithSharedRuntimeState) clear
    // shared playback state; other callers keep their existing semantics.
    static func runWithSharedRuntimeState<T>(
        defaults: UserDefaults = .standard,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await run(capturingSharedRuntimeState: true, defaults: defaults, body)
    }

    private static func run<T>(
        capturingSharedRuntimeState: Bool,
        defaults: UserDefaults = .standard,
        _ body: () async throws -> T
    ) async rethrows -> T {
        if isHeld {
            guard capturingSharedRuntimeState else {
                return try await body()
            }

            let snapshot = await ServerConfigurationSnapshot.capture(
                includeSharedRuntimeState: true, defaults: defaults)
            await snapshot.prepareForTest()
            do {
                let result = try await body()
                await snapshot.restore()
                return result
            } catch {
                await snapshot.restore()
                throw error
            }
        }

        await lock.acquire()
        let snapshot = await ServerConfigurationSnapshot.capture(
            includeSharedRuntimeState: capturingSharedRuntimeState, defaults: defaults
        )
        await snapshot.prepareForTest()

        do {
            let result = try await $isHeld.withValue(true) {
                try await body()
            }
            await snapshot.restore()
            await lock.release()
            return result
        } catch {
            await snapshot.restore()
            await lock.release()
            throw error
        }
    }
}

// Cross-suite mutual exclusion: .serialized only covers its own suite and cannot stop CacheReload from clearing
// the shared manager.
struct SharedRuntimeIsolationTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await ServerConfigurationTestIsolation.run(function)
    }
}

extension Trait where Self == SharedRuntimeIsolationTrait {
    static var sharedRuntimeIsolation: Self { Self() }
}

struct SharedPlaybackRuntimeIsolationTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await ServerConfigurationTestIsolation.runWithSharedRuntimeState(function)
    }
}

extension Trait where Self == SharedPlaybackRuntimeIsolationTrait {
    static var sharedPlaybackRuntimeIsolation: Self { Self() }
}

private struct ServerConfigurationSnapshot {
    let storedServer: ImmichServer?
    let sharedRuntime: SharedRuntimeSnapshot?

    @MainActor
    static func capture(includeSharedRuntimeState: Bool, defaults: UserDefaults) -> ServerConfigurationSnapshot {
        ServerConfigurationSnapshot(
            storedServer: ImmichServer.load(),
            sharedRuntime: includeSharedRuntimeState ? SharedRuntimeSnapshot.capture(defaults: defaults) : nil
        )
    }

    @MainActor
    func prepareForTest() {
        sharedRuntime?.prepareForTest()
    }

    @MainActor
    func restore() {
        // Restore both persistence and APIService memory so the next test does not read a stale singleton.
        sharedRuntime?.restore()

        if let storedServer {
            storedServer.save()
        } else {
            ImmichServer.clearSavedConfiguration()
        }

        ImmichAPIService.shared.reloadServerConfiguration()
    }
}

private struct SharedRuntimeSnapshot {
    let defaults: UserDefaults
    let playbackSettingsValue: Any?
    let filterSelectionValue: Any?
    let downloadManager: DownloadManagerSnapshot

    @MainActor
    static func capture(defaults: UserDefaults) -> SharedRuntimeSnapshot {
        SharedRuntimeSnapshot(
            defaults: defaults,
            playbackSettingsValue: defaults.object(forKey: "playbackSettings"),
            filterSelectionValue: defaults.object(forKey: "filterSelection"),
            downloadManager: DownloadManagerSnapshot.capture()
        )
    }

    @MainActor
    func prepareForTest() {
        defaults.removeObject(forKey: "playbackSettings")
        defaults.removeObject(forKey: "filterSelection")
        AssetsDownloadManager.shared.resetForServerConfigurationChange()
        SDWebImageManager.shared.cancelAll()
        SDWebImageDownloader.shared.cancelAllDownloads()
        #if DEBUG
        AssetsDownloadManager.shared.resetPlaybackImageRequestLifecycleDiagnostics()
        #endif
    }

    @MainActor
    func restore() {
        AssetsDownloadManager.shared.resetForServerConfigurationChange()
        downloadManager.restore(to: AssetsDownloadManager.shared)
        #if DEBUG
        AssetsDownloadManager.shared.resetPlaybackImageRequestLifecycleDiagnostics()
        #endif

        // Put the persisted values back as-is, so a decode failure does not become a delete and re-encoding does not
        // change the original bytes.
        defaults.set(playbackSettingsValue, forKey: "playbackSettings")
        defaults.set(filterSelectionValue, forKey: "filterSelection")
    }
}

private struct DownloadManagerSnapshot {
    let assetStates: [String: AssetStates]
    let assetPreviewStates: [String: AssetStates]
    let assetThumbnailStates: [String: AssetStates]
    let assetURLs: [String: URL]
    let assetPreviewURLs: [String: URL]
    let assetThumbnailURLs: [String: URL]

    @MainActor
    static func capture() -> DownloadManagerSnapshot {
        let manager = AssetsDownloadManager.shared
        return DownloadManagerSnapshot(
            assetStates: manager.assetStates,
            assetPreviewStates: manager.assetPreviewStates,
            assetThumbnailStates: manager.assetThumbnailStates,
            assetURLs: manager.assetURLs,
            assetPreviewURLs: manager.assetPreviewURLs,
            assetThumbnailURLs: manager.assetThumbnailURLs
        )
    }

    @MainActor
    func restore(to manager: AssetsDownloadManager) {
        manager.assetStates = assetStates
        manager.assetPreviewStates = assetPreviewStates
        manager.assetThumbnailStates = assetThumbnailStates
        manager.assetURLs = assetURLs
        manager.assetPreviewURLs = assetPreviewURLs
        manager.assetThumbnailURLs = assetThumbnailURLs
    }
}
