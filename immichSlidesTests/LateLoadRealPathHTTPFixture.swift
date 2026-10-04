//
//  LateLoadRealPathHTTPFixture.swift
//  immichSlidesTests
//
//  Local loopback HTTP fixture: sends the real loadPhoto / SDWebImage traffic to a test port,
//  without relying on URLProtocol or an already-initialized shared downloader session.
//

import Foundation
import Network
import os
import SDWebImage
import UIKit
@testable import immichSlides

enum LateLoadRealPathFixture {
    static let loopbackHost = "127.0.0.1"
    static let fixtureCredential = "late-load-fixture"

    static func thumbnailURL(port: UInt16, assetId: String, size: ThumbnailSize) -> URL? {
        URL(string: "http://\(loopbackHost):\(port)/api/assets/\(assetId)/thumbnail?size=\(size.rawValue)")
    }
}

struct LateLoadRecordedRequest: Sendable, Equatable {
    let method: String
    let path: String
    let assetId: String?
    let host: String?
    let apiKey: String?
}

final class LateLoadLocalHTTPFixture: Sendable {
    private struct State: Sendable {
        var listener: NWListener?
        var heldAssetIds: Set<String> = []
        var holdWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        var entered: [LateLoadRecordedRequest] = []
        var completed: [LateLoadRecordedRequest] = []
        var jpegByAssetId: [String: Data] = [:]
        var openConnections: [ObjectIdentifier: NWConnection] = [:]
        var port: UInt16 = 0
        var boundHost: String?
        var usesSystemAssignedPort = false
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "late-load.http")
    private static let listenerStartTimeoutSeconds: TimeInterval = 10
    private let defaultJPEG: Data

    var port: UInt16 {
        stateLock.withLock { $0.port }
    }

    var boundHost: String? {
        stateLock.withLock { $0.boundHost }
    }

    var usesSystemAssignedPort: Bool {
        stateLock.withLock { $0.usesSystemAssignedPort }
    }

    var isListeningOnLoopbackOnly: Bool {
        stateLock.withLock { state in
            state.boundHost == LateLoadRealPathFixture.loopbackHost
                && state.usesSystemAssignedPort
                && state.port > 0
        }
    }

    init() {
        defaultJPEG = Self.makeJPEG(red: 0.2, green: 0.4, blue: 0.8) ?? Data()
    }

    deinit {
        // On assertion failure or task cancellation the caller's defer may not stop it in time; close the listener here
        // as a fallback.
        stop()
    }

    func start() async throws {
        // Bind only to IPv4 loopback and let the system assign the port; NWListener(..., on: .any) listens on all
        // interfaces.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        let listener = try NWListener(using: parameters)
        stateLock.withLock { state in
            state.listener = listener
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let didResume = OSAllocatedUnfairLock(initialState: false)
            let claimResume: @Sendable () -> Bool = {
                didResume.withLock { hasResumed in
                    guard !hasResumed else { return false }
                    hasResumed = true
                    return true
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard claimResume() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard claimResume() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard claimResume() else { return }
                    continuation.resume(throwing: URLError(.cancelled))
                default:
                    break
                }
            }
            listener.start(queue: queue)
            // Bounds the start: a listener stuck in .setup or .waiting never reaches .ready or .failed.
            queue.asyncAfter(deadline: .now() + Self.listenerStartTimeoutSeconds) {
                guard claimResume() else { return }
                listener.cancel()
                continuation.resume(throwing: URLError(.timedOut))
            }
        }

        try recordVerifiedLoopbackBind(parameters: parameters, listener: listener)
        guard !defaultJPEG.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
    }

    func stop() {
        let (waiters, connections, listener) = stateLock.withLock { state in
            let waiters = state.holdWaiters
            state.holdWaiters = [:]
            state.heldAssetIds = []
            let connections = Array(state.openConnections.values)
            state.openConnections = [:]
            let listener = state.listener
            state.listener = nil
            return (waiters, connections, listener)
        }
        for continuations in waiters.values {
            for continuation in continuations {
                continuation.resume()
            }
        }
        // Cancel connections before the listener, so old requests do not hold the utility queue in the next test.
        for connection in connections {
            connection.cancel()
        }
        listener?.cancel()
    }

    func hold(assetIds: Set<String>) {
        stateLock.withLock { state in
            state.heldAssetIds.formUnion(assetIds)
        }
    }

    func release(assetId: String) {
        let waiters = stateLock.withLock { state in
            state.heldAssetIds.remove(assetId)
            return state.holdWaiters.removeValue(forKey: assetId) ?? []
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func releaseAll() {
        let waiters = stateLock.withLock { state in
            state.heldAssetIds = []
            let waiters = state.holdWaiters
            state.holdWaiters = [:]
            return waiters
        }
        for continuations in waiters.values {
            for continuation in continuations {
                continuation.resume()
            }
        }
    }

    func setJPEG(_ data: Data, for assetId: String) {
        stateLock.withLock { state in
            state.jpegByAssetId[assetId] = data
        }
    }

    func enteredRequests() -> [LateLoadRecordedRequest] {
        stateLock.withLock { $0.entered }
    }

    func completedRequests() -> [LateLoadRecordedRequest] {
        stateLock.withLock { $0.completed }
    }

    func enteredCount(assetId: String) -> Int {
        enteredRequests().filter { $0.assetId == assetId }.count
    }

    func completedCount(assetId: String) -> Int {
        completedRequests().filter { $0.assetId == assetId }.count
    }

    func waitUntilEntered(assetId: String, timeout: TimeInterval = 8) async -> Bool {
        await waitUntil(timeout: timeout) { self.enteredCount(assetId: assetId) > 0 }
    }

    func waitUntilCompleted(assetId: String, timeout: TimeInterval = 8) async -> Bool {
        await waitUntil(timeout: timeout) { self.completedCount(assetId: assetId) > 0 }
    }

    private func recordVerifiedLoopbackBind(parameters: NWParameters, listener: NWListener) throws {
        guard case .hostPort(let host, let requestedPort) = parameters.requiredLocalEndpoint else {
            throw URLError(.cannotConnectToHost)
        }
        let isIPv4Loopback: Bool
        if case .ipv4(let address) = host {
            isIPv4Loopback = address == .loopback
        } else {
            isIPv4Loopback = false
        }
        guard isIPv4Loopback, requestedPort == .any else {
            throw URLError(.cannotConnectToHost)
        }
        guard let rawPort = listener.port?.rawValue, rawPort > 0 else {
            throw URLError(.cannotConnectToHost)
        }
        stateLock.withLock { state in
            state.boundHost = LateLoadRealPathFixture.loopbackHost
            state.usesSystemAssignedPort = true
            state.port = rawPort
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func handle(_ connection: NWConnection) {
        stateLock.withLock { state in
            state.openConnections[ObjectIdentifier(connection)] = connection
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        stateLock.withLock { state in
            _ = state.openConnections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                self.forget(connection)
                return
            }
            var next = buffer
            if let data {
                next.append(data)
            }
            guard let headerRange = next.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    connection.cancel()
                    self.forget(connection)
                } else {
                    self.receiveRequest(on: connection, buffer: next)
                }
                return
            }
            let headerData = next.subdata(in: next.startIndex..<headerRange.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8),
                let parsed = Self.parseHTTPRequest(headerText)
            else {
                self.send(status: 400, body: Data(), on: connection)
                return
            }
            Task {
                await self.fulfill(parsed, on: connection)
            }
        }
    }

    private func fulfill(_ request: LateLoadRecordedRequest, on connection: NWConnection) async {
        let shouldHold = stateLock.withLock { state in
            state.entered.append(request)
            return request.assetId.map { state.heldAssetIds.contains($0) } ?? false
        }

        if shouldHold, let assetId = request.assetId {
            await withCheckedContinuation { continuation in
                let shouldResume = stateLock.withLock { state in
                    if state.heldAssetIds.contains(assetId) {
                        state.holdWaiters[assetId, default: []].append(continuation)
                        return false
                    }
                    return true
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }

        let body = stateLock.withLock { state in
            if let assetId = request.assetId, let jpeg = state.jpegByAssetId[assetId] {
                return jpeg
            }
            return defaultJPEG
        }

        let contentType =
            body.starts(with: Data([0x89, 0x50, 0x4E, 0x47]))
            ? "image/png"
            : "image/jpeg"
        send(status: 200, body: body, contentType: contentType, on: connection)

        stateLock.withLock { state in
            state.completed.append(request)
        }
    }

    private func send(status: Int, body: Data, contentType: String = "text/plain", on connection: NWConnection) {
        let reason = status == 200 ? "OK" : "Error"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(
            content: payload,
            completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                self?.forget(connection)
            })
    }

    private static func parseHTTPRequest(_ headerText: String) -> LateLoadRecordedRequest? {
        let lines = headerText.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let requestLine = lines.first else { return nil }
        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2 else { return nil }
        let method = String(tokens[0])
        let path = String(tokens[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return LateLoadRecordedRequest(
            method: method,
            path: path,
            assetId: assetId(from: path),
            host: headers["host"],
            apiKey: headers["x-api-key"]
        )
    }

    private static func assetId(from path: String) -> String? {
        let pathOnly =
            path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? path
        let parts = pathOnly.split(separator: "/").map(String.init)
        guard let assetsIndex = parts.firstIndex(of: "assets"),
            assetsIndex + 1 < parts.count
        else {
            return nil
        }
        return parts[assetsIndex + 1]
    }

    static func makeJPEG(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}

@MainActor
enum LateLoadRealPathTestSupport {
    @discardableResult
    static func installIsolatedFixtureServer(port: UInt16, credential: String) -> Bool {
        ImmichServer.clearSavedConfiguration()
        let server = ImmichServer(
            immichURL: ImmichServer.normalizeServerURL("http://\(LateLoadRealPathFixture.loopbackHost):\(port)"),
            immichApiKey: credential
        )
        let didSave = server.save(writeAPIKeyToKeychain: { _ in true })
        ImmichAPIService.shared.reloadServerConfiguration()
        return didSave
    }

    // Cancel in-flight tasks and clear the memory cache, so HTTP/SDWebImage work from the previous test does not stall
    // this test's detached planning.
    static func resetDownloadManager(_ manager: AssetsDownloadManager) {
        manager.resetForServerConfigurationChange()
        SDWebImageManager.shared.cancelAll()
        SDWebImageDownloader.shared.cancelAllDownloads()
    }

    static func clearImageCache(for urls: [URL]) {
        for url in urls {
            SDImageCache.shared.removeImageFromMemory(forKey: url.absoluteString)
            SDImageCache.shared.removeImageFromDisk(forKey: url.absoluteString)
        }
    }
}
