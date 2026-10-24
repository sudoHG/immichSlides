import XCTest
@testable import immichSlides

extension SettingsResumeContractTests {
    func testIPhonePauseSignsSustainedFadeOnRequestClockBeforeLateStablePhoto() throws {
        for start in [10.0, 13.2, 14.0] {
            let evidence = try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53,
                samples: iphoneFadeSamples(start: start), intervalSeconds: 12
            )
            XCTAssertEqual(evidence.verdict, .detected(requestElapsed: start, mark: "A5", status: "DIMMING"))
            XCTAssertTrue(evidence.isOfficialStartSigned)
        }
    }

    func testIPhonePauseRejectsEarlyAndLateSustainedFade() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53,
                samples: earlyFadeWithFrozenDimSamples(), intervalSeconds: 12
            )
        ) {
            XCTAssertEqual(
                $0.localizedDescription,
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            )
        }
        for (start, message) in [
            (
                9.8,
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            ),
            (
                14.1,
                "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
            )
        ] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53,
                    samples: iphoneFadeSamples(start: start), intervalSeconds: 12
                )
            ) { XCTAssertEqual($0.localizedDescription, message) }
        }
    }

    func testIPhonePauseRejectsLongBlackAfterInWindowFade() {
        let fade = iphoneFadeSamples(start: 13.2).filter { $0.requestElapsed < 14.1 }
        for newStart in [16.01, 16.012, 16.3] {
            let black = (0...20).map { index in
                watchSample(
                    request: 14.1 + Double(index) * 0.15, mark: "BLACK", status: "BLACK", luma: 0.01, returnLag: 0.14)
            }.filter { $0.returnElapsed <= newStart }
            let newPhoto = (0...8).map { index in
                watchSample(request: newStart + Double(index) * 0.15, mark: "A1", luma: 0.47, returnLag: 0.14)
            }
            if newStart == 16.01 {
                XCTAssertNoThrow(
                    try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
                        continueMark: "A5", baselineLuma: 0.53, samples: fade + black + newPhoto, intervalSeconds: 12
                    ))
            } else {
                XCTAssertThrowsError(
                    try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
                        continueMark: "A5", baselineLuma: 0.53, samples: fade + black + newPhoto, intervalSeconds: 12
                    )
                ) {
                    XCTAssertEqual(
                        $0.localizedDescription,
                        "iPhone new photo must be stably identifiable within 4 s of transition start")
                }
            }
        }
    }

    func testIPhonePauseRejectsEveryUnusableFrameBeforeWindowEvenWhenRecovered() {
        for (mark, message) in [
            ("BLACK", "All black must not count as a pass"),
            ("BLANK", "Blank must not count as a pass"),
            ("UNRECOGNIZABLE", "Unrecognizable input must not count as a pass"),
            ("TRANSITION", "Unrecognizable input must not count as a pass")
        ] {
            let samples =
                [watchSample(request: 7.6, mark: mark, status: mark, returnLag: 0.14)] + iphoneFadeSamples(start: 13.2)
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53, samples: samples, intervalSeconds: 12
                )
            ) { XCTAssertEqual($0.localizedDescription, message) }
        }
    }

    func testIPhonePauseKeepsIsolatedBlackUniformDimAndUndecidableEvidenceUnsigned() throws {
        for signal in [
            "BLACK", "UNRECOGNIZABLE", "uniform", "one_frame", "recovered", "controls", "gap", "missing_baseline",
            "dark_baseline", "unknown_previous", "controls_mid_fade", "late_decrease", "increasing_dim", "long_span",
            "excess_frozen"
        ] {
            var samples = iphoneFadeSamples(start: 13.2)
            for index in 2...4 {
                let sample = samples[index]
                let unusable = signal == "BLACK" || signal == "UNRECOGNIZABLE"
                let luma = signal == "uniform" ? 0.3 : sample.meanLuma
                samples[index] = watchSample(
                    request: sample.requestElapsed, mark: unusable ? signal : "A5", status: unusable ? signal : "MATCH",
                    luma: luma, isControlBarVisible: signal != "controls", returnLag: 0.14
                )
            }
            if signal == "controls_mid_fade" {
                samples = tvosFadeSamples(start: 13.2).map { sample in
                    watchSample(
                        request: sample.requestElapsed, mark: sample.mark, status: sample.status, luma: sample.meanLuma,
                        isControlBarVisible: sample.requestElapsed < 13.5 - 0.001, returnLag: 0.28
                    )
                }
            }
            if signal == "dark_baseline" {
                for (index, luma) in [0.09, 0.07, 0.05].enumerated() {
                    samples[index + 2] = watchSample(
                        request: samples[index + 2].requestElapsed, mark: "A5", luma: luma, returnLag: 0.14)
                }
            }
            if signal == "one_frame" {
                samples.removeAll { abs($0.requestElapsed - 13.35) < 0.001 || abs($0.requestElapsed - 13.5) < 0.001 }
            }
            if signal == "gap" {
                samples[2] = watchSample(request: 13.2, mark: "A5", luma: 0.49, returnLag: 0.01)
            }
            if signal == "recovered" {
                samples[6] = watchSample(request: samples[6].requestElapsed, mark: "A5", luma: 0.53, returnLag: 0.14)
            }
            if signal == "unknown_previous" {
                samples[1] = watchSample(
                    request: 13.05, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", returnLag: 0.14)
            }
            if ["late_decrease", "increasing_dim", "long_span", "excess_frozen"].contains(signal) {
                samples = nonFadeDimSamples(signal: signal)
            }
            let baseline: Double? = signal == "missing_baseline" ? nil : signal == "dark_baseline" ? 0.1 : 0.53
            let evidence = try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
                continueMark: "A5", baselineLuma: baseline, samples: samples, intervalSeconds: 12
            )
            if ["late_decrease", "increasing_dim", "long_span", "excess_frozen"].contains(signal) {
                XCTAssertEqual(
                    evidence.verdict,
                    .pendingVideoReview(reason: "No usable start in window; post-window new photo does not count"),
                    signal
                )
                XCTAssertFalse(evidence.isOfficialStartSigned, signal)
                continue
            }
            guard case .pendingVideoReview = evidence.verdict else { return XCTFail("\(signal) must await review") }
            XCTAssertFalse(evidence.isOfficialStartSigned, signal)
        }
    }

    func testIPhonePauseRequiresStableNewPhotoAfterDimming() {
        let samples = iphoneFadeSamples(start: 13.2).filter { $0.mark != "A1" }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: samples, intervalSeconds: 12
            )
        ) { XCTAssertEqual($0.localizedDescription, "Black screen without a new photo must not pass automatically") }
    }

    private func iphoneFadeSamples(start: TimeInterval) -> [AccessLifecycleContract.ContinueWatchSample] {
        let old = [start - 0.3, start - 0.15].map {
            watchSample(request: $0, mark: "A5", luma: 0.53, returnLag: 0.14)
        }
        let fade = [0.49, 0.35, 0.16].enumerated().map { index, luma in
            watchSample(request: start + Double(index) * 0.15, mark: "A5", luma: luma, returnLag: 0.14)
        }
        let trough = (3...7).map { index in
            watchSample(
                request: start + Double(index) * 0.15, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.03,
                returnLag: 0.14)
        }
        let newPhoto = (8...16).map { index in
            watchSample(request: start + Double(index) * 0.15, mark: "A1", luma: 0.47, returnLag: 0.14)
        }
        return old + fade + trough + newPhoto
    }

    private func earlyFadeWithFrozenDimSamples() -> [AccessLifecycleContract.ContinueWatchSample] {
        let anchor = watchSample(request: 9.35, mark: "A5", luma: 0.53, returnLag: 0.14)
        let fade = [0.49, 0.49, 0.42, 0.35, 0.25].enumerated().map { index, luma in
            watchSample(request: 9.5 + Double(index) * 0.15, mark: "A5", luma: luma, returnLag: 0.14)
        }
        let trough = (0...3).map { index in
            watchSample(
                request: 10.25 + Double(index) * 0.15, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE",
                luma: 0.03, returnLag: 0.14
            )
        }
        let newPhoto = (0...8).map { index in
            watchSample(request: 10.85 + Double(index) * 0.15, mark: "A1", luma: 0.47, returnLag: 0.14)
        }
        return [anchor] + fade + trough + newPhoto
    }

    private func slowEarlyFadeWithoutFrozenDimSamples() -> [AccessLifecycleContract.ContinueWatchSample] {
        let fade = [
            watchSample(request: 8.99, mark: "A5", luma: 0.53, returnLag: 0.49),
            watchSample(request: 9.50, mark: "A5", luma: 0.49, returnLag: 0.49),
            watchSample(request: 10.01, mark: "A5", luma: 0.35, returnLag: 0.49)
        ]
        return fade
            + (0...6).map { index in
                watchSample(request: 10.52 + Double(index) * 0.3, mark: "A1", luma: 0.47, returnLag: 0.28)
            }
    }

    private func nonFadeDimSamples(signal: String) -> [AccessLifecycleContract.ContinueWatchSample] {
        if signal == "excess_frozen" {
            return (0...22).map { index in
                let luma: Double
                switch index {
                case 0: luma = 0.53
                case 1..<4: luma = 0.35
                case 4..<7: luma = 0.3489
                default: luma = 0.47
                }
                return watchSample(
                    request: 13.0 + Double(index) * 0.2, mark: index < 7 ? "A5" : "A1", luma: luma, returnLag: 0.18
                )
            }
        }
        if signal == "long_span" || signal == "span_boundary" {
            let cadence = signal == "long_span" ? 0.34 : 1.0 / 3.0
            let dim = [
                watchSample(request: 13.2 - cadence, mark: "A5", luma: 0.53, returnLag: cadence - 0.02),
                watchSample(request: 13.2, mark: "A5", luma: 0.49, returnLag: cadence - 0.02),
                watchSample(request: 13.2 + cadence, mark: "A5", luma: 0.49, returnLag: cadence - 0.02),
                watchSample(request: 13.2 + 2 * cadence, mark: "A5", luma: 0.35, returnLag: cadence - 0.02)
            ]
            return dim
                + (0...6).map { index in
                    watchSample(
                        request: 13.2 + 3 * cadence + Double(index) * 0.3, mark: "A1", luma: 0.47, returnLag: 0.28)
                }
        }
        return tvosFadeSamples(start: 13.2).map { sample in
            let offset = sample.requestElapsed - 13.2
            if offset >= -0.001 && offset < 0.9 - 0.001 {
                let luma =
                    signal == "late_decrease"
                    ? 0.35 : (offset < 0.3 - 0.001 ? 0.49 : offset < 0.6 - 0.001 ? 0.50 : 0.16)
                return watchSample(request: sample.requestElapsed, mark: "A5", luma: luma, returnLag: 0.28)
            }
            if signal == "late_decrease" && abs(offset - 0.9) < 0.001 {
                return watchSample(request: sample.requestElapsed, mark: "A5", luma: 0.3489, returnLag: 0.28)
            }
            return sample
        }
    }

    func testTVOSPauseJudgesSharedSustainedFadeBeforeLateNewPhoto() throws {
        for start in [10.0, 13.2, 14.0] {
            let evidence = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53,
                samples: tvosFadeSamples(start: start), intervalSeconds: 12
            )
            XCTAssertEqual(evidence.start.requestElapsed, start, accuracy: 0.001)
            XCTAssertEqual(evidence.start.mark, "A5")
            XCTAssertEqual(evidence.stable.mark, "A1")
            if start >= 13.2 {
                XCTAssertGreaterThan(evidence.stable.requestElapsed, 14)
            }
        }
        for frozenLuma in [0.4895, 0.49, 0.4905] {
            let frozen = tvosFadeSamples(start: 13.2).map { sample in
                abs(sample.requestElapsed - 13.5) < 0.001
                    ? watchSample(request: sample.requestElapsed, mark: "A5", luma: frozenLuma, returnLag: 0.28)
                    : sample
            }
            let evidence = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: frozen, intervalSeconds: 12
            )
            XCTAssertEqual(evidence.start.requestElapsed, 13.2, accuracy: 0.001)
        }
        let boundary = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
            continueMark: "A5", baselineLuma: 0.53,
            samples: nonFadeDimSamples(signal: "span_boundary"), intervalSeconds: 12
        )
        XCTAssertEqual(boundary.start.requestElapsed, 13.2, accuracy: 0.001)
        // Pinned 4K capture: the 1 s outgoing fade retained only two dim MATCH frames.
        let captured =
            [
                watchSample(request: 9.962391, mark: "A5", luma: 0.551154, returnLag: 0.302778),
                watchSample(request: 10.265197, mark: "A5", luma: 0.530846, returnLag: 0.324398),
                watchSample(request: 10.589622, mark: "A5", luma: 0.449442, returnLag: 0.397890),
                watchSample(request: 10.987536, mark: "A5", luma: 0.287456, returnLag: 0.453210),
                watchSample(
                    request: 11.440773, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.330429,
                    returnLag: 0.416386),
                watchSample(
                    request: 11.857182, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.453709,
                    returnLag: 0.304881)
            ]
            + (0...5).map { index in
                watchSample(request: 12.162089 + Double(index) * 0.24, mark: "A1", luma: 0.49, returnLag: 0.238)
            }
        let replay = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
            continueMark: "A5", baselineLuma: 0.557, samples: captured, intervalSeconds: 10
        )
        XCTAssertEqual(replay.start.requestElapsed, 10.589622, accuracy: 0.001)
        XCTAssertEqual(replay.start.mark, "A5")
    }

    func testTVOSPauseRejectsEarlyAndLateFadeStarts() {
        for samples in [earlyFadeWithFrozenDimSamples(), slowEarlyFadeWithoutFrozenDimSamples()] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53, samples: samples, intervalSeconds: 12
                )
            ) {
                XCTAssertEqual(
                    $0.localizedDescription,
                    "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
                )
            }
        }
        for (start, message) in [
            (
                9.3,
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            ),
            (
                14.1,
                "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
            )
        ] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53,
                    samples: tvosFadeSamples(start: start), intervalSeconds: 12
                )
            ) { error in
                XCTAssertEqual(error.localizedDescription, message)
                XCTAssertTrue(String(describing: error).hasPrefix("message("))
            }
        }
    }

    func testTVOSPauseRejectsDimWithoutStableNewPhoto() {
        let samples = tvosFadeSamples(start: 13.2)
        let dimOnly = samples.map { sample in
            watchSample(
                request: sample.requestElapsed, mark: sample.mark == "A1" ? "A5" : sample.mark,
                status: sample.status, luma: sample.meanLuma, returnLag: 0.28
            )
        }
        for invalid in [dimOnly, Array(samples.dropLast(4))] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53, samples: invalid, intervalSeconds: 12
                )
            ) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "After about a full T, it must switch to the next scene; no stable new public photo was confirmed"
                )
            }
        }
    }

    func testTVOSPauseRejectsLongBlackAfterInWindowFade() {
        let oldAndFade = tvosFadeSamples(start: 10).filter { $0.requestElapsed < 10.9 }
        let black = (0...10).map { index in
            watchSample(
                request: 10.9 + Double(index) * 0.3, mark: "BLACK", status: "BLACK",
                luma: 0.01, returnLag: 0.28
            )
        }
        for firstNewRequest in [12.52, 12.522, 14.2] {
            let newPhoto = (0...5).map { index in
                watchSample(
                    request: firstNewRequest + Double(index) * 0.3, mark: "A1", luma: 0.47, returnLag: 0.28
                )
            }
            let samples = oldAndFade + black.filter { $0.returnElapsed <= firstNewRequest } + newPhoto
            if firstNewRequest == 12.52 {
                XCTAssertNoThrow(
                    try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                        continueMark: "A5", baselineLuma: 0.53, samples: samples, intervalSeconds: 10
                    )
                )
            } else {
                XCTAssertThrowsError(
                    try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                        continueMark: "A5", baselineLuma: 0.53, samples: samples, intervalSeconds: 10
                    )
                ) { error in
                    XCTAssertEqual(
                        error.localizedDescription,
                        "tvOS new photo must be stably identifiable within 4 s of transition start"
                    )
                }
            }
        }
    }

    func testTVOSPauseRejectsUnrecognizableFrameBeforeAdvanceWindow() {
        let samples = tvosFadeSamples(start: 7).map { sample in
            if abs(sample.requestElapsed - 7.6) < 0.001 {
                return watchSample(
                    request: sample.requestElapsed, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE",
                    luma: sample.meanLuma, returnLag: 0.28
                )
            }
            return sample
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: samples, intervalSeconds: 10
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Unrecognizable input must not count as a pass")
        }
    }

    func testTVOSPauseRejectsEveryInvalidFrameBeforeAdvanceWindow() {
        for (mark, message) in [
            ("BLACK", "All black must not count as a pass"),
            ("BLANK", "Blank must not count as a pass"),
            ("UNRECOGNIZABLE", "Unrecognizable input must not count as a pass"),
            ("TRANSITION", "Unrecognizable input must not count as a pass"),
            (
                "A2",
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            )
        ] {
            let samples = tvosFadeSamples(start: 10).map { sample in
                if abs(sample.requestElapsed - 4.9) < 0.001 {
                    return watchSample(
                        request: sample.requestElapsed, mark: mark, status: mark == "A2" ? "MATCH" : mark,
                        luma: 0.01, returnLag: 0.28
                    )
                }
                return sample
            }
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53, samples: samples, intervalSeconds: 10
                ), mark
            ) { error in
                XCTAssertEqual(error.localizedDescription, message, mark)
            }
        }
    }

    func testTVOSPauseRejectsBlackUniformDimRecoveredDimAndControlBarAsStart() {
        let start = 13.2
        let valid = tvosFadeSamples(start: start)
        for mutation in [
            "isolated_black", "uniform_dim", "recovered_dim", "controls", "only_one_dim_frame", "dim_anchor",
            "anchor_gap", "increasing_dim", "controls_mid_fade", "recovered_transition", "late_decrease", "long_span",
            "excess_frozen"
        ] {
            var samples = valid.map { sample in
                let offset = sample.requestElapsed - start
                var mark = sample.mark
                var status = sample.status
                var luma = sample.meanLuma
                if offset >= -0.001 && offset < 0.9 - 0.001 {
                    if mutation == "isolated_black" { luma = 0.53 }
                    if mutation == "isolated_black" && abs(offset) < 0.001 {
                        mark = "BLACK"
                        status = "BLACK"
                        luma = 0.01
                    }
                    if mutation == "uniform_dim" { luma = 0.35 }
                    if mutation == "only_one_dim_frame" && offset > 0.2 {
                        mark = "UNRECOGNIZABLE"
                        status = "UNRECOGNIZABLE"
                    }
                }
                if mutation == "dim_anchor" && offset < -0.001 { luma = 0.49 }
                if mutation == "recovered_transition" && abs(offset) < 0.001 {
                    mark = "TRANSITION"
                    status = "TRANSITION"
                }
                if (mutation == "recovered_dim" || mutation == "recovered_transition") && abs(offset - 0.9) < 0.001 {
                    mark = "A5"
                    status = "MATCH"
                    luma = 0.53
                }
                if mutation == "isolated_black" && abs(offset - 0.9) < 0.001 {
                    mark = "A5"
                    status = "MATCH"
                    luma = 0.53
                }
                return watchSample(
                    request: sample.requestElapsed, mark: mark, status: status, luma: luma,
                    isControlBarVisible: (mutation != "controls" || offset < -0.001)
                        && (mutation != "controls_mid_fade" || offset < 0.3 - 0.001),
                    returnLag: mutation == "anchor_gap" && abs(offset + 0.3) < 0.001 ? 0.01 : 0.28
                )
            }
            if ["late_decrease", "increasing_dim", "long_span", "excess_frozen"].contains(mutation) {
                samples = nonFadeDimSamples(signal: mutation)
            }
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53, samples: samples, intervalSeconds: 12
                ), mutation
            ) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure",
                    "\(mutation): \(error.localizedDescription)"
                )
            }
        }
    }

    func testTVOSPauseRejectsInvalidRequestClockOrBaseline() {
        let valid = tvosFadeSamples(start: 13.2)
        let invalidTime = [watchSample(request: .nan, mark: "A5")] + valid
        for (baseline, interval, samples) in [
            (Double.nan, 12.0, valid), (0.0, 12.0, valid), (0.53, 0.0, valid),
            (0.53, 12.0, invalidTime), (0.53, 12.0, []), (0.53, 12.0, Array(valid.reversed()))
        ] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: baseline, samples: samples, intervalSeconds: interval
                )
            ) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "tvOS pause-continue evidence is invalid; invalid timing or original photo brightness evidence"
                )
            }
        }
    }

    func testTVOSPauseRescuesOneDimMatchOnlyWithDecodedPhotoDecline() throws {
        for proofStatus in ["MATCH", "UNRECOGNIZABLE"] {
            let samples = tvosRescueSamples(proofStatus: proofStatus)
            let evidence = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A1", baselineLuma: 0.497, samples: samples, intervalSeconds: 10,
                rescuePolicy: tvosRescuePolicy()
            )
            let rescue = try XCTUnwrap(evidence.rescue)
            XCTAssertEqual(evidence.start.requestElapsed, 10, accuracy: 0.001)
            XCTAssertEqual(rescue.dim.requestElapsed, 10.25, accuracy: 0.001)
            XCTAssertEqual(rescue.proof.returnElapsed, 10.74, accuracy: 0.001)
            XCTAssertEqual(rescue.proof.status, proofStatus)
        }
    }

    func testTVOSPauseRescueRejectsUnreadableUnboundAndNonPhotoEvidence() throws {
        for mutation in [
            "unreadable", "undrawn", "nil_pixels", "nil_q95", "nil_core", "black_proxy", "wrong_image", "wrong_state",
            "core", "gap",
            "calibration", "rising_q95", "rising_mean", "excess_ambiguous", "long_span",
            "shallow_proof", "bright_proof", "no_first_half", "unrecognized_dim", "wrong_required_mark"
        ] {
            var samples = tvosRescueSamples(cadence: mutation == "long_span" ? 0.6 : 0.25)
            let target =
                ["wrong_state", "unrecognized_dim"].contains(mutation)
                ? 41 : (mutation == "core" || mutation == "gap" ? 40 : 42)
            let original = samples[target]
            samples[target] = rescueSample(
                request: original.requestElapsed,
                mark: mutation == "black_proxy"
                    ? "BLACK" : (mutation == "unrecognized_dim" ? "UNRECOGNIZABLE" : original.mark),
                status: mutation == "black_proxy"
                    ? "BLACK" : (mutation == "unrecognized_dim" ? "UNRECOGNIZABLE" : original.status),
                luma: original.meanLuma,
                highlight: mutation == "nil_q95" ? nil : original.photoPixels?.highlightLuma,
                core: mutation == "nil_core"
                    ? nil : (mutation == "core" ? 0.059 : original.photoPixels?.whiteCoreFraction),
                controls: mutation != "wrong_state",
                returnLag: mutation == "gap" ? 0.05 : 0.24,
                decodedMean: mutation == "wrong_image" ? 0 : original.meanLuma,
                hasPixels: mutation != "nil_pixels",
                notes: ["unreadable", "undrawn"].contains(mutation) ? [mutation] : []
            )
            if mutation == "shallow_proof" || mutation == "bright_proof" {
                for index in 42..<samples.count where samples[index].mark != "A2" {
                    samples[index] = rescueSample(
                        request: samples[index].requestElapsed, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE",
                        luma: mutation == "shallow_proof" ? 0.443 : 0.41,
                        highlight: mutation == "bright_proof" ? 243 : 212)
                }
            }
            if mutation == "no_first_half" {
                for index in samples.indices where samples[index].requestElapsed <= 5 {
                    samples[index] = rescueSample(
                        request: samples[index].requestElapsed, luma: samples[index].meanLuma,
                        highlight: 255, core: 0.064, controls: false)
                }
            }
            if mutation == "calibration" {
                samples[4] = rescueSample(request: 1, luma: 0.472, highlight: 254)
            }
            if mutation == "rising_q95" || mutation == "rising_mean" {
                samples[42] = rescueSample(
                    request: 10.5, luma: mutation == "rising_mean" ? 0.46 : 0.45,
                    highlight: mutation == "rising_q95" ? 248 : 243)
                samples[43] = rescueSample(
                    request: 10.75, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.41, highlight: 212)
            }
            if mutation == "excess_ambiguous" {
                samples[41] = rescueSample(request: 10.25, luma: 0.4715, highlight: 253)
                samples[42] = rescueSample(request: 10.5, luma: 0.4714, highlight: 253)
                samples[43] = rescueSample(request: 10.75, luma: 0.455, highlight: 247)
                samples[44] = rescueSample(
                    request: 11, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.41, highlight: 212)
            }
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A1", baselineLuma: 0.497, samples: samples, intervalSeconds: 10,
                    rescuePolicy: tvosRescuePolicy(requiredMark: mutation == "wrong_required_mark" ? "A2" : "A1")
                ), mutation
            ) { XCTAssertEqual($0.localizedDescription, self.tvosLateMessage, mutation) }
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A1", baselineLuma: 0.497, samples: tvosRescueSamples(), intervalSeconds: 10,
                rescuePolicy: tvosRescuePolicy(isSinglePhoto: false)
            )
        ) { XCTAssertEqual($0.localizedDescription, self.tvosLateMessage) }

        var longCapture = tvosRescueSamples(anchor: 9.5)
        let proofIndex = try XCTUnwrap(longCapture.firstIndex { $0.requestElapsed == 10 })
        longCapture[proofIndex] = rescueSample(
            request: 10, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.41,
            highlight: 212, returnLag: 1.6)
        longCapture = longCapture.enumerated().filter { $0.offset <= proofIndex || $0.element.requestElapsed >= 11.6 }
            .map(\.element)
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A1", baselineLuma: 0.497, samples: longCapture, intervalSeconds: 10,
                rescuePolicy: tvosRescuePolicy())
        ) { XCTAssertEqual($0.localizedDescription, self.tvosLateMessage) }
    }

    func testTVOSPauseRescueRejectsOldPhotoRecoveryAndUnreadablePostProofFrames() {
        for mutation in ["rising_old_photo", "reappearing_old_photo", "undrawn"] {
            var samples = tvosRescueSamples(proofStatus: "MATCH")
            if mutation == "rising_old_photo" {
                samples[43] = rescueSample(request: 10.75, luma: 0.4, highlight: 213)
            } else if mutation == "reappearing_old_photo" {
                samples[44] = rescueSample(request: 11, luma: 0.29, highlight: 159)
            } else {
                samples[43] = rescueSample(
                    request: 10.75, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.3,
                    highlight: 160, notes: ["undrawn"])
            }
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A1", baselineLuma: 0.497, samples: samples, intervalSeconds: 10,
                    rescuePolicy: tvosRescuePolicy()
                ), mutation
            ) { XCTAssertEqual($0.localizedDescription, self.tvosLateMessage, mutation) }
        }
    }

    func testTVOSPauseRescueRejectsEarlyAndLateIntervals() {
        for (dim, message) in [(7.95, tvosEarlyMessage), (12.05, tvosLateMessage)] {
            let samples = tvosRescueSamples(anchor: dim - 0.25, newStart: max(12.01, dim + 1.76))
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                    continueMark: "A1", baselineLuma: 0.497, samples: samples, intervalSeconds: 10,
                    rescuePolicy: tvosRescuePolicy()
                )
            ) { XCTAssertEqual($0.localizedDescription, message) }
        }
    }

    func testTVOSPauseRescueKeepsOriginalPassAndItsFourSecondOrigin() throws {
        var samples = tvosRescueSamples(proofStatus: "MATCH", newStart: 12.76)
        samples[40] = rescueSample(request: 10, luma: 0.497, highlight: 255, core: 0.064)
        let original = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
            continueMark: "A1", baselineLuma: 0.497, samples: samples, intervalSeconds: 10)
        let augmented = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
            continueMark: "A1", baselineLuma: 0.497, samples: samples, intervalSeconds: 10,
            rescuePolicy: tvosRescuePolicy())
        XCTAssertEqual(augmented.start.requestElapsed, original.start.requestElapsed)
        XCTAssertEqual(augmented.stable.returnElapsed, original.stable.returnElapsed)
        XCTAssertEqual(augmented.stable.returnElapsed - augmented.start.requestElapsed, 4, accuracy: 0.001)
        XCTAssertNil(augmented.rescue)
    }

    func testTVOSPauseRescueKeepsConservativeFourSecondDeadline() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A1", baselineLuma: 0.497,
                samples: tvosRescueSamples(newStart: 12.76), intervalSeconds: 10,
                rescuePolicy: tvosRescuePolicy()
            )
        ) {
            XCTAssertEqual(
                $0.localizedDescription, "tvOS new photo must be stably identifiable within 4 s of transition start")
        }
    }

    func testTVOSPhotoPixelsLeaveIPhoneAndIPadVerdictsUnchanged() throws {
        let annotated = tvosRescueSamples()
        let plain = annotated.map { sample in
            AccessLifecycleContract.ContinueWatchSample(
                requestElapsed: sample.requestElapsed, returnElapsed: sample.returnElapsed,
                classifiedElapsed: sample.classifiedElapsed, status: sample.status, mark: sample.mark,
                meanLuma: sample.meanLuma, isControlBarVisible: sample.isControlBarVisible)
        }
        let original = try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
            continueMark: "A1", baselineLuma: 0.497, samples: plain, intervalSeconds: 10)
        let withPixels = try AccessLifecycleContract.assertIPhonePauseTimingEvidence(
            continueMark: "A1", baselineLuma: 0.497, samples: annotated, intervalSeconds: 10)
        XCTAssertEqual(withPixels.verdict, original.verdict)
        XCTAssertFalse(withPixels.isOfficialStartSigned)
        for samples in [plain, annotated] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                    continueMark: "A1", baselineLuma: 0.497, samples: samples, intervalSeconds: 10)
            ) {
                XCTAssertTrue($0.localizedDescription.hasPrefix("A continuous, reliable screenshot"))
            }
        }
    }

    func testTVOSPhotoRescueGeometryBoundCoversActualSinglePhotoPolicy() {
        let lifecycle = SceneLifecycleContract(
            configuredInterval: TimeInterval(AccessLifecycleContract.tvOSRequestedIntervalSeconds))
        let profile = SceneAnimationProfile(lifecycle: lifecycle)
        for direction in [SceneAnimationDirection.zoomIn, .zoomOut] {
            let before = profile.singlePhotoTransform(direction: direction, activeTime: 0, isMotionEnabled: true)
            let after = profile.singlePhotoTransform(
                direction: direction,
                activeTime: AccessLifecycleContract.TVOSPhotoMotionBounds.maximumSpanSeconds
                    + AccessLifecycleContract.timingToleranceSeconds,
                isMotionEnabled: true)
            XCTAssertLessThanOrEqual(
                abs(after.scale - before.scale) / 2,
                AccessLifecycleContract.TVOSPhotoMotionBounds.maximumMotionFractionPerAxis)
            XCTAssertEqual(before.translationInSlot, .zero)
            XCTAssertEqual(after.translationInSlot, .zero)
            XCTAssertEqual(after.anchorUnitPointInSlot, CGPoint(x: 0.5, y: 0.5))
        }
        XCTAssertGreaterThanOrEqual(
            AccessLifecycleContract.TVOSPhotoMotionBounds.whiteCoreErosionFractionPerAxis,
            2 * AccessLifecycleContract.TVOSPhotoMotionBounds.maximumMotionFractionPerAxis)
    }

    func testTVOSObservationPreservesVerdictsAndErrorBytesWhileRecordingFailureStages() {
        typealias Observation = AccessLifecycleContract.TVOSPauseTimingObservation
        let observation = Observation()
        func check(
            _ samples: [AccessLifecycleContract.ContinueWatchSample],
            mark: String = "A1", baseline: Double = 0.497, interval: Double = 10,
            policy: AccessLifecycleContract.TVOSFadeRescuePolicy? = nil,
            judge: Observation.JudgeStep, ran: Bool, stage: Observation.RescueStage,
            indices: [String: Int] = [:], file: StaticString = #filePath, line: UInt = #line
        ) {
            func outcome(_ sink: Observation?) -> [UInt8] {
                do {
                    let evidence = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                        continueMark: mark, baselineLuma: baseline, samples: samples,
                        intervalSeconds: interval, rescuePolicy: policy, observation: sink)
                    let times = [
                        evidence.start.requestElapsed, evidence.stable.returnElapsed,
                        evidence.rescue?.anchor.requestElapsed ?? -1,
                        evidence.rescue?.dim.requestElapsed ?? -1, evidence.rescue?.proof.returnElapsed ?? -1
                    ].map(\.bitPattern)
                    return Array("pass:\(times)".utf8)
                } catch {
                    return Array("\(String(reflecting: error)):\(error.localizedDescription)".utf8)
                }
            }
            XCTAssertEqual(outcome(observation), outcome(nil), file: file, line: line)
            XCTAssertEqual(observation.judgeStep, judge, file: file, line: line)
            XCTAssertEqual(observation.rescueRan, ran, file: file, line: line)
            XCTAssertEqual(observation.rescueStage, stage, file: file, line: line)
            XCTAssertEqual(observation.indices, indices, file: file, line: line)
        }
        let rescued = tvosRescueSamples()
        let fullCandidate = ["anchor": 40, "dim": 41, "proof": 42]
        check(rescued, policy: tvosRescuePolicy(), judge: .late, ran: true, stage: .passed, indices: fullCandidate)
        check(rescued, policy: tvosRescuePolicy(isSinglePhoto: false), judge: .late, ran: true, stage: .ineligible)
        check(rescued, judge: .late, ran: false, stage: .ineligible)
        check(rescued, baseline: .nan, judge: .other, ran: false, stage: .notRun)
        check(
            [watchSample(request: 0, mark: "A1"), watchSample(request: 9, mark: "A1")],
            judge: .noStableNewPhoto, ran: false, stage: .notRun)
        check(
            tvosFadeSamples(start: 10), mark: "A5", baseline: 0.53, interval: 12,
            judge: .passed, ran: false, stage: .notRun)
        check(
            earlyFadeWithFrozenDimSamples(), mark: "A5", baseline: 0.53, interval: 12,
            judge: .early, ran: false, stage: .notRun)

        var noDim = rescued
        noDim[41] = rescueSample(request: 10.25, luma: 0.455, highlight: 255, core: 0.064)
        check(noDim, policy: tvosRescuePolicy(), judge: .late, ran: true, stage: .noDim, indices: ["anchor": 41])
        var noProof = rescued
        noProof[42] = rescueSample(
            request: 10.5, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.46, highlight: 212)
        check(
            noProof, policy: tvosRescuePolicy(), judge: .late, ran: true, stage: .noProof,
            indices: ["anchor": 40, "dim": 41])
        check(
            tvosRescueSamples(cadence: 0.6), policy: tvosRescuePolicy(), judge: .late, ran: true, stage: .span,
            indices: ["anchor": 40, "dim": 41])
        var recovered = tvosRescueSamples(proofStatus: "MATCH")
        recovered[43] = rescueSample(request: 10.75, luma: 0.4, highlight: 213)
        check(
            recovered, policy: tvosRescuePolicy(), judge: .late, ran: true, stage: .recovery,
            indices: fullCandidate)
        check(
            tvosRescueSamples(anchor: 7.7), policy: tvosRescuePolicy(), judge: .late, ran: true,
            stage: .windowEarly, indices: ["anchor": 31, "dim": 32, "proof": 33])
        check(
            tvosRescueSamples(anchor: 11.8, newStart: 13.81), policy: tvosRescuePolicy(), judge: .late, ran: true,
            stage: .windowLate, indices: ["anchor": 48, "dim": 49, "proof": 50])
        check(
            tvosRescueSamples(newStart: 12.76), policy: tvosRescuePolicy(), judge: .late, ran: true,
            stage: .fourSecond, indices: fullCandidate)
        var originalFourSecond = tvosRescueSamples(proofStatus: "MATCH", newStart: 12.77)
        originalFourSecond[40] = rescueSample(request: 10, luma: 0.497, highlight: 255, core: 0.064)
        check(originalFourSecond, policy: tvosRescuePolicy(), judge: .fourSecond, ran: false, stage: .notRun)
        // Reuse the sink after failures to prove a later pass cannot retain stale candidate indices.
        check(
            tvosFadeSamples(start: 10), mark: "A5", baseline: 0.53, interval: 12,
            judge: .passed, ran: false, stage: .notRun)
    }

    private var tvosLateMessage: String {
        "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
    }

    private var tvosEarlyMessage: String {
        "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
    }

    private func tvosRescuePolicy(isSinglePhoto: Bool = true, requiredMark: String = "A1")
        -> AccessLifecycleContract.TVOSFadeRescuePolicy
    {
        .init(
            requiredMark: requiredMark, isSinglePhotoModeVerified: isSinglePhoto,
            plateauHighlightLuma: 255, minimumDimHighlightDrop: 3, proofHighlightRatio: 0.95,
            minimumMeanDrop: 0.030, minimumWhiteCoreFraction: 0.06,
            maximumAnchorToProofRequestSeconds: 1, maximumAnchorToProofReturnSeconds: 2)
    }

    private func rescueSample(
        request: Double, mark: String = "A1", status: String = "MATCH", luma: Double,
        highlight: Int?, core: Double? = 0, controls: Bool = true, returnLag: Double = 0.24,
        decodedMean: Double? = nil, hasPixels: Bool = true, notes: [String] = []
    ) -> AccessLifecycleContract.ContinueWatchSample {
        .init(
            requestElapsed: request, returnElapsed: request + returnLag, classifiedElapsed: request + returnLag + 0.1,
            status: status, mark: mark, meanLuma: luma, isControlBarVisible: controls,
            photoPixels: hasPixels
                ? .init(highlightLuma: highlight, whiteCoreFraction: core, decodedMeanLuma: decodedMean ?? luma) : nil,
            identityNotes: notes)
    }

    private func tvosRescueSamples(
        anchor: Double = 10, proofStatus: String = "UNRECOGNIZABLE", newStart: Double = 12.01,
        cadence: Double = 0.25
    ) -> [AccessLifecycleContract.ContinueWatchSample] {
        let old = stride(from: 0.0, to: anchor - 0.001, by: 0.25).map { request in
            rescueSample(
                request: request, luma: request == 0 ? 0.497 : 0.472, highlight: 255, core: 0.064,
                returnLag: min(0.24, anchor - request))
        }
        let fade = [
            rescueSample(request: anchor, luma: 0.472, highlight: 255, core: 0.064, returnLag: cadence - 0.01),
            rescueSample(request: anchor + cadence, luma: 0.455, highlight: 247, returnLag: cadence - 0.01),
            rescueSample(
                request: anchor + 2 * cadence, mark: proofStatus == "MATCH" ? "A1" : "UNRECOGNIZABLE",
                status: proofStatus, luma: 0.41, highlight: 212, returnLag: cadence - 0.01)
        ]
        let middle = stride(from: anchor + 3 * cadence, through: newStart - 0.24, by: 0.25).map { request in
            rescueSample(request: request, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.3, highlight: 160)
        }
        let next = (0...6).map { index in
            rescueSample(request: newStart + Double(index) * 0.25, mark: "A2", luma: 0.6, highlight: 212)
        }
        return old + fade + middle + next
    }

    func tvosFadeSamples(start: TimeInterval) -> [AccessLifecycleContract.ContinueWatchSample] {
        let oldCount = Int(start / 0.3)
        let old = (1...oldCount).reversed().map { index in
            watchSample(request: start - Double(index) * 0.3, mark: "A5", luma: 0.53, returnLag: 0.28)
        }
        let fade = [0.49, 0.35, 0.16].enumerated().map { index, luma in
            watchSample(request: start + Double(index) * 0.3, mark: "A5", luma: luma, returnLag: 0.28)
        }
        let black = watchSample(request: start + 0.9, mark: "BLACK", status: "BLACK", luma: 0.01, returnLag: 0.28)
        let darkNew = watchSample(request: start + 1.2, mark: "A1", luma: 0.15, returnLag: 0.28)
        let stable = (0...5).map { index in
            watchSample(request: start + 1.5 + Double(index) * 0.3, mark: "A1", luma: 0.47, returnLag: 0.28)
        }
        return old + fade + [black, darkNew] + stable
    }

    func testFirstTransitionStartRejectsEarlyLateBlackAndCrossWindow() {
        let early = [
            watchSample(request: 5.0, mark: "A2"),
            watchSample(request: 8.0, mark: "A3")
        ]
        XCTAssertEqual(
            AccessLifecycleContract.assessFirstTransitionStart(
                continueMark: "A2",
                baselineLuma: 0.5,
                samples: early,
                intervalSeconds: 12
            ),
            .tooEarly(requestElapsed: 8.0, mark: "A3")
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.officialStartSigned(
                for: .tooEarly(requestElapsed: 8.0, mark: "A3"),
                continueMark: "A2",
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("before T-2"))
        }

        let late = [
            watchSample(request: 5.0, mark: "A2"),
            watchSample(request: 11.0, mark: "A2"),
            watchSample(request: 16.0, mark: "A3")
        ]
        XCTAssertEqual(
            AccessLifecycleContract.assessFirstTransitionStart(
                continueMark: "A2",
                baselineLuma: 0.5,
                samples: late,
                intervalSeconds: 12
            ),
            .tooLate(requestElapsed: 16.0, mark: "A3")
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.officialStartSigned(
                for: .tooLate(requestElapsed: 16.0, mark: "A3"),
                continueMark: "A2",
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("test timing failure"))
        }

        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIdentifiableNewImagePresent(
                continueMark: "A2",
                confirmedMark: nil,
                confirmedStatus: nil
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Black screen without a new photo"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIdentifiableNewImagePresent(
                continueMark: "A2",
                confirmedMark: "BLACK",
                confirmedStatus: "BLACK"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Black screen without a new photo"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertWindowUsesRequestElapsed(
                requestElapsed: 13.0,
                returnElapsed: 14.5,
                classifiedElapsed: 14.8,
                elapsedUsedForWindow: 14.5
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Evidence crossing the window"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertWindowUsesRequestElapsed(
                requestElapsed: 13.0,
                returnElapsed: 14.5,
                classifiedElapsed: 14.8,
                elapsedUsedForWindow: 13.0
            )
        )
    }

    func testUncertainStartCannotDefaultOfficialPass() throws {
        let uncertainThenLate = [
            watchSample(request: 5.0, mark: "A5", luma: 0.55),
            watchSample(request: 12.9, mark: "A5", luma: 0.40),
            watchSample(request: 14.4, mark: "A1", luma: 0.42)
        ]
        let verdict = AccessLifecycleContract.assessFirstTransitionStart(
            continueMark: "A5",
            baselineLuma: 0.55,
            samples: uncertainThenLate,
            intervalSeconds: 12
        )
        guard case .pendingVideoReview = verdict else {
            return XCTFail(
                "After a luma drop in the window, a new image outside the window must await video review, not be judged tooLate or auto-passed"
            )
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertFirstTransitionStartOfficialPass(
                verdict: verdict,
                isOfficiallySigned: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("pending video review"))
        }
        XCTAssertFalse(
            try AccessLifecycleContract.officialStartSigned(
                for: verdict,
                continueMark: "A5",
                intervalSeconds: 12
            )
        )
    }

    func testNewImageConfirmationIsSeparateFromStartAndMayFollowWindow() throws {
        let mixThenZoomedNew = [
            watchSample(request: 5.0, mark: "A5", status: "MATCH"),
            watchSample(request: 12.9, mark: "TRANSITION", status: "TRANSITION", luma: 0.28),
            watchSample(request: 14.7, mark: "A1", status: "MATCH", luma: 0.41)
        ]
        let start = AccessLifecycleContract.assessFirstTransitionStart(
            continueMark: "A5",
            baselineLuma: 0.5,
            samples: mixThenZoomedNew,
            intervalSeconds: 12
        )
        XCTAssertEqual(
            start,
            .detected(requestElapsed: 12.9, mark: "TRANSITION", status: "TRANSITION")
        )
        XCTAssertTrue(
            try AccessLifecycleContract.officialStartSigned(
                for: start,
                continueMark: "A5",
                intervalSeconds: 12
            )
        )
        let confirmed = AccessLifecycleContract.firstIdentifiableNewImage(
            continueMark: "A5",
            samples: mixThenZoomedNew
        )
        XCTAssertEqual(confirmed?.requestElapsed, 14.7)
        XCTAssertEqual(confirmed?.mark, "A1")
        try AccessLifecycleContract.assertIdentifiableNewImagePresent(
            continueMark: "A5",
            confirmedMark: confirmed?.mark,
            confirmedStatus: confirmed?.status
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A5",
                earlyMark: "A5",
                elapsedSeconds: 5.0,
                intervalSeconds: 12
            )
        )
    }

    func testStableConfirmationRejectsDarkMisclassificationAndWaitsForBrightSequence() {
        var samples = [watchSample(request: 13.8, mark: "A2", luma: 0.065, returnLag: 0.1)]
        XCTAssertNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples))
        samples.append(watchSample(request: 14.1, mark: "A1", luma: 0.4, returnLag: 0.1))
        samples.append(watchSample(request: 14.3, mark: "A1", luma: 0.4, returnLag: 0.1))
        XCTAssertNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples))
        for time in [14.5, 14.7, 14.9, 15.1] {
            samples.append(watchSample(request: time, mark: "A1", luma: 0.4, returnLag: 0.1))
        }
        XCTAssertEqual(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples)?.mark, "A1")
    }

    func testStableConfirmationRestartsOnUnknownDifferentAndDarkFrames() {
        for interruption in [
            watchSample(request: 14.5, mark: "A2", returnLag: 0.1),
            watchSample(request: 14.5, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", returnLag: 0.1),
            watchSample(request: 14.5, mark: "A1", luma: 0.05, returnLag: 0.1)
        ] {
            let samples =
                [14.1, 14.3].map { watchSample(request: $0, mark: "A1", returnLag: 0.1) }
                + [interruption]
                + [14.7, 14.9, 15.1].map { watchSample(request: $0, mark: "A1", returnLag: 0.1) }
            XCTAssertNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples))
            let uninterrupted = [14.1, 14.3, 14.5, 14.7, 14.9, 15.1].map {
                watchSample(request: $0, mark: "A1", returnLag: 0.1)
            }
            XCTAssertNotNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: uninterrupted))
        }
    }

    func testStableConfirmationRejectsSamplingGapsAndInvalidTimes() {
        for samples in [
            [watchSample(request: 14, mark: "A1"), watchSample(request: 17, mark: "A1")],
            [watchSample(request: 14, mark: "A1", returnLag: 0.1), watchSample(request: 14.9, mark: "A1")],
            [watchSample(request: 14, mark: "A1"), watchSample(request: 14.1, mark: "A1")],
            [watchSample(request: .nan, mark: "A1")]
        ] {
            XCTAssertNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples))
        }
    }

    func testIPadPauseRequiresConservativeTransitionWindowAndOneSecondStableImage() throws {
        let samples =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.2, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ]
            + (0...8).map { index in
                watchSample(request: 10.3 + Double(index) * 0.15, mark: "A1", returnLag: 0.1, classifyLag: 0.1)
            }

        let evidence = try AccessLifecycleContract.assertIPadPauseTimingEvidence(
            continueMark: "A5",
            baselineLuma: 0.5,
            samples: samples,
            intervalSeconds: 12
        )

        XCTAssertEqual(evidence.earliestTransitionElapsed, 10.1, accuracy: 0.001)
        XCTAssertEqual(evidence.latestTransitionElapsed, 10.25, accuracy: 0.001)
        XCTAssertEqual(evidence.stableImageRequestElapsed, 11.5, accuracy: 0.001)
        XCTAssertEqual(evidence.stableImageReturnElapsed, 11.6, accuracy: 0.001)
        XCTAssertEqual(evidence.stableImageDelaySeconds, 1.4, accuracy: 0.001)
        XCTAssertLessThanOrEqual(evidence.stableImageDelaySeconds, 4.0)
    }

    func testIPadPauseReplaysSustainedFadeAndIgnoresSmallLumaNoise() throws {
        let oldFrames = [
            watchSample(request: 8.249, mark: "A5", luma: 0.5343, returnLag: 0.18),
            watchSample(request: 8.445, mark: "A5", luma: 0.5319, returnLag: 0.18),
            watchSample(request: 8.636, mark: "A5", luma: 0.5306, returnLag: 0.18),
            watchSample(request: 8.830, mark: "A5", luma: 0.5307, returnLag: 0.18),
            watchSample(request: 9.036, mark: "A5", luma: 0.5307, returnLag: 0.18),
            watchSample(request: 9.228, mark: "A5", luma: 0.5307, returnLag: 0.18),
            watchSample(request: 9.419, mark: "A5", luma: 0.5307, returnLag: 0.18),
            watchSample(request: 9.608, mark: "A5", luma: 0.5308, returnLag: 0.18),
            watchSample(request: 9.798, mark: "A5", luma: 0.5309, returnLag: 0.18),
            watchSample(request: 9.987, mark: "A5", luma: 0.5310, returnLag: 0.18),
            watchSample(request: 10.175, mark: "A5", luma: 0.5310, returnLag: 0.18),
            watchSample(request: 10.364, mark: "A5", luma: 0.5310, returnLag: 0.18)
        ]
        let fadeFrames = [
            watchSample(request: 10.551, mark: "A5", luma: 0.49, returnLag: 0.18),
            watchSample(request: 10.739, mark: "A5", luma: 0.35, returnLag: 0.18),
            watchSample(request: 10.930, mark: "A5", luma: 0.16, returnLag: 0.18),
            watchSample(request: 11.118, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.02, returnLag: 0.18)
        ]
        let stableFrames = (0...10).map { index in
            watchSample(request: 11.333 + Double(index) * 0.2, mark: "A1", luma: 0.47, returnLag: 0.18)
        }
        let samples = oldFrames + fadeFrames + stableFrames
        let evidence = try AccessLifecycleContract.assertIPadPauseTimingEvidence(
            continueMark: "A5",
            baselineLuma: 0.535,
            samples: samples,
            intervalSeconds: 12
        )

        XCTAssertEqual(evidence.transitionStartRequestElapsed, 10.551, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(evidence.earliestTransitionElapsed, 10)
        XCTAssertLessThanOrEqual(evidence.latestTransitionElapsed, 14)
        XCTAssertLessThanOrEqual(evidence.stableImageDelaySeconds, 4)
    }

    func testIPadPauseRejectsRecoveredDimFrameDimOnlyAndControlBarOnlyChange() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53,
                samples: slowEarlyFadeWithoutFrozenDimSamples(), intervalSeconds: 12
            )
        ) {
            XCTAssertEqual(
                $0.localizedDescription,
                "iPad transition: conservative screenshot range must lie fully within T±2 s"
            )
        }
        for signal in ["late_decrease", "increasing_dim", "long_span", "excess_frozen"] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53,
                    samples: nonFadeDimSamples(signal: signal), intervalSeconds: 12
                ), signal
            ) { error in
                if signal == "increasing_dim" {
                    XCTAssertTrue(
                        error.localizedDescription.hasPrefix(
                            "A continuous, reliable screenshot of the previous photo must precede the iPad transition start;"
                        ), signal
                    )
                    return
                }
                XCTAssertEqual(
                    error.localizedDescription,
                    "iPad transition: conservative screenshot range must lie fully within T±2 s", signal
                )
            }
        }
        let recoveredTwoDimFrames = (0...39).map { index in
            let luma: Double
            switch index {
            case 1, 12: luma = 0.49
            case 2: luma = 0.45
            case 13: luma = 0.35
            case 14..<26: luma = 0.02
            case 26...: luma = 0.47
            default: luma = 0.53
            }
            let mark = index >= 26 ? "A1" : (index >= 14 ? "UNRECOGNIZABLE" : "A5")
            return watchSample(
                request: 13.4 + Double(index) * 0.1, mark: mark,
                status: mark == "UNRECOGNIZABLE" ? mark : "MATCH", luma: luma, returnLag: 0.05
            )
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: recoveredTwoDimFrames, intervalSeconds: 12
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "iPad transition: conservative screenshot range must lie fully within T±2 s"
            )
        }

        let recoveredDim = [
            watchSample(request: 10.1, mark: "A5", luma: 0.53, returnLag: 0.05),
            watchSample(request: 10.2, mark: "A5", luma: 0.49, returnLag: 0.05),
            watchSample(request: 10.3, mark: "A5", luma: 0.53, returnLag: 0.05),
            watchSample(request: 10.4, mark: "A5", luma: 0.53, returnLag: 0.05)
        ]
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: recoveredDim, intervalSeconds: 12
            )
        )

        let dimOnly = [
            watchSample(request: 10.1, mark: "A5", luma: 0.53, returnLag: 0.05),
            watchSample(request: 10.2, mark: "A5", luma: 0.49, returnLag: 0.05),
            watchSample(request: 10.3, mark: "A5", luma: 0.35, returnLag: 0.05),
            watchSample(request: 10.4, mark: "A5", luma: 0.16, returnLag: 0.05),
            watchSample(request: 10.5, mark: "BLACK", status: "BLACK", luma: 0.01, returnLag: 0.05)
        ]
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: dimOnly, intervalSeconds: 12
            )
        )

        for (onset, controlsChangeOffset) in [("TRANSITION", 0.0), ("DIMMING", 0.3)] {
            let controlsOnly = tvosFadeSamples(start: 12.3).map { sample in
                let isTransition = onset == "TRANSITION" && abs(sample.requestElapsed - 12.3) < 0.001
                return watchSample(
                    request: sample.requestElapsed,
                    mark: isTransition ? "TRANSITION" : sample.mark,
                    status: isTransition ? "TRANSITION" : sample.status, luma: sample.meanLuma,
                    isControlBarVisible: sample.requestElapsed - 12.3 < controlsChangeOffset - 0.001, returnLag: 0.28
                )
            }
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.53, samples: controlsOnly, intervalSeconds: 12
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("reliable screenshot of the previous photo"))
            }
        }
    }

    func testIPadPauseRejectsEarlyOrLateConservativeTransitionBounds() {
        let stableFrames = (0...8).map { index in
            watchSample(request: 10.1 + Double(index) * 0.15, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
        }
        let early =
            [
                watchSample(request: 9.9, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.0, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ] + stableFrames
        let late =
            [
                watchSample(request: 13.8, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 13.95, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.1, classifyLag: 0.1)
            ]
            + (0...8).map { index in
                watchSample(request: 14.1 + Double(index) * 0.15, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
            }

        for samples in [early, late] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.5, samples: samples, intervalSeconds: 12
                )
            )
        }
    }

    func testIPadPauseIncludesPressLatencyInConservativeLowerBound() {
        let samples =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05),
                watchSample(request: 10.2, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05)
            ]
            + (0...8).map { index in
                watchSample(request: 10.3 + Double(index) * 0.15, mark: "A1", returnLag: 0.05)
            }

        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5",
                baselineLuma: 0.5,
                samples: samples,
                intervalSeconds: 12,
                pressReturnedElapsed: 0.2
            )
        )
    }

    func testIPadPauseRejectsUncertainOrMissingTransitionAndInsufficientStableFrames() {
        let unknownBeforeStart =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(
                    request: 10.2, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.3, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ]
            + (0...8).map { index in
                watchSample(request: 10.4 + Double(index) * 0.15, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
            }
        let insufficientStableFrames =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.2, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ]
            + (0...5).map { index in
                watchSample(request: 10.3 + Double(index) * 0.15, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
            }
        let missingStart = [watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1)]

        for samples in [unknownBeforeStart, insufficientStableFrames, missingStart] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.5, samples: samples, intervalSeconds: 12
                )
            )
        }
    }

    func testIPadPauseRejectsStableImageMoreThanFourSecondsAfterTransitionStart() {
        let samples =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.2, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ]
            + (0...40).map { index in
                watchSample(
                    request: 10.3 + Double(index) * 0.1, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05,
                    classifyLag: 0.1)
            }
            + (0...12).map { index in
                watchSample(request: 14.4 + Double(index) * 0.09, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
            }

        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.5, samples: samples, intervalSeconds: 12
            )
        )
    }

    func testRecordingMustContinuePastIdentityTimeoutWithoutNewImage() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertRecordingDidNotStopAtIdentityTimeout(
                lastSampleRequestElapsed: 14.0,
                hasConfirmedNewImage: false,
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("T+2"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertRecordingDidNotStopAtIdentityTimeout(
                lastSampleRequestElapsed: 14.7,
                hasConfirmedNewImage: true,
                intervalSeconds: 12
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertRecordingDidNotStopAtIdentityTimeout(
                lastSampleRequestElapsed: 18.0,
                hasConfirmedNewImage: false,
                intervalSeconds: 12
            )
        )
        XCTAssertEqual(
            AccessLifecycleContract.continueWatchRecordingDeadline(intervalSeconds: 12),
            26
        )
        XCTAssertEqual(
            AccessLifecycleContract.continueWatchDenseCaptureDeadline(intervalSeconds: 12),
            18
        )
        XCTAssertEqual(AccessLifecycleContract.continueCaptureSlackSeconds, 2)
    }

    func testClickReturnTimeCannotReplacePressOrigin() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertClickTimesRecordedSeparately(
                pressIssuedElapsed: 0,
                pressReturnedElapsed: 0.29,
                continueOriginElapsed: 0.29,
                didUseReturnedAsOrigin: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("click return"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertClickTimesRecordedSeparately(
                pressIssuedElapsed: 0,
                pressReturnedElapsed: 0.29,
                continueOriginElapsed: 0,
                didUseReturnedAsOrigin: false
            )
        )
    }

    func testZoomControlBarAndClassificationFailureAreNotStart() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "MATCH",
                mark: "A5",
                continueMark: "A5",
                isControlBarVisible: true
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "MATCH",
                mark: "A5",
                continueMark: "A5",
                isControlBarVisible: false
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "BLACK",
                mark: "BLACK",
                continueMark: "A5",
                isControlBarVisible: true
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "UNRECOGNIZABLE",
                mark: "UNRECOGNIZABLE",
                continueMark: "A5",
                isControlBarVisible: true
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "TRANSITION",
                mark: "TRANSITION",
                continueMark: "A5",
                isControlBarVisible: true
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "MATCH",
                mark: "A1",
                continueMark: "A5",
                isControlBarVisible: true
            )
        )
        let zoomOnly = [
            watchSample(request: 5.0, mark: "A5"),
            watchSample(request: 12.0, mark: "A5"),
            watchSample(request: 13.0, mark: "A5")
        ]
        XCTAssertEqual(
            AccessLifecycleContract.assessFirstTransitionStart(
                continueMark: "A5",
                baselineLuma: 0.5,
                samples: zoomOnly,
                intervalSeconds: 12
            ),
            .missing
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.officialStartSigned(
                for: .missing,
                continueMark: "A5",
                intervalSeconds: 12
            )
        )
    }

    func watchSample(
        request: TimeInterval,
        mark: String,
        status: String = "MATCH",
        luma: Double = 0.5,
        isControlBarVisible: Bool = true,
        returnLag: TimeInterval = 0.3,
        classifyLag: TimeInterval = 0.8
    ) -> AccessLifecycleContract.ContinueWatchSample {
        AccessLifecycleContract.ContinueWatchSample(
            requestElapsed: request,
            returnElapsed: request + returnLag,
            classifiedElapsed: request + classifyLag,
            status: status,
            mark: mark,
            meanLuma: luma,
            isControlBarVisible: isControlBarVisible
        )
    }
}
