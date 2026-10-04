import Foundation
import Testing

@Suite
struct SceneTransitionDiagnosticTests {
    private typealias Sample = SceneTransitionDiagnostic.Sample
    private typealias Evidence = SceneTransitionDiagnostic.CrossfadeEvidence

    private let settledOldPhoto = Sample(
        phase: "stablePhoto", roles: ["stable"], ids: ["old"], opacities: [1], progress: [0.2])
    private let settledNewPhoto = Sample(
        phase: "stablePhoto", roles: ["stable"], ids: ["new"], opacities: [1], progress: [0])
    private var stillCrossfade: Evidence { evidence(first: 0.2, last: 0.2) }
    private var movingCrossfade: Evidence { evidence(first: 0.22, last: 0.28) }

    /// Synthetic crossfade evidence; defaults to a real blend whose motion never went backwards.
    private func evidence(
        first: Double, last: Double, lowest: Double? = nil, highest: Double? = nil, frameCount: Int = 18,
        outgoingID: String = "old", incomingID: String = "new", peakBlend: Double = 0.38, rewound: Bool = false
    ) -> Evidence {
        Evidence(
            frameCount: frameCount, outgoingID: outgoingID, incomingID: incomingID, firstOutgoingProgress: first,
            lastOutgoingProgress: last, lowestOutgoingProgress: lowest ?? min(first, last),
            highestOutgoingProgress: highest ?? max(first, last), peakBlendOpacity: peakBlend,
            didOutgoingProgressRewind: rewound)
    }

    private func held(_ progress: Double) -> Sample {
        Sample(
            phase: "grace", roles: ["stable", "incoming"], ids: ["old", "new"], opacities: [1, 0],
            progress: [progress, 0.04])
    }

    private func crossfade(
        outgoing: Double, incoming: Double, progress: Double, ids: [String] = ["old", "new"]
    ) -> Sample {
        Sample(
            phase: "transition", roles: ["outgoing", "incoming"], ids: ids, opacities: [outgoing, incoming],
            progress: [progress, 0])
    }

    private func evaluate(
        _ samples: [Sample], crossfade: Evidence?, paused: Bool, before: Sample? = nil
    ) -> SceneTransitionDiagnostic.Verdict {
        SceneTransitionDiagnostic.evaluate(
            before: before ?? settledOldPhoto, after: samples, crossfade: crossfade, isPlaybackPaused: paused)
    }

    @Test
    func `a paused crossfade that holds the old frame still is accepted`() {
        let samples = [
            held(0.2),
            crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.2),
            crossfade(outgoing: 0.33, incoming: 0.67, progress: 0.2),
            settledNewPhoto
        ]
        #expect(evaluate(samples, crossfade: stillCrossfade, paused: true) == .outgoingHeldStill)
    }

    @Test
    func `a playing crossfade whose old photo keeps moving is accepted`() {
        let samples = [
            held(0.21),
            crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.23),
            crossfade(outgoing: 0.33, incoming: 0.67, progress: 0.26),
            settledNewPhoto
        ]
        #expect(evaluate(samples, crossfade: movingCrossfade, paused: false) == .outgoingAdvanced)
    }

    @Test
    func `a crossfade drawn between samples is judged from the frame record`() {
        let samples = [settledOldPhoto, held(0.2), settledNewPhoto]
        #expect(evaluate(samples, crossfade: stillCrossfade, paused: true) == .outgoingHeldStill)
        #expect(evaluate([settledNewPhoto], crossfade: stillCrossfade, paused: true) == .outgoingHeldStill)
    }

    @Test
    func `the old photo moving while paused or standing still while playing is rejected`() {
        let samples = [crossfade(outgoing: 0.5, incoming: 0.5, progress: 0.2), settledNewPhoto]
        let movingWhilePaused = evidence(first: 0.2, last: 0.25)
        #expect(evaluate(samples, crossfade: movingWhilePaused, paused: true) == .invalid)
        #expect(evaluate(samples, crossfade: stillCrossfade, paused: false) == .invalid)
    }

    @Test
    func `a playing old photo that moved while held but stopped during the crossfade is rejected`() {
        let stoppedFrames = evidence(first: 0.25, last: 0.25)
        let movedWhileHeld = [held(0.25), settledNewPhoto]
        #expect(evaluate(movedWhileHeld, crossfade: stoppedFrames, paused: false) == .invalid)

        let stoppedSamples = [
            crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.25),
            crossfade(outgoing: 0.33, incoming: 0.67, progress: 0.25),
            settledNewPhoto
        ]
        #expect(evaluate(stoppedSamples, crossfade: movingCrossfade, paused: false) == .invalid)
    }

    @Test
    func `dropping the old photo before the new one appears is rejected`() {
        let incomingOnly = [
            Sample(phase: "incomingFromLoading", roles: ["incoming"], ids: ["new"], opacities: [0.6], progress: [0]),
            Sample(phase: "incomingFromLoading", roles: ["incoming"], ids: ["new"], opacities: [0.9], progress: [0]),
            settledNewPhoto
        ]
        let loading =
            [Sample(phase: "loading", roles: ["incoming"], ids: ["new"], opacities: [0], progress: [0])] + incomingOnly
        for samples in [incomingOnly, loading] {
            #expect(evaluate(samples, crossfade: stillCrossfade, paused: true) == .invalid)
            #expect(evaluate(samples, crossfade: movingCrossfade, paused: false) == .invalid)
        }
    }

    @Test
    func `missing or mismatched crossfade records are rejected`() {
        let samples = [held(0.2), settledNewPhoto]
        let mismatched = [
            evidence(first: 0.2, last: 0.2, frameCount: 0),
            evidence(first: 0.2, last: 0.2, outgoingID: "other"),
            evidence(first: 0.2, last: 0.2, incomingID: "old"),
            evidence(first: 0.2, last: 0.2, incomingID: "third")
        ]
        #expect(evaluate(samples, crossfade: nil, paused: true) == .invalid)
        for evidence in mismatched {
            #expect(evaluate(samples, crossfade: evidence, paused: true) == .invalid)
        }
    }

    @Test
    func `a sample with less than half of the screen covered is rejected`() {
        let dimCrossfade = [crossfade(outgoing: 0.2, incoming: 0.2, progress: 0.2), settledNewPhoto]
        #expect(
            SceneTransitionDiagnostic.photoCoverage(of: [0.2, 0.2]) < SceneTransitionDiagnostic.minimumPhotoCoverage)
        #expect(evaluate(dimCrossfade, crossfade: stillCrossfade, paused: true) == .invalid)
    }

    @Test
    func `a hold that shows anything but the old photo over a hidden target is rejected`() {
        let partlyShownTarget = [
            Sample(
                phase: "grace", roles: ["stable", "incoming"], ids: ["old", "new"], opacities: [1, 0.3],
                progress: [0.2, 0]),
            settledNewPhoto
        ]
        let otherTarget = [
            Sample(
                phase: "grace", roles: ["stable", "incoming"], ids: ["old", "third"], opacities: [1, 0],
                progress: [0.2, 0]),
            settledNewPhoto
        ]
        #expect(evaluate(partlyShownTarget, crossfade: stillCrossfade, paused: true) == .invalid)
        #expect(evaluate(otherTarget, crossfade: stillCrossfade, paused: true) == .invalid)
    }

    @Test
    func `phases that run backwards or never settle are rejected`() {
        let backwards = [
            crossfade(outgoing: 0.33, incoming: 0.67, progress: 0.2),
            crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.2),
            settledNewPhoto
        ]
        let rehold = [crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.2), held(0.2), settledNewPhoto]
        let oldAfterNew = [settledNewPhoto, settledOldPhoto, settledNewPhoto]
        let unsettled = [held(0.2), crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.2)]
        for samples in [backwards, rehold, oldAfterNew, unsettled, []] {
            #expect(evaluate(samples, crossfade: stillCrossfade, paused: true) == .invalid)
        }
    }

    @Test
    func `a crossfade that fades out a different photo or ends elsewhere is rejected`() {
        let swapped = [
            held(0.2),
            crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.2, ids: ["other", "new"]),
            settledNewPhoto
        ]
        let backToOld = [crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.2), settledOldPhoto]
        let unrelated = [
            crossfade(outgoing: 0.67, incoming: 0.33, progress: 0.2),
            Sample(phase: "stablePhoto", roles: ["stable"], ids: ["third"], opacities: [1], progress: [0])
        ]
        for samples in [swapped, backToOld, unrelated] {
            #expect(evaluate(samples, crossfade: stillCrossfade, paused: true) == .invalid)
        }
    }

    @Test
    func `malformed samples and an unsettled starting sample are rejected`() {
        let malformed: [[Sample]] = [
            [crossfade(outgoing: 0.5, incoming: 0.5, progress: .nan), settledNewPhoto],
            [
                Sample(
                    phase: "transition", roles: ["outgoing", "incoming"], ids: ["old", "new"], opacities: [0.5],
                    progress: [0.2, 0])
            ] + [settledNewPhoto],
            [crossfade(outgoing: 0.5, incoming: 0.5, progress: 0.2, ids: ["old"])] + [settledNewPhoto],
            [
                Sample(
                    phase: "unknown", roles: ["outgoing", "incoming"], ids: ["old", "new"], opacities: [0.5, 0.5],
                    progress: [0.2, 0])
            ] + [settledNewPhoto],
            [crossfade(outgoing: 0.5, incoming: 0.5, progress: 0.2)]
                + [Sample(phase: "stablePhoto", roles: ["stable"], ids: ["new"], opacities: [0.9], progress: [0])]
        ]
        for samples in malformed {
            #expect(evaluate(samples, crossfade: stillCrossfade, paused: true) == .invalid)
        }
        let valid = [crossfade(outgoing: 0.5, incoming: 0.5, progress: 0.2), settledNewPhoto]
        let unsettledBefore = Sample(
            phase: "grace", roles: ["stable", "incoming"], ids: ["old", "new"], opacities: [1, 0], progress: [0.2, 0])
        #expect(evaluate(valid, crossfade: stillCrossfade, paused: true, before: unsettledBefore) == .invalid)
        #expect(evaluate(valid, crossfade: stillCrossfade, paused: true) == .outgoingHeldStill)
    }

    @Test
    func `a switch between the photos without a real blend is rejected`() {
        let samples = [held(0.2), settledNewPhoto]
        #expect(evaluate(samples, crossfade: evidence(first: 0.2, last: 0.2, peakBlend: 0), paused: true) == .invalid)
        #expect(
            evaluate(samples, crossfade: evidence(first: 0.2, last: 0.2, peakBlend: 0.05), paused: true) == .invalid)
        #expect(evaluate(samples, crossfade: stillCrossfade, paused: true) == .outgoingHeldStill)
    }

    @Test
    func `a playing crossfade that starts behind the last held frame is rejected`() {
        let samples = [held(0.3), settledNewPhoto]
        #expect(evaluate(samples, crossfade: evidence(first: 0.21, last: 0.24), paused: false) == .invalid)
        #expect(evaluate(samples, crossfade: evidence(first: 0.31, last: 0.34), paused: false) == .outgoingAdvanced)
    }

    @Test
    func `motion that goes backwards or wanders between the recorded ends is rejected`() {
        let samples = [held(0.21), settledNewPhoto]
        let rewoundWhilePlaying = evidence(first: 0.22, last: 0.28, rewound: true)
        #expect(evaluate(samples, crossfade: rewoundWhilePlaying, paused: false) == .invalid)
        let wanderedWhilePaused = evidence(first: 0.2, last: 0.2, lowest: 0.2, highest: 0.25)
        #expect(evaluate([held(0.2), settledNewPhoto], crossfade: wanderedWhilePaused, paused: true) == .invalid)
        let rewoundWhilePaused = evidence(first: 0.2, last: 0.2, rewound: true)
        #expect(evaluate([held(0.2), settledNewPhoto], crossfade: rewoundWhilePaused, paused: true) == .invalid)
    }

    @Test
    func `the probe crossfade record is read field by field and anything else is refused`() {
        let evidence = SceneTransitionDiagnostic.crossfadeEvidence(
            lastCrossfade: "ab12>cd34@0.200000>0.250000@0.190000>0.260000@0.480000@rewound", frameCount: 7)
        #expect(evidence?.frameCount == 7)
        #expect(evidence?.outgoingID == "ab12")
        #expect(evidence?.incomingID == "cd34")
        #expect(evidence?.firstOutgoingProgress == 0.2)
        #expect(evidence?.lastOutgoingProgress == 0.25)
        #expect(evidence?.lowestOutgoingProgress == 0.19)
        #expect(evidence?.highestOutgoingProgress == 0.26)
        #expect(evidence?.peakBlendOpacity == 0.48)
        #expect(evidence?.didOutgoingProgressRewind == true)
        let steady = SceneTransitionDiagnostic.crossfadeEvidence(
            lastCrossfade: "ab12>cd34@0.2>0.2@0.2>0.2@0.5@steady", frameCount: 7)
        #expect(steady?.didOutgoingProgressRewind == false)
        let refused = [
            "none", "ab12>cd34", "ab12>cd34@0.2>0.25", "ab12>cd34@0.2>0.25@0.2>0.25@0.5",
            "ab12>cd34@0.2>0.25@0.2>0.25@0.5@maybe", "ab12>cd34@0.2>0.25@0.2@0.5@steady",
            "ab12>cd34@x>0.25@0.2>0.25@0.5@steady", "ab12>cd34@0.2>0.25@0.2>0.25@x@steady"
        ]
        for raw in refused {
            #expect(SceneTransitionDiagnostic.crossfadeEvidence(lastCrossfade: raw, frameCount: 7) == nil)
        }
    }
}
