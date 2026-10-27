#if DEBUG
import CryptoKit
import Darwin
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
        let transitionScene: String
        let transitionSource: String
        let heldTargetScene: String
    }

    struct LayerSample: Equatable {
        let scene: String
        let opacity: Double
        let motionActiveTime: TimeInterval
    }

    struct Frame: Equatable {
        let scene: String
        let assets: [String]
        let fingerprint: [LayerSample]
        let isStable: Bool
        let isPaused: Bool
        let outgoingOpacity: Double?
        let transitionScene: String
        let transitionSource: String
        let heldTargetScene: String
    }

    private let lock = NSRecursiveLock()
    private let launchNonce = UUID().uuidString
    private let configuration = PlatformCompat.lifecycleTimelineConfigurationForTesting
    private let requestURL = PlatformCompat.lifecycleTimelineConfigurationForTesting?.directory
        .appendingPathComponent("playback-lifecycle-request")
    var isEnabled: Bool { configuration != nil }
    private var sequence = 0
    private var fileHandle: FileHandle?
    private var previousFrame: Frame?
    private var lastRequest = ""
    private var pendingRequest = ""
    private var requestModificationDate: Date?
    private var requestMonitor: DispatchSourceFileSystemObject?
    private var frozenFingerprint: [LayerSample]?
    private var decodedAssets: [String: Set<String>] = [:]
    private var sceneKeys: [PlaybackSessionEngine.ScenePresentationIdentity: String] = [:]
    private var sceneAssets: [String: [String]] = [:]
    private var lastFingerprint: (samples: [LayerSample], hash: String)?

    private init() {
        record("timelineStarted")
        monitorRequestChanges()
    }

    static func hash(_ value: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(
            decoding: SHA256.hash(data: Data(value.utf8)).flatMap { byte in
                [digits[Int(byte >> 4)], digits[Int(byte & 15)]]
            }, as: UTF8.self)
    }

    static func sceneKey(_ identity: PlaybackSessionEngine.ScenePresentationIdentity) -> String {
        let recorder = shared
        recorder.lock.lock()
        defer { recorder.lock.unlock() }
        if let key = recorder.sceneKeys[identity] { return key }
        let key = hash(identity.generation.uuidString + ":" + identity.sceneID)
        recorder.sceneKeys[identity] = key
        return key
    }

    func cachedAssets(scene: String, load: () -> [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let assets = sceneAssets[scene] { return assets }
        let assets = load().map(Self.hash)
        sceneAssets[scene] = assets
        return assets
    }

    private func frameHash(_ frame: Frame) -> String {
        if let lastFingerprint, lastFingerprint.samples == frame.fingerprint { return lastFingerprint.hash }
        let hash = Self.hash(
            frame.fingerprint.map { "\($0.scene):\($0.opacity):\($0.motionActiveTime)" }.joined(separator: "|"))
        lastFingerprint = (frame.fingerprint, hash)
        return hash
    }

    private func monitorRequestChanges() {
        guard let configuration else { return }
        let descriptor = open(configuration.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        monitor.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.cacheRequest() }
        }
        monitor.setCancelHandler { close(descriptor) }
        requestMonitor = monitor
        monitor.resume()
        cacheRequest()
    }

    private func cacheRequest() {
        guard let requestURL,
            let attributes = try? FileManager.default.attributesOfItem(atPath: requestURL.path),
            let modification = attributes[.modificationDate] as? Date,
            modification != requestModificationDate,
            let request = try? String(contentsOf: requestURL, encoding: .utf8), !request.isEmpty
        else { return }
        requestModificationDate = modification
        pendingRequest = request
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
        transitionScene: String? = nil, transitionSource: String? = nil,
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
            assets: frame?.assets ?? previousFrame?.assets ?? [], frame: frame.map(frameHash) ?? "",
            isStable: frame?.isStable ?? false, isPaused: frame?.isPaused ?? false, request: request,
            exceptionBasis: exceptionBasis,
            transitionScene: transitionScene ?? frame?.transitionScene ?? previousFrame?.transitionScene ?? "",
            transitionSource: transitionSource ?? frame?.transitionSource ?? previousFrame?.transitionSource ?? "",
            heldTargetScene: frame?.heldTargetScene ?? "")
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
        guard isEnabled else { return }
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
        if !pendingRequest.isEmpty, pendingRequest != lastRequest {
            let request = pendingRequest
            lastRequest = request
            record(request.hasPrefix("clock-") ? "clockHandshake" : "checkpoint", frame: frame, request: request)
        }
    }
}

extension SlideShowViewModel {
    func lifecycleTimelineFrame(
        _ snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> PlaybackLifecycleTimeline.Frame {
        let recorder = PlaybackLifecycleTimeline.shared
        guard recorder.isEnabled else {
            return PlaybackLifecycleTimeline.Frame(
                scene: "", assets: [], fingerprint: [], isStable: false, isPaused: false, outgoingOpacity: nil,
                transitionScene: "", transitionSource: "", heldTargetScene: "")
        }
        let visible = snapshot.layers.filter { $0.opacity > 0 }
        let transition = playbackSession.lifecycleTimelineTransitionForTesting
        // During a raise, its marked foreground layer is the exception's subject even before it dominates opacity.
        let primary =
            visible.first(where: { $0.identity == transition.raisedIdentity })
            ?? visible.max(by: { $0.opacity < $1.opacity }) ?? snapshot.layers.first
        let scene = primary.map { PlaybackLifecycleTimeline.sceneKey($0.identity) } ?? ""
        let assets = recorder.cachedAssets(scene: scene) {
            primary.flatMap { self.scene(for: $0) }?.photoSlots.map { $0.asset.id } ?? []
        }
        let isStable =
            visible.count == 1 && visible[0].opacity == 1 && visible[0].isPresentationReady
            && recorder.areAllSlotsDecoded(scene: scene, assets: assets)
        let fingerprint = visible.map {
            PlaybackLifecycleTimeline.LayerSample(
                scene: PlaybackLifecycleTimeline.sceneKey($0.identity), opacity: $0.opacity,
                motionActiveTime: $0.motionActiveTime)
        }
        let transitionScene = transition.identity.map(PlaybackLifecycleTimeline.sceneKey) ?? ""
        return PlaybackLifecycleTimeline.Frame(
            scene: scene, assets: assets, fingerprint: fingerprint,
            isStable: isStable, isPaused: snapshot.suspensionReasons.contains(.userPaused),
            outgoingOpacity: snapshot.layers.filter { $0.role == .outgoing && $0.opacity > 0 }.map(\.opacity).max(),
            transitionScene: transitionScene, transitionSource: transition.source,
            heldTargetScene: transition.isHeld ? transitionScene : "")
    }
}
#endif
