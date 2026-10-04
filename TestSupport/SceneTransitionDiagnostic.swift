import Foundation

/// Judges the contract probe around one manual Next: the old photo stays on screen until the new one has crossfaded
/// in, and its motion follows playback (moving while playing, still while paused).
enum SceneTransitionDiagnostic {
    struct Sample {
        let phase: String
        let roles: [String]
        /// Hashed layer identities, one per role, so the diagnostic can tell the old photo from the new one.
        let ids: [String]
        let opacities: [Double]
        let progress: [Double]
    }

    /// What the app recorded frame by frame about the last crossfade, so a crossfade shorter than the sampling
    /// interval is still judged.
    struct CrossfadeEvidence {
        /// Crossfade frames drawn between the probe read before Next and the last sample.
        let frameCount: Int
        let outgoingID: String
        let incomingID: String
        let firstOutgoingProgress: Double
        let lastOutgoingProgress: Double
        let lowestOutgoingProgress: Double
        let highestOutgoingProgress: Double
        /// Largest share of the screen both photos showed at once, the outgoing photo drawn below the incoming one.
        let peakBlendOpacity: Double
        /// A later frame showed the outgoing photo's motion behind an earlier one.
        let didOutgoingProgressRewind: Bool
    }

    enum Verdict: String, Codable {
        /// Playing: the old photo kept moving while it faded out.
        case outgoingAdvanced
        /// Paused: the old photo stayed on its paused frame while it faded out.
        case outgoingHeldStill
        case invalid
    }

    /// Share of the screen that photo layers must cover in every sample; below it the screen reads as empty.
    static let minimumPhotoCoverage = 0.5
    /// Both photos must show at least this share at once in some frame. A linear crossfade peaks near 0.38 and stays
    /// above it for over half of its frames; a hard switch, or an opaque photo cut in on top, stays at 0.
    static let minimumBlendOpacity = 0.1
    private static let progressTolerance = 0.000_1

    /// Share of the screen covered when the layers are composited over the black backing.
    static func photoCoverage(of opacities: [Double]) -> Double {
        1 - opacities.reduce(1) { uncovered, opacity in uncovered * (1 - opacity) }
    }

    /// `before` is read just before Next and must show a settled photo. `samples` run from the press until the new photo
    /// has settled. Any loading or incoming-only sample means the old photo was dropped first, which is a failure.
    static func evaluate(
        before: Sample,
        after samples: [Sample],
        crossfade: CrossfadeEvidence?,
        isPlaybackPaused: Bool
    ) -> Verdict {
        let oldPhoto = before.ids.first ?? ""
        guard isSettledPhoto(before), let final = samples.last, isSettledPhoto(final),
            samples.allSatisfy(isWellFormed),
            samples.allSatisfy({ photoCoverage(of: $0.opacities) >= minimumPhotoCoverage }),
            let crossfade, crossfade.frameCount > 0, crossfade.outgoingID == oldPhoto,
            crossfade.incomingID != oldPhoto, final.ids == [crossfade.incomingID],
            crossfade.peakBlendOpacity >= minimumBlendOpacity,
            [
                crossfade.firstOutgoingProgress, crossfade.lastOutgoingProgress, crossfade.lowestOutgoingProgress,
                crossfade.highestOutgoingProgress
            ].allSatisfy(\.isFinite)
        else { return .invalid }

        let newPhoto = crossfade.incomingID
        // Phases only move forward: old photo, old photo held over the hidden target, crossfade, new photo.
        var stage = 0
        var oldPhotoProgress = [before.progress[0]]
        var sampledCrossfadeProgress: [Double] = []
        var previousCrossfade: (outgoing: Double, incoming: Double)?
        for sample in samples {
            switch sample.phase {
            case "stablePhoto" where sample.roles == ["stable"] && sample.opacities == [1]:
                if sample.ids == [oldPhoto], stage == 0 {
                    oldPhotoProgress.append(sample.progress[0])
                } else if sample.ids == [newPhoto] {
                    stage = 3
                } else {
                    return .invalid
                }
            case "grace" where stage <= 1:
                guard sample.roles == ["stable", "incoming"], sample.opacities == [1, 0],
                    sample.ids == [oldPhoto, newPhoto]
                else { return .invalid }
                stage = 1
                oldPhotoProgress.append(sample.progress[0])
            case "transition" where stage <= 2:
                guard Set(sample.roles) == Set(["outgoing", "incoming"]),
                    let outgoing = sample.roles.firstIndex(of: "outgoing"),
                    let incoming = sample.roles.firstIndex(of: "incoming"),
                    sample.ids[outgoing] == oldPhoto, sample.ids[incoming] == newPhoto
                else { return .invalid }
                let opacities = (outgoing: sample.opacities[outgoing], incoming: sample.opacities[incoming])
                if let previousCrossfade,
                    opacities.outgoing > previousCrossfade.outgoing || opacities.incoming < previousCrossfade.incoming
                {
                    return .invalid
                }
                previousCrossfade = opacities
                stage = 2
                sampledCrossfadeProgress.append(sample.progress[outgoing])
            default:
                return .invalid
            }
        }
        guard stage == 3 else { return .invalid }

        let baseline = before.progress[0]
        if isPlaybackPaused {
            let heldStill =
                !crossfade.didOutgoingProgressRewind
                && (oldPhotoProgress + sampledCrossfadeProgress + [
                    crossfade.firstOutgoingProgress, crossfade.lastOutgoingProgress,
                    crossfade.lowestOutgoingProgress, crossfade.highestOutgoingProgress
                ]).allSatisfy { abs($0 - baseline) <= progressTolerance }
            return heldStill ? .outgoingHeldStill : .invalid
        }
        let sampled = oldPhotoProgress + sampledCrossfadeProgress
        let neverRewinds = zip(sampled, sampled.dropFirst()).allSatisfy { $1 >= $0 - progressTolerance }
        let sampledCrossfadeMoves = zip(sampledCrossfadeProgress, sampledCrossfadeProgress.dropFirst())
            .allSatisfy { $1 > $0 + progressTolerance }
        // Frame by frame, the old photo must keep moving through the crossfade itself, from where it was last seen held.
        let lastHeldProgress = oldPhotoProgress.last ?? baseline
        let crossfadeMoves =
            !crossfade.didOutgoingProgressRewind
            && crossfade.firstOutgoingProgress >= lastHeldProgress - progressTolerance
            && crossfade.lastOutgoingProgress > crossfade.firstOutgoingProgress + progressTolerance
        return neverRewinds && sampledCrossfadeMoves && crossfadeMoves ? .outgoingAdvanced : .invalid
    }

    /// Reads the probe's `lastCrossfade` field:
    /// `<outgoing id>><incoming id>@<first>><last progress>@<lowest>><highest progress>@<peak blend>@<steady|rewound>`.
    static func crossfadeEvidence(lastCrossfade: String, frameCount: Int) -> CrossfadeEvidence? {
        let parts = lastCrossfade.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, ["steady", "rewound"].contains(parts[4]) else { return nil }
        let ids = parts[0].split(separator: ">").map(String.init)
        let progress = parts[1].split(separator: ">").compactMap { Double(String($0)) }
        let range = parts[2].split(separator: ">").compactMap { Double(String($0)) }
        guard ids.count == 2, progress.count == 2, range.count == 2, let blend = Double(parts[3]) else { return nil }
        return CrossfadeEvidence(
            frameCount: frameCount, outgoingID: ids[0], incomingID: ids[1],
            firstOutgoingProgress: progress[0], lastOutgoingProgress: progress[1],
            lowestOutgoingProgress: range[0], highestOutgoingProgress: range[1], peakBlendOpacity: blend,
            didOutgoingProgressRewind: parts[4] == "rewound")
    }

    private static func isSettledPhoto(_ sample: Sample) -> Bool {
        isWellFormed(sample) && sample.phase == "stablePhoto" && sample.roles == ["stable"] && sample.opacities == [1]
    }

    private static func isWellFormed(_ sample: Sample) -> Bool {
        !sample.roles.isEmpty && Set(sample.roles).count == sample.roles.count
            && Set(sample.ids).count == sample.ids.count && sample.roles.count == sample.ids.count
            && sample.roles.count == sample.opacities.count && sample.roles.count == sample.progress.count
            && sample.opacities.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && sample.progress.allSatisfy { $0.isFinite && $0 >= 0 }
    }
}
