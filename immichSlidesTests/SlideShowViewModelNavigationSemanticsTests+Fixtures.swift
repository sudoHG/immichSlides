import Foundation
import Testing
@testable import immichSlides

extension SlideShowViewModelNavigationSemanticsTests {
    func makeSmartFillViewModel() -> SlideShowViewModel {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: iPadLandscapePlanningPixelSize,
                profile: .iPad,
                orientation: .landscape
            )
        )
        let initialAssets = (0..<6).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)
        completeCurrentScenePresentation(vm)
        return vm
    }

    func expectHistory(_ vm: SlideShowViewModel, assetIds: [String], cursor: Int) throws {
        let data = Data(vm.playbackHistoryLedgerDiagnosticsSummaryJSON.utf8)
        let history = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(history["suffixPrimaryAssetIds"] as? [String] == assetIds)
        #expect(history["entryCount"] as? Int == assetIds.count)
        #expect(history["cursor"] as? Int == cursor)
    }

    func completeCurrentScenePresentation(_ vm: SlideShowViewModel) {
        var snapshot = vm.sceneRenderSnapshot
        guard let targetLayer = snapshot.layers.last(where: { $0.role == .incoming || $0.role == .stable }),
            let scene = vm.scene(for: targetLayer)
        else {
            return
        }

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

        snapshot = vm.sceneRenderSnapshot
        if snapshot.phase == .transition,
            snapshot.layers.last(where: { $0.role == .incoming })?.isPresentationReady == false,
            let transitionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        {
            vm.scenePresentationTimestampProviderForTesting = { transitionDeadline }
            snapshot = vm.sceneRenderSnapshot
        }

        guard
            let visibleLayer = snapshot.layers.last(where: {
                ($0.role == .incoming || $0.role == .stable) && $0.isPresentationReady
            })
        else {
            return
        }
        if visibleLayer.role == .incoming {
            let visibleTime =
                (visibleLayer.fadeStartTime ?? 0) + SceneTransitionDiagnostic.firstVisibleTickOffsetSeconds
            vm.scenePresentationTimestampProviderForTesting = { visibleTime }
        }
        snapshot = vm.sceneRenderSnapshot
        guard let displayedLayer = snapshot.layers.last(where: { $0.identity == visibleLayer.identity }) else {
            return
        }
        // As with the scene-root reporter, a paused first photo that goes straight to stable must still pass one
        // visible tick.
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
        if reporter.transactionCompleted(candidate: candidate),
            let identity = reporter.consumeDisplayTick(currentCandidate: candidate)
        {
            vm.incomingBecameVisible(identity)
        }
        if visibleLayer.role == .incoming,
            let completionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        {
            vm.scenePresentationTimestampProviderForTesting = { completionDeadline }
        }
    }

    func failSceneRendererThroughRetryBudget(
        layer: PlaybackSessionEngine.SceneRenderLayer,
        viewModel vm: SlideShowViewModel
    ) {
        guard let scene = vm.scene(for: layer),
            let slot = scene.photoSlots.first
        else {
            return
        }
        for _ in 0...SceneLifecycleContract.retryLimit {
            let rendererIdentity = SceneRendererIdentity(
                generation: layer.identity.generation,
                attemptID: vm.scenePresentationRendererAttemptID(for: layer),
                sceneID: layer.identity.sceneID,
                slotID: slot.id,
                assetID: slot.asset.id
            )
            vm.rendererFailed(rendererIdentity)
        }
    }

    // Sleep-polling instead of a yield budget: 10k yields last ~0.3s and starve the detached planner.
    func waitUntilForTesting(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        await waitUntil(pollInterval: .milliseconds(2), condition)
    }

    func assertLatency(
        _ readback: PlaybackSmartFillSceneReadback?,
        actionTimestamp: TimeInterval,
        scenePublishTimestamp: TimeInterval,
        latencyMilliseconds: Double
    ) {
        #expect(readback?.actionTimestamp == actionTimestamp)
        #expect(readback?.scenePublishTimestamp == scenePublishTimestamp)
        #expect(
            abs((readback?.actionToSceneLatencyMilliseconds ?? -1) - latencyMilliseconds) < latencyToleranceMilliseconds
        )
        #expect(readback?.qaDebugSummary.contains("actionTimestamp=\(format(actionTimestamp))") == true)
        #expect(readback?.qaDebugSummary.contains("scenePublishTimestamp=\(format(scenePublishTimestamp))") == true)
        #expect(readback?.qaDebugSummary.contains("actionToSceneLatencyMs=\(format(latencyMilliseconds))") == true)
    }

    func assertPublishTimingRecorded(
        _ readback: PlaybackSmartFillSceneReadback?,
        actionTimestamp: TimeInterval
    ) {
        #expect(readback?.actionTimestamp == actionTimestamp)
        #expect((readback?.scenePublishTimestamp ?? -1) >= actionTimestamp)
        #expect((readback?.actionToSceneLatencyMilliseconds ?? -1) >= 0)
        #expect(readback?.qaDebugSummary.contains("actionTimestamp=\(format(actionTimestamp))") == true)
        #expect(readback?.qaDebugSummary.contains("scenePublishTimestamp=") == true)
        #expect(readback?.qaDebugSummary.contains("actionToSceneLatencyMs=") == true)
    }

    func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    func parseSummaryFields(_ summary: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: summary.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                return (
                    String(part[..<equalIndex]),
                    String(part[part.index(after: equalIndex)...])
                )
            }
        )
    }

    func parsePhaseMap(_ raw: String) -> [String: Double] {
        raw.split(separator: ",").reduce(into: [String: Double]()) { result, part in
            let entry = String(part)
            guard let separatorIndex = entry.firstIndex(of: ":"),
                let value = Double(entry[entry.index(after: separatorIndex)...])
            else {
                return
            }
            result[String(entry[..<separatorIndex])] = value
        }
    }

    struct PlaybackHistoryMemoryEstimate {
        let entryCount: Int
        let rawBytes: Int
        let conservativeBytes: Int
    }

    func estimatePlaybackHistoryLedgerMemory(_ ledger: PlaybackHistoryLedger) -> PlaybackHistoryMemoryEstimate {
        let rawBytes =
            MemoryLayout<PlaybackHistoryLedger>.stride
            + arrayStorageBytes(
                count: ledger.entries.count, elementStride: MemoryLayout<PlaybackHistoryLedgerEntry>.stride)
            + ledger.entries.reduce(0) { partial, entry in
                partial + estimateSceneStorage(entry.scene)
            }
        // The memory estimate leaves headroom for Array/String capacity and CoW so it is not too tight.
        let conservativeBytes = rawBytes * conservativeMemoryHeadroomFactor
        return PlaybackHistoryMemoryEstimate(
            entryCount: ledger.entries.count,
            rawBytes: rawBytes,
            conservativeBytes: conservativeBytes
        )
    }

    func estimateSceneStorage(_ scene: PlaybackScene) -> Int {
        stringStorageBytes(scene.id)
            + arrayStorageBytes(count: scene.photoSlots.count, elementStride: MemoryLayout<PhotoSlot>.stride)
            + scene.photoSlots.reduce(0) { partial, slot in
                partial
                    + stringStorageBytes(slot.id)
                    + estimateAssetStorage(slot.asset)
                    + estimatePlanningStorage(slot.planning)
            }
            + estimateProtectionStorage(scene.protectionSnapshot)
            + estimateReadbackStorage(scene.smartFillReadback)
    }

    func estimateAssetStorage(_ asset: Asset) -> Int {
        stringStorageBytes(asset.id)
            + stringStorageBytes(asset.type)
            + optionalStringStorageBytes(asset.livePhotoVideoID)
            + optionalStringStorageBytes(asset.thumbhash)
            + estimateExifStorage(asset.exifInfo)
            + arrayStorageBytes(count: asset.tags?.count ?? 0, elementStride: MemoryLayout<String>.stride)
            + (asset.tags ?? []).reduce(0) { $0 + stringStorageBytes($1) }
            + arrayStorageBytes(count: asset.people?.count ?? 0, elementStride: MemoryLayout<People>.stride)
            + (asset.people ?? []).reduce(0) { $0 + estimatePeopleStorage($1) }
            + arrayStorageBytes(
                count: asset.unassignedFaces?.count ?? 0, elementStride: MemoryLayout<UnassignedFace>.stride)
            + (asset.unassignedFaces ?? []).reduce(0) { $0 + stringStorageBytes($1.id) }
    }

    func estimateExifStorage(_ exif: ExifInfo?) -> Int {
        guard let exif else { return 0 }
        return MemoryLayout<ExifInfo>.stride
            + optionalStringStorageBytes(exif.make)
            + optionalStringStorageBytes(exif.model)
            + optionalStringStorageBytes(exif.dateTimeOriginal)
            + optionalStringStorageBytes(exif.timeZone)
            + optionalStringStorageBytes(exif.lensModel)
            + optionalStringStorageBytes(exif.exposureTime)
            + optionalStringStorageBytes(exif.city)
            + optionalStringStorageBytes(exif.state)
            + optionalStringStorageBytes(exif.country)
            + optionalStringStorageBytes(exif.orientation)
    }

    func estimatePeopleStorage(_ person: People) -> Int {
        stringStorageBytes(person.id)
            + stringStorageBytes(person.name)
            + arrayStorageBytes(count: person.faces?.count ?? 0, elementStride: MemoryLayout<FaceBox>.stride)
            + (person.faces ?? []).reduce(0) { partial, face in
                partial
                    + optionalStringStorageBytes(face.id)
                    + optionalStringStorageBytes(face.sourceType)
            }
    }

    func estimatePlanningStorage(_ planning: PlaybackPlanningSnapshot) -> Int {
        stringStorageBytes(planning.version)
            + stringStorageBytes(planning.sourceImage.orientation)
            + arrayStorageBytes(
                count: planning.fallbackReasons.count,
                elementStride: MemoryLayout<PlaybackPlanningFallbackReason>.stride)
            + stringStorageBytes(planning.qaDebugSummary)
    }

    func estimateProtectionStorage(_ snapshot: PlaybackProtectionSnapshot) -> Int {
        stringStorageBytes(snapshot.version)
            + stringStorageBytes(snapshot.qaDebugSummary)
            + arrayStorageBytes(
                count: snapshot.regions.count, elementStride: MemoryLayout<PlaybackProtectionRegion>.stride)
    }

    func estimateReadbackStorage(_ readback: PlaybackSmartFillSceneReadback?) -> Int {
        guard let readback else { return 0 }
        return stringStorageBytes(readback.version)
            + stringStorageBytes(readback.layoutPolicyId)
            + stringStorageBytes(readback.surfaceKey)
            + stringStorageBytes(readback.ratioPreset)
            + stringStorageBytes(readback.rotationStartRatioPreset)
            + stringStorageBytes(readback.acceptedRatioPreset)
            + stringStorageBytes(readback.rotationKeyHashPrefix)
            + stringStorageBytes(readback.qaDebugSummary)
            + arrayStorageBytes(
                count: readback.slotRoles.count, elementStride: MemoryLayout<PlaybackSmartFillSlotRole>.stride)
            + arrayStorageBytes(
                count: readback.rejectedLayoutReasonTopList.count,
                elementStride: MemoryLayout<PlaybackSmartFillPlannerRejectReason>.stride)
            + arrayStorageBytes(count: readback.reasonCodes.count, elementStride: MemoryLayout<String>.stride)
            + readback.reasonCodes.reduce(0) { $0 + stringStorageBytes($1) }
    }

    func stringStorageBytes(_ value: String) -> Int {
        estimatedStringStorageOverheadBytes + value.utf8.count
    }

    func optionalStringStorageBytes(_ value: String?) -> Int {
        value.map(stringStorageBytes) ?? 0
    }

    func arrayStorageBytes(count: Int, elementStride: Int) -> Int {
        guard count > 0 else { return 0 }
        return estimatedArrayStorageOverheadBytes + (count * elementStride)
    }

    func formatMiB(_ bytes: Int) -> String {
        String(format: "%.3f", Double(bytes) / bytesPerMiB)
    }

    func makeEstimatedHistoryScene(index: Int, slotCount: Int) -> PlaybackScene {
        let slots = (0..<slotCount).map { slotIndex in
            let asset = makeRichAsset(id: "asset-\(index)-\(slotIndex)", width: 6000, height: 4000)
            return PhotoSlot(
                id: "slot-\(index)-\(slotIndex)-\(asset.id)",
                asset: asset,
                planning: makeEstimatedPlanning(index: index, slotIndex: slotIndex, slotCount: slotCount)
            )
        }
        return PlaybackScene(
            id: "scene-estimate-\(index)",
            photoSlots: slots,
            smartFillReadback: makeEstimatedReadback(index: index, slotCount: slotCount)
        )
    }

    func makeEstimatedPlanning(
        index: Int,
        slotIndex: Int,
        slotCount: Int
    ) -> PlaybackPlanningSnapshot {
        PlaybackPlanningSnapshot(
            version: "smart-fill-planner-v2",
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: PlaybackPlanningPixelSize(width: 6000, height: 4000),
                exifPixelSize: PlaybackPlanningPixelSize(width: 6000, height: 4000),
                orientation: "available"
            ),
            displayFrame: PlaybackPlanningRect(
                x: slotCount == 1 ? 0 : Double(slotIndex) * 0.5,
                y: 0,
                width: slotCount == 1 ? 1 : 0.5,
                height: 1
            ),
            cropRect: PlaybackPlanningRect(x: 0, y: 0.04, width: 1, height: 0.92),
            qualityDecision: .smartFillAccepted,
            faceProtection: .accepted,
            fallbackReasons: [],
            qaDebugSummary:
                "version=smart-fill-planner-v2;sceneType=\(slotCount == 1 ? "single" : "double");surfaceKey=appleTV-landscape-tv-regular-safeTV;slotRef=asset_\(index)_\(slotIndex);display=x0.000y0.000w0.500h1.000;crop=x0.000y0.040w1.000h0.920;cropRetention=0.920;protectionContained=true;candidateWindowUsed=24;evaluationCount=2;fallback=none"
        )
    }

    func makeEstimatedReadback(index: Int, slotCount: Int) -> PlaybackSmartFillSceneReadback {
        PlaybackSmartFillSceneReadback(
            version: "smart-fill-planner-v2",
            sceneType: slotCount == 1 ? .single : .double,
            layoutPolicyId: "appletv-landscape-pr49-v1",
            surfaceKey: "appleTV-landscape-tv-regular-safeTV|size:55x32|aspect:35",
            layoutVariant: slotCount == 1 ? .single : .horizontalEqual,
            ratioPreset: slotCount == 1 ? "full" : "50/50",
            slotRoles: slotCount == 1 ? [.primary] : [.primary, .secondary],
            fallbackReason: nil,
            candidateWindowUsed: 24,
            evaluationCount: 2,
            rotationStartLayoutVariant: slotCount == 1 ? .single : .rightPrimaryLeftSecondary,
            rotationStartRatioPreset: slotCount == 1 ? "full" : "55/45",
            acceptedLayoutVariant: slotCount == 1 ? .single : .horizontalEqual,
            acceptedRatioPreset: slotCount == 1 ? "full" : "50/50",
            rotationKeyHashPrefix: "5b8a52baf191",
            rejectedLayoutReasonTopList: [.cropRetentionTooLow, .verticalDoubleDisallowedOnSurface],
            reasonCodes: ["accepted", "crop-retention-too-low", "vertical-double-disallowed-on-surface"],
            qaDebugSummary:
                "version=smart-fill-planner-v2;sceneType=\(slotCount == 1 ? "single" : "double");surfaceKey=appleTV-landscape-tv-regular-safeTV;layoutVariant=\(slotCount == 1 ? PlaybackSmartFillLayoutVariant.single.rawValue : PlaybackSmartFillLayoutVariant.horizontalEqual.rawValue);ratioPreset=\(slotCount == 1 ? "full" : "50/50");slotRefs=asset_\(index)_0\(slotCount == 2 ? ",asset_\(index)_1" : "");ledgerSceneAssets=asset-\(index)-0\(slotCount == 2 ? ",asset-\(index)-1" : "");candidateWindowUsed=24;evaluationCount=2;fallback=none;rejects=vertical-double-disallowed-on-surface,crop-retention-too-low"
        )
    }

    func makeRichAsset(id: String, width: Int, height: Int) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: ExifInfo(
                make: "Canon",
                model: "EOS 5D Mark III",
                dateTimeOriginal: "2025-04-14T10:20:30",
                timeZone: "Asia/Shanghai",
                lensModel: "EF35mm f/1.4L II USM",
                fNumber: 4.0,
                focalLength: 35,
                iso: 320,
                exposureTime: "1/125",
                latitude: 31.2304,
                longitude: 121.4737,
                city: "Shanghai",
                state: "Shanghai",
                country: "China",
                rating: 5,
                exifImageWidth: width,
                exifImageHeight: height,
                orientation: "1"
            ),
            people: [
                People(
                    id: "person-\(id)-0",
                    name: "Person \(id)",
                    isHidden: false,
                    isFavorite: false,
                    faces: [
                        FaceBox(
                            id: "face-\(id)-0",
                            boundingBoxX1: 120,
                            boundingBoxX2: 360,
                            boundingBoxY1: 240,
                            boundingBoxY2: 520,
                            imageWidth: width,
                            imageHeight: height,
                            sourceType: "machine-learning"
                        )
                    ]
                )
            ],
            tags: ["travel", "family", "featured"],
            livePhotoVideoID: nil,
            width: width,
            height: height,
            thumbhash: "1QcSHQRnh493V4dIh4eXh1h4kJUI",
            unassignedFaces: [UnassignedFace(id: "unassigned-\(id)-0")]
        )
    }

    func markReady(_ assets: [Asset], in manager: AssetsDownloadManager) {
        for asset in assets {
            manager.assetStates[asset.id] = .readyToPlay
            manager.assetPreviewStates[asset.id] = .readyToPlay
        }
    }

    func markReady(assetId: String, size: ThumbnailSize, in manager: AssetsDownloadManager) {
        switch size {
        case .fullsize:
            manager.assetStates[assetId] = .readyToPlay
        case .preview:
            manager.assetPreviewStates[assetId] = .readyToPlay
        case .thumbnail:
            manager.assetThumbnailStates[assetId] = .readyToPlay
        }
    }

    func makeAsset(id: String, width: Int, height: Int) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil,
            width: width,
            height: height
        )
    }

    func resetDownloadManagerState(_ manager: AssetsDownloadManager) {
        manager.assetStates = [:]
        manager.assetPreviewStates = [:]
        manager.assetThumbnailStates = [:]
        manager.assetURLs = [:]
        manager.assetPreviewURLs = [:]
        manager.assetThumbnailURLs = [:]
    }
}
