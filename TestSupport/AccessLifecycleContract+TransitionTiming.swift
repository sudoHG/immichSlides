import Foundation

extension AccessLifecycleContract {
    static func assertIPhonePauseTimingEvidence(
        continueMark: String,
        baselineLuma: Double?,
        samples: [ContinueWatchSample],
        intervalSeconds: TimeInterval
    ) throws -> (verdict: FirstTransitionStartVerdict, isOfficialStartSigned: Bool) {
        try assertSamplesStayOnSceneBeforeAdvanceWindow(
            continueMark: continueMark,
            samples: samples.map { (elapsed: $0.requestElapsed, mark: $0.mark) },
            intervalSeconds: intervalSeconds
        )
        guard let stable = firstStableNewImage(continueMark: continueMark, samples: samples) else {
            throw AssertionError.message("Black screen without a new photo must not pass automatically")
        }
        let verdict = assessFirstTransitionStart(
            continueMark: continueMark, baselineLuma: baselineLuma,
            samples: samples, intervalSeconds: intervalSeconds
        )
        let signed = try officialStartSigned(for: verdict, continueMark: continueMark, intervalSeconds: intervalSeconds)
        if case .detected(let requestElapsed, _, _) = verdict {
            guard let start = samples.first(where: { $0.requestElapsed == requestElapsed }) else {
                throw AssertionError.message(
                    "iPhone pause-continue evidence is invalid; detected start has no captured frame")
            }
            try assertStableImageWithinTransitionDeadline(
                start: start, stable: stable,
                failureMessage: "iPhone new photo must be stably identifiable within 4 s of transition start"
            )
        }
        return (verdict, signed)
    }

    static func assertTVOSPauseTimingEvidence(
        continueMark: String,
        baselineLuma: Double,
        samples: [ContinueWatchSample],
        intervalSeconds: TimeInterval
    ) throws -> (start: ContinueWatchSample, stable: ContinueWatchSample) {
        guard intervalSeconds.isFinite, intervalSeconds > 0,
            baselineLuma.isFinite, baselineLuma > minimumBaselineLuminance,
            samples.isEmpty == false,
            samples.enumerated().allSatisfy({ index, sample in
                sample.requestElapsed.isFinite && sample.requestElapsed >= 0
                    && sample.returnElapsed.isFinite && sample.returnElapsed >= sample.requestElapsed
                    && sample.classifiedElapsed.isFinite && sample.classifiedElapsed >= sample.returnElapsed
                    && sample.meanLuma.isFinite
                    && (index == 0 || sample.requestElapsed >= samples[index - 1].returnElapsed)
            })
        else {
            throw AssertionError.message(
                "tvOS pause-continue evidence is invalid; invalid timing or original photo brightness evidence"
            )
        }
        try assertSamplesStayOnSceneBeforeAdvanceWindow(
            continueMark: continueMark,
            samples: samples.map { (elapsed: $0.requestElapsed, mark: $0.mark) },
            intervalSeconds: intervalSeconds
        )
        guard let stable = firstStableNewImage(continueMark: continueMark, samples: samples) else {
            throw AssertionError.message(
                "After about a full T, it must switch to the next scene; no stable new public photo was confirmed")
        }
        let threshold = baselineLuma * sustainedDimmingLuminanceRatio
        let startIndex = samples.indices.first { index in
            let sample = samples[index]
            if sample.status == "MATCH", isUsableSceneMark(sample.mark), sample.mark != continueMark {
                return true
            }
            if sample.status == "TRANSITION" || sample.mark == "TRANSITION" {
                let recovered = samples.dropFirst(index + 1).prefix {
                    $0.requestElapsed <= stable.requestElapsed
                }.contains { $0.status == "MATCH" && $0.mark == continueMark && $0.meanLuma >= threshold }
                return !recovered
            }
            guard index > 0, sample.status == "MATCH", sample.mark == continueMark,
                sample.meanLuma < threshold,
                samples[index - 1].status == "MATCH", samples[index - 1].mark == continueMark,
                samples[index - 1].isControlBarVisible == sample.isControlBarVisible
            else { return false }
            return hasSustainedDimming(from: index, continueMark: continueMark, threshold: threshold, samples: samples)
        }
        guard let startIndex else {
            throw AssertionError.message("tvOS pause-continue evidence is invalid; no transition start was detected")
        }
        let start = samples[startIndex]
        try assertContinueAutoAdvanceInWindow(
            continueMark: continueMark, laterMark: stable.mark,
            elapsedSeconds: start.requestElapsed, intervalSeconds: intervalSeconds
        )
        try assertStableImageWithinTransitionDeadline(
            start: start, stable: stable,
            failureMessage: "tvOS new photo must be stably identifiable within 4 s of transition start"
        )
        return (start, stable)
    }

    static func assertContinueEarlyStillSameScene(
        continueMark: String,
        earlyMark: String,
        elapsedSeconds: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(continueMark)
        try assertPresentMark(earlyMark)
        if elapsedSeconds > intervalSeconds / 2 {
            throw AssertionError.message(
                "The first-half evidence window after Continue crossed its bounds; classify this as a test timing failure"
            )
        }
        if earlyMark != continueMark {
            throw AssertionError.message("The same public pattern must stay for the first half of T after Continue")
        }
    }

    static func assertContinueAutoAdvanceInWindow(
        continueMark: String,
        laterMark: String,
        elapsedSeconds: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(continueMark)
        try assertPresentMark(laterMark)
        let earliest = intervalSeconds - continueCaptureSlackSeconds
        let latest = intervalSeconds + continueCaptureSlackSeconds
        if elapsedSeconds > latest {
            throw AssertionError.message(
                "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
            )
        }
        if elapsedSeconds < earliest {
            throw AssertionError.message(
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            )
        }
        if laterMark == continueMark {
            throw AssertionError.message("After about a full T, it must switch to the next scene")
        }
    }

    static func isUsableSceneMark(_ mark: String) -> Bool {
        mark.isEmpty == false
            && mark != "BLACK"
            && mark != "BLANK"
            && mark != "UNRECOGNIZABLE"
            && mark != "TRANSITION"
    }

    static func assertSamplesStayOnSceneBeforeAdvanceWindow(
        continueMark: String,
        samples: [(elapsed: TimeInterval, mark: String)],
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(continueMark)
        let earliest = intervalSeconds - continueCaptureSlackSeconds
        for sample in samples where sample.elapsed + timingToleranceSeconds < earliest {
            try assertPresentMark(sample.mark)
            if sample.mark != continueMark {
                throw AssertionError.message(
                    "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
                )
            }
        }
    }

    static func assertSameProcess(beforeIdentifier: Int32, afterIdentifier: Int32) throws {
        if beforeIdentifier <= 0 || afterIdentifier <= 0 {
            throw AssertionError.message("Background return is missing the original process identity")
        }
        if beforeIdentifier != afterIdentifier {
            throw AssertionError.message("System pause analog must not rebuild the process")
        }
    }

    static func assertBackgroundIdentityIsFirstSegment(
        secondsBeforeIdentity: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        if secondsBeforeIdentity + timingToleranceSeconds >= intervalSeconds {
            throw AssertionError.message("On background return, do not wait a playback cycle before capturing identity")
        }
    }

    static func continueWatchRecordingDeadline(intervalSeconds: TimeInterval) -> TimeInterval {
        intervalSeconds + continueCaptureSlackSeconds + intervalSeconds
    }

    static func continueWatchDenseCaptureDeadline(intervalSeconds: TimeInterval) -> TimeInterval {
        min(
            intervalSeconds + continueCaptureSlackSeconds + newImageCaptureBeyondWindowSeconds,
            continueWatchRecordingDeadline(intervalSeconds: intervalSeconds)
        )
    }

    static func isAutoTransitionStart(status: String, mark: String, continueMark: String) -> Bool {
        if status == "TRANSITION" || mark == "TRANSITION" {
            return true
        }
        return isUsableSceneMark(mark) && mark != continueMark
    }

    static func isForbiddenAdvanceProxy(
        status: String,
        mark: String,
        continueMark: String,
        isControlBarVisible: Bool
    ) -> Bool {
        if status == "BLACK" || mark == "BLACK" { return true }
        if status == "BLANK" || mark == "BLANK" { return true }
        if status == "UNRECOGNIZABLE" || mark == "UNRECOGNIZABLE" { return true }
        if isUsableSceneMark(mark) && mark == continueMark { return true }
        if isControlBarVisible == false && mark == continueMark { return true }
        return isAutoTransitionStart(status: status, mark: mark, continueMark: continueMark) == false
    }

    static func assertBlackZoomBarOrClassificationIsNotAdvance(
        status: String,
        mark: String,
        continueMark: String,
        isControlBarVisible: Bool
    ) throws {
        if isForbiddenAdvanceProxy(
            status: status,
            mark: mark,
            continueMark: continueMark,
            isControlBarVisible: isControlBarVisible
        ) {
            throw AssertionError.message("Black screen, zoom, control bar gone or unrecognized is not a transition")
        }
    }

    static func assertClickTimesRecordedSeparately(
        pressIssuedElapsed: TimeInterval,
        pressReturnedElapsed: TimeInterval,
        continueOriginElapsed: TimeInterval,
        didUseReturnedAsOrigin: Bool
    ) throws {
        if didUseReturnedAsOrigin {
            throw AssertionError.message("Do not use click return time to hide the action's elapsed time")
        }
        if pressReturnedElapsed + timingToleranceSeconds < pressIssuedElapsed {
            throw AssertionError.message("The click return time must not be earlier than the press")
        }
        if abs(continueOriginElapsed - pressIssuedElapsed) > timingToleranceSeconds {
            throw AssertionError.message("Do not use click return time to hide the action's elapsed time")
        }
    }

    static func assertWindowUsesRequestElapsed(
        requestElapsed: TimeInterval,
        returnElapsed: TimeInterval,
        classifiedElapsed: TimeInterval,
        elapsedUsedForWindow: TimeInterval
    ) throws {
        if abs(elapsedUsedForWindow - requestElapsed) > timingToleranceSeconds {
            throw AssertionError.message("Evidence crossing the window must not pass automatically")
        }
        if elapsedUsedForWindow == returnElapsed && returnElapsed > requestElapsed + timingToleranceSeconds {
            throw AssertionError.message("Evidence crossing the window must not pass automatically")
        }
        if elapsedUsedForWindow == classifiedElapsed && classifiedElapsed > requestElapsed + timingToleranceSeconds {
            throw AssertionError.message("Evidence crossing the window must not pass automatically")
        }
    }

    static func firstIdentifiableNewImage(
        continueMark: String,
        samples: [ContinueWatchSample]
    ) -> ContinueWatchSample? {
        samples.first { sample in
            sample.status == "MATCH" && isUsableSceneMark(sample.mark) && sample.mark != continueMark
        }
    }

    static func firstStableNewImage(
        continueMark: String,
        samples: [ContinueWatchSample],
        minimumStableSeconds: TimeInterval = newStableMarkConfirmWindow
    ) -> ContinueWatchSample? {
        guard minimumStableSeconds.isFinite, minimumStableSeconds > 0 else { return nil }
        var candidate: ContinueWatchSample?
        var previous: ContinueWatchSample?
        for sample in samples {
            guard sample.requestElapsed.isFinite, sample.returnElapsed.isFinite,
                sample.returnElapsed >= sample.requestElapsed,
                sample.meanLuma.isFinite
            else { return nil }
            if let previous {
                if sample.requestElapsed < previous.returnElapsed { return nil }
                if sample.requestElapsed - previous.returnElapsed > newStableMarkPollInterval + timingToleranceSeconds {
                    candidate = nil
                }
            }
            previous = sample
            guard isUsableSceneMark(sample.mark),
                isConfirmedNewStableMark(
                    status: sample.status, mark: sample.mark, candidateMark: sample.mark,
                    initialMark: continueMark, meanLuma: sample.meanLuma
                )
            else {
                candidate = nil
                continue
            }
            if candidate?.mark != sample.mark { candidate = sample }
            if let candidate,
                sample.requestElapsed - candidate.returnElapsed >= minimumStableSeconds
            {
                return sample
            }
        }
        return nil
    }

    static func assertIPadPauseTimingEvidence(
        continueMark: String,
        baselineLuma: Double,
        samples: [ContinueWatchSample],
        intervalSeconds: TimeInterval,
        pressReturnedElapsed: TimeInterval = 0
    ) throws -> IPadPauseTimingEvidence {
        guard intervalSeconds.isFinite, intervalSeconds > 0,
            baselineLuma.isFinite, baselineLuma > minimumBaselineLuminance,
            pressReturnedElapsed.isFinite, (0...maximumPressReturnDelaySeconds).contains(pressReturnedElapsed)
        else {
            throw AssertionError.message("iPad pause-continue lacks valid timing or original photo brightness evidence")
        }
        guard samples.count >= 2 else {
            throw AssertionError.message("iPad pause-continue is missing verifiable old-photo and transition samples")
        }

        for index in samples.indices {
            let sample = samples[index]
            guard sample.requestElapsed.isFinite, sample.returnElapsed.isFinite,
                sample.classifiedElapsed.isFinite, sample.meanLuma.isFinite,
                sample.returnElapsed >= sample.requestElapsed,
                sample.returnElapsed - sample.requestElapsed <= 1.001
            else {
                throw AssertionError.message("iPad pause-continue samples contain invalid timing or brightness")
            }
            if index > 0 {
                let previous = samples[index - 1]
                let gap = sample.requestElapsed - previous.returnElapsed
                guard gap >= 0, gap <= newStableMarkPollInterval + timingToleranceSeconds else {
                    throw AssertionError.message("iPad pause-continue samples are out of order or have a gap")
                }
            }
        }

        let dimmingThreshold = baselineLuma * sustainedDimmingLuminanceRatio
        var startIndex: Int?
        for index in 1..<samples.count {
            let sample = samples[index]
            let isTransitionMarker = sample.status == "TRANSITION" || sample.mark == "TRANSITION"
            let isDifferentImage =
                sample.status == "MATCH"
                && isUsableSceneMark(sample.mark)
                && sample.mark != continueMark
            let isSustainedDimming =
                sample.status == "MATCH"
                && sample.mark == continueMark
                && sample.meanLuma < dimmingThreshold
                && hasSustainedDimming(
                    from: index,
                    continueMark: continueMark,
                    threshold: dimmingThreshold,
                    samples: samples
                )
            if isTransitionMarker || isDifferentImage || isSustainedDimming {
                startIndex = index
                break
            }
        }
        guard let startIndex, startIndex > 0 else {
            throw AssertionError.message("iPad pause-continue: no transition start via sustained dimming or new photo")
        }
        let start = samples[startIndex]
        let previous = samples[startIndex - 1]
        guard samples[..<startIndex].allSatisfy({ $0.status == "MATCH" && $0.mark == continueMark }),
            previous.status == "MATCH", previous.mark == continueMark,
            previous.isControlBarVisible == start.isControlBarVisible,
            previous.meanLuma.isFinite, previous.meanLuma >= newStableMarkMinimumLuma,
            previous.requestElapsed.isFinite, previous.returnElapsed.isFinite,
            start.requestElapsed.isFinite, start.returnElapsed.isFinite,
            previous.returnElapsed >= previous.requestElapsed,
            start.returnElapsed >= start.requestElapsed,
            start.requestElapsed >= previous.returnElapsed
        else {
            throw AssertionError.message(
                "A continuous, reliable screenshot of the previous photo must precede the iPad transition start; previous[index=\(startIndex - 1), requestElapsed=\(previous.requestElapsed), returnElapsed=\(previous.returnElapsed), status=\(previous.status), mark=\(previous.mark), meanLuma=\(previous.meanLuma)]; start[index=\(startIndex), requestElapsed=\(start.requestElapsed), returnElapsed=\(start.returnElapsed), status=\(start.status), mark=\(start.mark), meanLuma=\(start.meanLuma)]"
            )
        }
        let earliestTransitionElapsed = previous.requestElapsed - pressReturnedElapsed
        let latestTransitionElapsed = start.returnElapsed
        let earliestAllowed = intervalSeconds - continueCaptureSlackSeconds
        let latestAllowed = intervalSeconds + continueCaptureSlackSeconds
        if earliestTransitionElapsed + timingToleranceSeconds < earliestAllowed
            || latestTransitionElapsed > latestAllowed + timingToleranceSeconds
        {
            throw AssertionError.message("iPad transition: conservative screenshot range must lie fully within T±2 s")
        }
        guard
            let stable = firstStableNewImage(
                continueMark: continueMark,
                samples: samples,
                minimumStableSeconds: ipadNewStableMarkConfirmWindow
            ), stable.requestElapsed + timingToleranceSeconds >= start.requestElapsed
        else {
            throw AssertionError.message("iPad must keep identifying a different new photo for at least 1 second")
        }
        try assertStableImageWithinTransitionDeadline(
            start: start, stable: stable,
            failureMessage: "iPad new photo must be stably identifiable within 4 s of transition start"
        )
        return IPadPauseTimingEvidence(
            earliestTransitionElapsed: earliestTransitionElapsed,
            latestTransitionElapsed: latestTransitionElapsed,
            transitionStartRequestElapsed: start.requestElapsed,
            stableImageRequestElapsed: stable.requestElapsed,
            stableImageReturnElapsed: stable.returnElapsed,
            stableImageDelaySeconds: stable.returnElapsed - start.requestElapsed
        )
    }

    private static func assertStableImageWithinTransitionDeadline(
        start: ContinueWatchSample,
        stable: ContinueWatchSample,
        failureMessage: String
    ) throws {
        let delay = stable.returnElapsed - start.requestElapsed
        if !delay.isFinite || delay < 0 || delay > ipadStableImageDeadlineAfterTransition + timingToleranceSeconds {
            throw AssertionError.message(failureMessage)
        }
    }

    static func hasSustainedDimming(
        from startIndex: Int,
        continueMark: String,
        threshold: Double,
        samples: [ContinueWatchSample]
    ) -> Bool {
        // A 4K capture can take 0.45 s: anchor the three-point fade in the preceding bright old photo.
        guard startIndex > 0 else { return false }
        let anchorIndex = startIndex - 1
        let lastIndex = anchorIndex + requiredConsecutiveFadeSampleCount - 1
        guard lastIndex < samples.count else { return false }
        var previous = samples[anchorIndex]
        guard previous.status == "MATCH", previous.mark == continueMark,
            previous.meanLuma.isFinite, previous.meanLuma >= threshold
        else { return false }
        for index in startIndex...lastIndex {
            let sample = samples[index]
            let gap = sample.requestElapsed - previous.returnElapsed
            guard sample.status == "MATCH", sample.mark == continueMark,
                sample.meanLuma.isFinite, sample.meanLuma < threshold,
                sample.meanLuma < previous.meanLuma - luminanceTolerance,
                sample.isControlBarVisible == previous.isControlBarVisible,
                gap >= 0, gap <= newStableMarkPollInterval + timingToleranceSeconds
            else {
                return false
            }
            previous = sample
        }
        // A flicker that recovers the old photo cannot establish fade onset on any platform.
        let stable = firstStableNewImage(continueMark: continueMark, samples: samples)
        return !samples.dropFirst(startIndex + 1).prefix {
            $0.requestElapsed <= (stable?.requestElapsed ?? .infinity)
        }.contains { $0.status == "MATCH" && $0.mark == continueMark && $0.meanLuma >= threshold }
    }

    static func assertIdentifiableNewImagePresent(
        continueMark: String,
        confirmedMark: String?,
        confirmedStatus: String?
    ) throws {
        try assertPresentMark(continueMark)
        guard let confirmedMark, let confirmedStatus else {
            throw AssertionError.message("Black screen without a new photo must not pass automatically")
        }
        if confirmedStatus != "MATCH" || isUsableSceneMark(confirmedMark) == false || confirmedMark == continueMark {
            throw AssertionError.message("Black screen without a new photo must not pass automatically")
        }
        try assertPresentMark(confirmedMark)
    }

    static func assertRecordingDidNotStopAtIdentityTimeout(
        lastSampleRequestElapsed: TimeInterval,
        hasConfirmedNewImage: Bool,
        intervalSeconds: TimeInterval
    ) throws {
        let identityTimeout = intervalSeconds + continueCaptureSlackSeconds
        if hasConfirmedNewImage {
            return
        }
        if lastSampleRequestElapsed <= identityTimeout + timingToleranceSeconds {
            throw AssertionError.message("Record until a new photo is identifiable, not until the T+2 identity timeout")
        }
    }

    static func assessFirstTransitionStart(
        continueMark: String,
        baselineLuma: Double?,
        samples: [ContinueWatchSample],
        intervalSeconds: TimeInterval
    ) -> FirstTransitionStartVerdict {
        let earliest = intervalSeconds - continueCaptureSlackSeconds
        let latest = intervalSeconds + continueCaptureSlackSeconds
        let ordered = samples.sorted { $0.requestElapsed < $1.requestElapsed }

        func hasUncertainSignal(_ sample: ContinueWatchSample) -> Bool {
            if sample.requestElapsed + timingToleranceSeconds < earliest || sample.requestElapsed > latest {
                return false
            }
            if sample.status == "UNRECOGNIZABLE" || sample.mark == "UNRECOGNIZABLE" {
                return true
            }
            if sample.status == "BLACK" || sample.mark == "BLACK" {
                return true
            }
            if let baselineLuma,
                isUsableSceneMark(sample.mark),
                sample.mark == continueMark,
                baselineLuma - sample.meanLuma >= uncertainSameMarkLumaDrop
            {
                return true
            }
            return false
        }

        let startIndex = ordered.indices.first { index in
            let sample = ordered[index]
            if isAutoTransitionStart(status: sample.status, mark: sample.mark, continueMark: continueMark) {
                return true
            }
            guard let baselineLuma, baselineLuma.isFinite, baselineLuma > minimumBaselineLuminance,
                index > 0, sample.status == "MATCH", sample.mark == continueMark,
                sample.meanLuma.isFinite,
                ordered[index - 1].status == "MATCH", ordered[index - 1].mark == continueMark,
                ordered[index - 1].isControlBarVisible == sample.isControlBarVisible
            else { return false }
            let threshold = baselineLuma * sustainedDimmingLuminanceRatio
            guard sample.meanLuma < threshold else { return false }
            return hasSustainedDimming(
                from: index, continueMark: continueMark, threshold: threshold, samples: ordered
            )
        }
        guard let startIndex
        else {
            if ordered.contains(where: hasUncertainSignal) {
                return .pendingVideoReview(reason: "Unusable changes in window; auto start cannot be reliably judged")
            }
            return .missing
        }
        let firstStart = ordered[startIndex]
        if firstStart.requestElapsed + timingToleranceSeconds < earliest {
            return .tooEarly(requestElapsed: firstStart.requestElapsed, mark: firstStart.mark)
        }
        if firstStart.requestElapsed > latest {
            let hasEarlierUncertainEvidence = ordered.contains { sample in
                sample.requestElapsed + timingToleranceSeconds < firstStart.requestElapsed && hasUncertainSignal(sample)
            }
            if hasEarlierUncertainEvidence {
                return .pendingVideoReview(reason: "No usable start in window; post-window new photo does not count")
            }
            return .tooLate(requestElapsed: firstStart.requestElapsed, mark: firstStart.mark)
        }
        return .detected(
            requestElapsed: firstStart.requestElapsed,
            mark: firstStart.mark,
            status: firstStart.mark == continueMark ? "DIMMING" : firstStart.status
        )
    }

    static func assertFirstTransitionStartInWindow(
        continueMark: String,
        startMark: String,
        startStatus: String,
        elapsedSeconds: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(continueMark)
        let isSustainedDimmingStart = startStatus == "DIMMING" && startMark == continueMark
        if !isSustainedDimmingStart {
            try assertBlackZoomBarOrClassificationIsNotAdvance(
                status: startStatus,
                mark: startMark,
                continueMark: continueMark,
                isControlBarVisible: true
            )
            if isAutoTransitionStart(status: startStatus, mark: startMark, continueMark: continueMark) == false {
                throw AssertionError.message("Black screen, zoom, control bar gone or unrecognized is not a transition")
            }
        }
        let earliest = intervalSeconds - continueCaptureSlackSeconds
        let latest = intervalSeconds + continueCaptureSlackSeconds
        if elapsedSeconds > latest {
            throw AssertionError.message(
                "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
            )
        }
        if elapsedSeconds < earliest {
            throw AssertionError.message(
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            )
        }
    }

    static func assertFirstTransitionStartOfficialPass(
        verdict: FirstTransitionStartVerdict,
        isOfficiallySigned: Bool
    ) throws {
        switch verdict {
        case .detected:
            if isOfficiallySigned == false {
                throw AssertionError.message("An in-window start was detected but not signed off")
            }
        case .pendingVideoReview:
            if isOfficiallySigned {
                throw AssertionError.message(
                    "Uncertain samples must remain pending video review; do not default to PASS")
            }
        case .tooEarly, .tooLate, .missing:
            if isOfficiallySigned {
                throw AssertionError.message("Too early/late transition or missing start cannot pass automatically")
            }
        }
    }

    static func officialStartSigned(
        for verdict: FirstTransitionStartVerdict,
        continueMark: String,
        intervalSeconds: TimeInterval
    ) throws -> Bool {
        switch verdict {
        case .detected(let elapsed, let mark, let status):
            try assertFirstTransitionStartInWindow(
                continueMark: continueMark,
                startMark: mark,
                startStatus: status,
                elapsedSeconds: elapsed,
                intervalSeconds: intervalSeconds
            )
            try assertFirstTransitionStartOfficialPass(verdict: verdict, isOfficiallySigned: true)
            return true
        case .pendingVideoReview:
            try assertFirstTransitionStartOfficialPass(verdict: verdict, isOfficiallySigned: false)
            return false
        case .tooEarly:
            throw AssertionError.message(
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            )
        case .tooLate, .missing:
            throw AssertionError.message(
                "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
            )
        }
    }

    static func isSettingValueEqual(_ left: Any, _ right: Any) -> Bool {
        String(describing: left) == String(describing: right)
    }
}
