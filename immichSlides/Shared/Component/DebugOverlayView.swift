import SwiftUI
import SDWebImage

struct PlaybackDebugOverlaySceneSummary {
    let lines: [String]

    init(scene: PlaybackScene?) {
        guard let scene else {
            lines = ["Scene missing renderer none fallback missing"]
            return
        }

        let readback = scene.smartFillReadback
        let sceneLabel = readback?.sceneType.rawValue ?? "legacy"
        let rendererLabel = readback == nil || readback?.sceneType == .fallback ? "legacy" : "smartFill"
        let fallbackReason = readback?.fallbackReason?.rawValue ?? (readback == nil ? "legacy" : "none")
        let fallbackCategory = readback?.fallbackCategory.rawValue ?? (readback == nil ? "legacy" : "none")
        var result = [
            "Scene \(sceneLabel) renderer \(rendererLabel) fallback \(fallbackReason)/\(fallbackCategory)"
        ]

        result += scene.photoSlots.enumerated().map { index, slot in
            let role = Self.roleLabel(at: index, readback: readback)
            return [
                "slot \(role) \(slot.asset.id)",
                "frame \(slot.planning.displayFrame.debugOverlayLabel)",
                "crop \(slot.planning.cropRect.debugOverlayLabel)",
                "retention \(Self.cropRetentionLabel(for: slot.planning))"
            ].joined(separator: " ")
        }
        lines = result
    }

    private static func roleLabel(
        at index: Int,
        readback: PlaybackSmartFillSceneReadback?
    ) -> String {
        guard let roles = readback?.slotRoles,
            index < roles.count
        else {
            return index == 0 ? "primary" : "slot\(index)"
        }
        return roles[index].rawValue
    }

    private static func cropRetentionLabel(for planning: PlaybackPlanningSnapshot) -> String {
        let crop = planning.cropRect
        return String(format: "%.3f", crop.width * crop.height)
    }
}

// The DEBUG panel also runs in English environments, so its text must be localized; it sits bottom-left so it
// does not cover the main photo.

struct DebugOverlayView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @ObservedObject var viewModel: SlideShowViewModel
    @ObservedObject var downloadManager: AssetsDownloadManager

    let renderCount: Int

    var bottomPadding: CGFloat = 12

    var fontSize: CGFloat = 15
    private var layout: ViewLayoutTraits {
        ViewLayoutTraits(
            horizontalSizeClass: nil,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }
    private var isPhone: Bool { layout.isPhone }
    private var isCompactHeight: Bool { layout.isCompactHeight }
    private var panelFontSize: CGFloat { isPhone ? (isCompactHeight ? 11 : 12) : fontSize }
    private var panelPadding: CGFloat { isPhone ? (isCompactHeight ? 7 : 8) : 10 }
    private var panelCornerRadius: CGFloat { isPhone ? 6 : 8 }
    private var panelMaxWidth: CGFloat { isPhone ? (isCompactHeight ? 360 : 420) : 1180 }
    private var panelLineLimit: Int { isPhone ? (isCompactHeight ? 11 : 13) : 18 }

    var body: some View {

        VStack {
            Spacer()
            HStack {
                Text(debugText)
                    .font(.system(size: panelFontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(panelLineLimit)
                    .minimumScaleFactor(0.65)
                    .padding(panelPadding)
                    .background(.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius))
                    .frame(maxWidth: panelMaxWidth, alignment: .leading)
                Spacer()
            }
            .padding(.leading, isPhone ? 10 : 16)
            .padding(.bottom, bottomPadding)
        }
        .accessibilityIdentifier("slideshow.debugOverlay")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(debugText))
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        .allowsHitTesting(false)
    }

    private var debugText: String {
        guard !viewModel.assets.isEmpty else {
            return String(localized: "⚠️ No assets")
        }
        guard let currentScene = viewModel.safeCurrentScene,
            let currentAsset = currentScene.primaryAsset
        else {
            return LocalizedText.format("❌ Current index out of bounds: %lld", Int64(viewModel.currentIndex))
        }

        let total = viewModel.assets.count
        let currentFull = stateText(downloadManager.assetStates[currentAsset.id])
        let currentPreview = stateText(downloadManager.assetPreviewStates[currentAsset.id])
        let currentPeopleCount = currentAsset.people?.count ?? 0
        let currentUnassignedFacesCount = currentAsset.unassignedFaces?.count ?? 0
        let currentPeopleNames = peopleNamesText(currentAsset.people ?? [])

        // With SmartFill, scenes no longer map one-to-one to the raw asset pool, so they are listed separately to
        // avoid misreading when tracing photos.
        let currentSceneLines = PlaybackDebugOverlaySceneSummary(scene: currentScene).lines
        let targetSceneLines = targetSceneDebugLines()
        let nextIndex = (viewModel.currentIndex + 1) < total ? (viewModel.currentIndex + 1) : 0
        let nextAsset = viewModel.assets[nextIndex]
        let nextFull = stateText(downloadManager.assetStates[nextAsset.id])
        let nextPreview = stateText(downloadManager.assetPreviewStates[nextAsset.id])

        let tasks = downloadManager.activeTaskCount
        let diskBytes = SDImageCache.shared.totalDiskSize()
        let diskCount = SDImageCache.shared.totalDiskCount()
        let speed = downloadSpeedText(
            bytes: downloadManager.lastDownloadBytes,
            duration: downloadManager.lastDownloadDuration,
            cacheHit: downloadManager.lastDownloadWasCacheHit
        )

        var lines = [
            progressLine(
                currentIndex: viewModel.currentIndex,
                total: total,
                targetIndex: viewModel.targetIndex,
                isAutoPlay: viewModel.isAutoPlay
            ),
            currentAssetLine(
                id: currentAsset.id,
                fullState: currentFull,
                previewState: currentPreview
            )
        ]
        lines += currentSceneLines
        lines += [
            peopleLine(
                taggedCount: currentPeopleCount,
                peopleNames: currentPeopleNames,
                untaggedCount: currentUnassignedFacesCount
            ),
            visionLine(state: viewModel.visionFaceAuditState)
        ]
        lines += targetSceneLines
        lines += [
            nextAssetLine(
                nextIndex: nextIndex,
                id: nextAsset.id,
                fullState: nextFull,
                previewState: nextPreview
            ),
            renderLine(
                renderCount: renderCount,
                preloadCount: viewModel.preloadCount
            ),
            taskLine(
                tasks: tasks,
                cacheSize: formatBytes(diskBytes),
                cacheCount: diskCount,
                speed: speed
            )
        ]
        return lines.joined(separator: "\n")
    }

    private func stateText(_ state: AssetStates?) -> String {
        switch state {
        case .readyToPlay:
            return String(localized: "Ready")
        case .loadingURL:
            return String(localized: "Fetch URL")
        case .urlReady:
            return String(localized: "URL OK")
        case .downloading:
            return String(localized: "Downloading")
        case .failed:
            return String(localized: "URL failed")
        case .failedToDownload:
            return String(localized: "Download failed")
        case .notStarted:
            return String(localized: "Not started")
        case .downloaded:
            return String(localized: "Done")
        case .none:
            return "-"
        }
    }

    private func autoPlayText(_ isEnabled: Bool) -> String {
        isEnabled ? String(localized: "On") : String(localized: "Off")
    }

    private func progressLine(
        currentIndex: Int,
        total: Int,
        targetIndex: Int,
        isAutoPlay: Bool
    ) -> String {
        LocalizedText.format(
            "Current %lld/%lld  Target %lld  Auto %@",
            Int64(currentIndex),
            Int64(total - 1),
            Int64(targetIndex),
            autoPlayText(isAutoPlay)
        )
    }

    private func currentAssetLine(
        id: String,
        fullState: String,
        previewState: String
    ) -> String {
        LocalizedText.format("Current asset %@  Full: %@  Preview: %@", id, fullState, previewState)
    }

    private func peopleLine(
        taggedCount: Int,
        peopleNames: String,
        untaggedCount: Int
    ) -> String {
        LocalizedText.format(
            "People tagged: %lld (%@)  Untagged: %lld",
            Int64(taggedCount),
            peopleNames,
            Int64(untaggedCount)
        )
    }

    private func nextAssetLine(
        nextIndex: Int,
        id: String,
        fullState: String,
        previewState: String
    ) -> String {
        LocalizedText.format(
            "RawNext %lld %@  前景：%@  预览：%@",
            Int64(nextIndex),
            id,
            fullState,
            previewState
        )
    }

    private func targetSceneDebugLines() -> [String] {
        guard viewModel.targetIndex != viewModel.currentIndex,
            let targetScene = viewModel.scene(at: viewModel.targetIndex)
        else {
            return []
        }
        return PlaybackDebugOverlaySceneSummary(scene: targetScene).lines.map { "Target \($0)" }
    }

    // Vision face counting only shows the current state and duration, not full diagnostics.

    private func visionLine(state: VisionFaceAuditState) -> String {
        switch state {
        case .idle:
            return "Vision -"
        case .waitingForImage:
            return "Vision wait-image"
        case .running:
            return "Vision running"
        case .finished(let result):
            return LocalizedText.format(
                "Vision n=%lld %@ %lldms",
                Int64(result.faceCount),
                result.imageSource.rawValue,
                Int64(result.elapsedMilliseconds)
            )
        case .failed(let reason):
            return LocalizedText.format("Vision err %@", reason)
        }
    }

    private func renderLine(renderCount: Int, preloadCount: Int) -> String {
        LocalizedText.format("Render window %lld  Preload %lld", Int64(renderCount), Int64(preloadCount))
    }

    private func taskLine(tasks: Int, cacheSize: String, cacheCount: UInt, speed: String) -> String {
        LocalizedText.format(
            "Tasks %lld  Cache %@(%llu)  Rate %@",
            Int64(tasks),
            cacheSize,
            cacheCount,
            speed
        )
    }

    // List at most 4 person names so the panel does not get too long.
    private func peopleNamesText(_ people: [People]) -> String {
        guard !people.isEmpty else { return "-" }
        let names = people.map { person in
            let trimmed = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "Unnamed") : trimmed
        }
        let limit = 4
        if names.count <= limit {
            return names.joined(separator: ",")
        } else {
            let head = names.prefix(limit).joined(separator: ",")
            return "\(head)..."
        }
    }

    private func formatBytes(_ bytes: UInt) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1fKB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1fMB", mb) }
        let gb = mb / 1024.0
        return String(format: "%.2fGB", gb)
    }

    // Estimate the rate from disk bytes / duration; a cache hit is not reported as a download speed.
    private func downloadSpeedText(bytes: UInt, duration: TimeInterval?, cacheHit: Bool) -> String {
        if cacheHit { return String(localized: "Cache hit") }
        guard let duration, duration > 0 else { return "-" }
        let mb = Double(bytes) / 1024.0 / 1024.0
        let speed = mb / duration
        if mb == 0 { return String(format: "%.2fs", duration) }
        return String(format: "%.2fMB/s", speed)
    }
}

private extension PlaybackPlanningRect {
    var debugOverlayLabel: String {
        "x\(formatted(x))y\(formatted(y))w\(formatted(width))h\(formatted(height))"
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
