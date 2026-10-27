#if DEBUG
import CryptoKit
import Foundation

/// Sparse, read-only evidence. Failed writes leave a sequence gap or a missing checkpoint, never a success.
final class PlaybackLifecycleTimeline: @unchecked Sendable {
    static let shared = PlaybackLifecycleTimeline()

    struct Event: Codable {
        let schemaVersion = 1
        let launchNonce: String
        let caseNonce: String
        let sequence: Int
        let kind: String
        let uptime: TimeInterval
        let scene: String
        let assets: [String]
        let frame: String
        let isStable: Bool
        let isPaused: Bool
        let request: String
        let exceptionBasis: String
    }

    struct Frame: Equatable {
        let scene: String
        let assets: [String]
        let fingerprint: String
        let isStable: Bool
        let isPaused: Bool
        let outgoingOpacity: Double?
    }

    private let lock = NSRecursiveLock()
    private let launchNonce = UUID().uuidString
    private let configuration = PlatformCompat.lifecycleTimelineConfigurationForTesting
    private var sequence = 0
    private var fileHandle: FileHandle?
    private var previousFrame: Frame?
    private var lastRequest = ""
    private var frozenFingerprint: String?
    private var decodedAssets: [String: Set<String>] = [:]

    private init() {
        record("timelineStarted")
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sceneKey(_ identity: PlaybackSessionEngine.ScenePresentationIdentity) -> String {
        hash(identity.generation.uuidString + ":" + identity.sceneID)
    }

    func rendererDecoded(_ identity: SceneRendererIdentity) {
        guard configuration != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = Self.hash(identity.generation.uuidString + ":" + identity.sceneID)
        decodedAssets[key, default: []].insert(Self.hash(identity.assetID))
    }

    func areAllSlotsDecoded(scene: String, assets: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !assets.isEmpty && Set(assets).isSubset(of: decodedAssets[scene] ?? [])
    }

    func record(
        _ kind: String, frame: Frame? = nil, scene: String? = nil, request: String = "", exceptionBasis: String = "",
        uptime: TimeInterval? = nil
    ) {
        guard let configuration else { return }
        lock.lock()
        defer { lock.unlock() }
        // The event timestamp precedes all serialization and disk IO.
        let uptime = uptime ?? ProcessInfo.processInfo.systemUptime
        sequence += 1
        let event = Event(
            launchNonce: launchNonce, caseNonce: configuration.nonce, sequence: sequence, kind: kind,
            uptime: uptime, scene: scene ?? frame?.scene ?? previousFrame?.scene ?? "",
            assets: frame?.assets ?? previousFrame?.assets ?? [], frame: frame?.fingerprint ?? "",
            isStable: frame?.isStable ?? false, isPaused: frame?.isPaused ?? false, request: request,
            exceptionBasis: exceptionBasis)
        do {
            if fileHandle == nil {
                try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
                let url = configuration.directory.appendingPathComponent("playback-lifecycle-timeline.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                fileHandle = try FileHandle(forWritingTo: url)
                try fileHandle?.seekToEnd()
            }
            let line = try JSONEncoder().encode(event) + Data("\n".utf8)
            try fileHandle?.write(contentsOf: line)
        } catch {
            // A following durable event exposes the missing sequence; missing tail acknowledgements time out.
            fileHandle = nil
        }
    }

    func recordReceipt(_ kind: String, frame: @autoclosure () -> Frame) {
        guard configuration != nil else { return }
        // Snapshot construction must not move an input's origin under App CPU starvation.
        let uptime = ProcessInfo.processInfo.systemUptime
        record(kind, frame: frame(), uptime: uptime)
    }

    /// Called only after the render transaction completes and its next display tick arrives.
    func committedFrame(_ frame: Frame) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let configuration else { return }
        lock.lock()
        defer { lock.unlock() }
        if let previousFrame {
            if let opacity = frame.outgoingOpacity, opacity < 1,
                previousFrame.outgoingOpacity == nil || previousFrame.outgoingOpacity == 1
            {
                record("renderFadeStarted", frame: frame, uptime: uptime)
            }
            if previousFrame.isStable && !frame.isStable { record("renderUnstable", frame: frame, uptime: uptime) }
            if frame.isPaused && previousFrame.isPaused && frame.fingerprint != previousFrame.fingerprint {
                record("frozenFrameChanged", frame: frame, uptime: uptime)
            }
            if frame.isPaused && previousFrame.isPaused && frame.fingerprint == previousFrame.fingerprint {
                if frozenFingerprint != frame.fingerprint {
                    record("frameFrozen", frame: frame, uptime: uptime)
                    frozenFingerprint = frame.fingerprint
                }
            } else {
                frozenFingerprint = nil
            }
        }
        if frame.isStable
            && (previousFrame?.isStable != true || previousFrame?.scene != frame.scene
                || (previousFrame?.isPaused == true && !frame.isPaused))
        {
            record("sceneStable", frame: frame, uptime: uptime)
        }
        if frame.isPaused && previousFrame?.isPaused != true {
            record("pauseFrameCommitted", frame: frame, uptime: uptime)
        }
        previousFrame = frame
        let requestURL = configuration.directory.appendingPathComponent("playback-lifecycle-request")
        if let request = try? String(contentsOf: requestURL, encoding: .utf8), !request.isEmpty,
            request != lastRequest
        {
            lastRequest = request
            record(request.hasPrefix("clock-") ? "clockHandshake" : "checkpoint", frame: frame, request: request)
        }
    }
}

extension SlideShowViewModel {
    func lifecycleTimelineFrame(
        _ snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> PlaybackLifecycleTimeline.Frame {
        guard PlatformCompat.lifecycleTimelineConfigurationForTesting != nil else {
            return PlaybackLifecycleTimeline.Frame(
                scene: "", assets: [], fingerprint: "", isStable: false, isPaused: false, outgoingOpacity: nil)
        }
        let visible = snapshot.layers.filter { $0.opacity > 0 }
        let primary = visible.max(by: { $0.opacity < $1.opacity }) ?? snapshot.layers.first
        let scene = primary.map { PlaybackLifecycleTimeline.sceneKey($0.identity) } ?? ""
        let assets =
            primary.flatMap { self.scene(for: $0) }?.photoSlots.map {
                PlaybackLifecycleTimeline.hash($0.asset.id)
            } ?? []
        let isStable =
            visible.count == 1 && visible[0].opacity == 1 && visible[0].isPresentationReady
            && PlaybackLifecycleTimeline.shared.areAllSlotsDecoded(scene: scene, assets: assets)
        let fingerprint = snapshot.layers.filter { $0.opacity > 0 }.map {
            "\(PlaybackLifecycleTimeline.sceneKey($0.identity)):\($0.opacity):\($0.motionActiveTime)"
        }.joined(separator: "|")
        return PlaybackLifecycleTimeline.Frame(
            scene: scene, assets: assets, fingerprint: PlaybackLifecycleTimeline.hash(fingerprint),
            isStable: isStable, isPaused: snapshot.suspensionReasons.contains(.userPaused),
            outgoingOpacity: snapshot.layers.first(where: { $0.role == .outgoing })?.opacity)
    }
}
#endif
