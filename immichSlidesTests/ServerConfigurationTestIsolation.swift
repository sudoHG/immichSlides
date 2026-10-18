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

// Observes URLSession.shared traffic only; SDWebImage's independent sessions are outside this scope.
private final class LiveRequestObserver: URLProtocol, @unchecked Sendable {
    private struct Scope {
        let token: UUID
        var isRateLimited = false
        var isConcurrencyLimited = false
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var host: String?
    nonisolated(unsafe) private static var scope: Scope?
    nonisolated(unsafe) private static var observers: [Int: LiveRequestObserver] = [:]
    nonisolated(unsafe) private static var starts: [TimeInterval] = []
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var peakInFlight = 0
    private static let forwardingSession: URLSession = {
        let configuration = URLSession.shared.configuration
        // Reuse connections and the original cache policy without recursively intercepting the forwarding session.
        configuration.protocolClasses = []
        return URLSession(configuration: configuration, delegate: ForwardingDelegate(), delegateQueue: nil)
    }()
    // Client callbacks can synchronously stop loading; serialize them with cancellation without deadlocking.
    private let callbackLock = NSRecursiveLock()
    private static let testTokenKey = "LiveRequestObserver.testToken"
    private let initialTestToken = LiveRequestObserver.lock.withLock { LiveRequestObserver.scope?.token }
    private var testToken: UUID? {
        if let value = URLProtocol.property(forKey: Self.testTokenKey, in: request) as? String {
            return UUID(uuidString: value)
        }
        return initialTestToken
    }
    private var isStopped = false
    private var forwardingTask: URLSessionDataTask?

    private final class ForwardingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let observer = LiveRequestObserver.lock.withLock { LiveRequestObserver.observers[task.taskIdentifier] }
            observer?.redirect(to: request, response: response)
            completionHandler(nil)
        }
    }

    static func begin() -> UUID {
        let token = UUID()
        lock.withLock {
            host = TestServerConfiguration.current.flatMap { URL(string: $0.serverURL)?.host }
            scope = Scope(token: token)
        }
        URLProtocol.registerClass(Self.self)
        return token
    }

    static func finish(token: UUID) -> (isRateLimited: Bool, isConcurrencyLimited: Bool) {
        lock.withLock {
            guard let finished = scope, finished.token == token else { return (false, false) }
            host = nil
            scope = nil
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
            return (finished.isRateLimited, finished.isConcurrencyLimited)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { host != nil && request.url?.host == host }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        callbackLock.withLock {
            guard !isStopped else { return }
            var forwarded = request
            if let stream = forwarded.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 {
                        client?.urlProtocol(
                            self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeContentData))
                        return
                    }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                forwarded.httpBodyStream = nil
                forwarded.httpBody = body
                forwarded.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
                forwarded.setValue(nil, forHTTPHeaderField: "Transfer-Encoding")
            }
            let token = Self.lock.withLock {
                Self.starts.append(ProcessInfo.processInfo.systemUptime)
                Self.inFlight += 1
                Self.peakInFlight = max(Self.peakInFlight, Self.inFlight)
                return testToken
            }
            forwardingTask = Self.forwardingSession.dataTask(with: forwarded) { [self] data, response, error in
                Self.lock.withLock {
                    Self.inFlight -= 1
                    if let task = forwardingTask { Self.observers.removeValue(forKey: task.taskIdentifier) }
                    // A response from a finished test must never be attributed to the next test.
                    if let token, Self.scope?.token == token {
                        switch (response as? HTTPURLResponse)?.statusCode {
                        case 429: Self.scope?.isRateLimited = true
                        case 503: Self.scope?.isConcurrencyLimited = true
                        default: break
                        }
                    }
                }
                callbackLock.withLock {
                    guard !isStopped else { return }
                    if let error {
                        client?.urlProtocol(self, didFailWithError: error)
                    } else if let response {
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        guard !isStopped else { return }
                        if let data { client?.urlProtocol(self, didLoad: data) }
                        guard !isStopped else { return }
                        client?.urlProtocolDidFinishLoading(self)
                    }
                }
            }
            if let task = forwardingTask {
                Self.lock.withLock { Self.observers[task.taskIdentifier] = self }
                task.resume()
            }
        }
    }

    private func redirect(to request: URLRequest, response: HTTPURLResponse) {
        callbackLock.withLock {
            guard !isStopped else { return }
            isStopped = true
            let redirected = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
            if let token = testToken {
                URLProtocol.setProperty(token.uuidString, forKey: Self.testTokenKey, in: redirected)
            }
            client?.urlProtocol(self, wasRedirectedTo: redirected as URLRequest, redirectResponse: response)
        }
    }

    override func stopLoading() {
        callbackLock.withLock {
            isStopped = true
            forwardingTask?.cancel()
        }
    }
}

enum LiveTestTraffic {
    private static let verificationLimiter = LiveVerificationLimiter()

    static func observe<T>(_ body: () async throws -> T) async rethrows -> T {
        let token = LiveRequestObserver.begin()
        defer {
            let limits = LiveRequestObserver.finish(token: token)
            if limits.isRateLimited {
                Issue.record("TEST_SERVER_RATE_LIMITED: test server rate limited")
            }
            if limits.isConcurrencyLimited {
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
