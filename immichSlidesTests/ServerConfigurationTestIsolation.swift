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

// Observes only the configured live host; forwarding leaves App request scheduling unchanged.
private final class LiveRequestObserver: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var host: String?
    nonisolated(unsafe) private static var starts: [TimeInterval] = []
    nonisolated(unsafe) private static var rateLimited = false
    nonisolated(unsafe) private static var concurrencyLimited = false
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var peakInFlight = 0
    private var forwardingTask: URLSessionDataTask?
    private var forwardingSession: URLSession?

    static func begin() {
        lock.withLock {
            host = TestServerConfiguration.current.flatMap { URL(string: $0.serverURL)?.host }
            rateLimited = false
            concurrencyLimited = false
        }
        URLProtocol.registerClass(Self.self)
    }

    static func finish() -> (rateLimited: Bool, concurrencyLimited: Bool) {
        lock.withLock {
            host = nil
            if let first = starts.first {
                var minutes: [Int: Int] = [:]
                var windowStart = 0
                var peak = 0
                var secondStart = 0
                var peakSecond = 0
                for (index, start) in starts.enumerated() {
                    minutes[Int((start - first) / 60), default: 0] += 1
                    while start - starts[windowStart] >= 60 { windowStart += 1 }
                    peak = max(peak, index - windowStart + 1)
                    while start - starts[secondStart] >= 1 { secondStart += 1 }
                    peakSecond = max(peakSecond, index - secondStart + 1)
                }
                let buckets = minutes.keys.sorted().map { "\($0):\(minutes[$0]!)" }.joined(separator: ",")
                print(
                    "LIVE_REQUEST_COUNTS total=\(starts.count) peakRollingMinute=\(peak) peakRollingSecond=\(peakSecond) peakInFlight=\(peakInFlight) minutes=\(buckets)"
                )
            }
            return (rateLimited, concurrencyLimited)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { host != nil && request.url?.host == host }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.starts.append(ProcessInfo.processInfo.systemUptime)
            Self.inFlight += 1
            Self.peakInFlight = max(Self.peakInFlight, Self.inFlight)
        }
        let configuration = URLSessionConfiguration.ephemeral
        // Explicit protocols avoid recursively intercepting the observer's forwarded request.
        configuration.protocolClasses = []
        let session = URLSession(configuration: configuration)
        forwardingSession = session
        forwardingTask = session.dataTask(with: request) { [self] data, response, error in
            Self.lock.withLock {
                Self.inFlight -= 1
                switch (response as? HTTPURLResponse)?.statusCode {
                case 429: Self.rateLimited = true
                case 503: Self.concurrencyLimited = true
                default: break
                }
            }
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
            } else if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data { client?.urlProtocol(self, didLoad: data) }
                client?.urlProtocolDidFinishLoading(self)
            }
            session.finishTasksAndInvalidate()
        }
        forwardingTask?.resume()
    }

    override func stopLoading() {
        forwardingTask?.cancel()
        forwardingSession?.invalidateAndCancel()
    }
}

enum LiveTestTraffic {
    private static let verificationLimiter = LiveVerificationLimiter()

    static func observe<T>(_ body: () async throws -> T) async rethrows -> T {
        LiveRequestObserver.begin()
        defer {
            let limits = LiveRequestObserver.finish()
            if limits.rateLimited {
                Issue.record("TEST_SERVER_RATE_LIMITED: test server rate limited")
            }
            if limits.concurrencyLimited {
                Issue.record("TEST_SERVER_CONCURRENCY_LIMITED: gateway concurrency limit")
            }
        }
        return try await body()
    }

    @MainActor
    static func verificationRequest<T>(_ body: () async throws -> T) async throws -> T {
        try await verificationLimiter.acquire()
        do {
            let value = try await body()
            await verificationLimiter.release()
            return value
        } catch {
            await verificationLimiter.release()
            throw error
        }
    }

    @MainActor
    static func independentlyLoadedAssets(ids: [String], api: ImmichAPIService) async throws -> [Asset] {
        try await withThrowingTaskGroup(of: (Int, Asset).self) { group in
            var nextIndex = 0
            var loaded = [Asset?](repeating: nil, count: ids.count)
            func addNext() {
                guard nextIndex < ids.count else { return }
                let index = nextIndex
                nextIndex += 1
                group.addTask { @MainActor in
                    let asset = try await verificationRequest { try await api.getAsset(id: ids[index]) }
                    return (index, asset)
                }
            }
            for _ in 0..<LiveVerificationLimiter.maximumInFlight { addNext() }
            while let (index, asset) = try await group.next() {
                loaded[index] = asset
                addNext()
            }
            return loaded.compactMap { $0 }
        }
    }
}

private actor LiveVerificationLimiter {
    static let maximumInFlight = 4
    private let minimumStartGap: Duration = .seconds(TestWait.seconds(.infrastructure(0.07)))
    private let clock = ContinuousClock()
    private var nextStart: ContinuousClock.Instant?
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async throws {
        if inFlight == Self.maximumInFlight {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            inFlight += 1
        }
        do {
            // Recheck after suspension: overdue sleepers must never resume as a burst.
            while let nextStart, clock.now < nextStart {
                try await clock.sleep(until: nextStart)
            }
            try Task.checkCancellation()
            nextStart = clock.now.advanced(by: minimumStartGap)
        } catch {
            release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

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
        try await run(shouldCaptureSharedRuntimeState: false, body)
    }

    // Only callers that opt into sharedPlaybackRuntimeIsolation (or runWithSharedRuntimeState) clear
    // shared playback state; other callers keep their existing semantics.
    static func runWithSharedRuntimeState<T>(
        defaults: UserDefaults = .standard,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await run(shouldCaptureSharedRuntimeState: true, defaults: defaults, body)
    }

    private static func run<T>(
        shouldCaptureSharedRuntimeState: Bool,
        defaults: UserDefaults = .standard,
        _ body: () async throws -> T
    ) async rethrows -> T {
        if isHeld {
            guard shouldCaptureSharedRuntimeState else {
                return try await body()
            }

            let snapshot = await ServerConfigurationSnapshot.capture(
                shouldIncludeSharedRuntimeState: true, defaults: defaults)
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
            shouldIncludeSharedRuntimeState: shouldCaptureSharedRuntimeState, defaults: defaults
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
    static func capture(shouldIncludeSharedRuntimeState: Bool, defaults: UserDefaults) -> ServerConfigurationSnapshot {
        ServerConfigurationSnapshot(
            storedServer: ImmichServer.load(),
            sharedRuntime: shouldIncludeSharedRuntimeState ? SharedRuntimeSnapshot.capture(defaults: defaults) : nil
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
