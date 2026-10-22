import XCTest

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

    func testTVOSPauseUsesSettledFirstHalfBaselineWithoutDelayingOriginalEarlyOnset() throws {
        let samples = tvosDriftingBaselineSamples(start: 10.3)
        let evidence = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
            continueMark: "A1", baselineLuma: 0.497043, samples: samples, intervalSeconds: 10
        )
        XCTAssertEqual(evidence.start.requestElapsed, 10.3, accuracy: 0.001)
        XCTAssertEqual(evidence.start.mark, "A1")
        XCTAssertGreaterThan(evidence.stable.requestElapsed, 12)

        let hiddenFade = samples.map { sample in
            watchSample(
                request: sample.requestElapsed, mark: sample.mark, status: sample.status, luma: sample.meanLuma,
                isControlBarVisible: sample.requestElapsed < 8.2, returnLag: 0.19
            )
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A1", baselineLuma: 0.497043, samples: hiddenFade, intervalSeconds: 10
            )
        ) { XCTAssertTrue($0.localizedDescription.hasPrefix("No automatic photo change was captured within T±2")) }

        // The calibrated threshold would first sign 8.1; the original threshold must still reject 7.9.
        let early = tvosDriftingBaselineSamples(start: 7.9, hasControlBarHide: false)
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A1", baselineLuma: 0.497043, samples: early, intervalSeconds: 10
            )
        ) { XCTAssertTrue($0.localizedDescription.hasPrefix("Automatic photo change occurred before T-2")) }
    }

    func testTVOSPauseCalibrationRejectsDimmingUnsettledAndPostHalfFrames() {
        for signal in [
            "already_dim", "gradual_dim", "brighter", "changing_controls", "gap", "unknown", "post_half",
            "half_boundary", "short_stability"
        ] {
            let samples = (0...10).map { index in
                let request =
                    signal == "half_boundary"
                    ? 3.8125 + Double(index) * 0.25
                    : (signal == "post_half" ? 5.0 : 0.2) + Double(index) * (signal == "gap" ? 0.4 : 0.2)
                let luma: Double
                switch signal {
                case "already_dim": luma = index == 0 ? 0.497043 : 0.460
                case "gradual_dim": luma = 0.497043 - Double(index) * 0.005
                case "brighter": luma = 0.52
                default: luma = 0.486
                }
                return watchSample(
                    request: request, mark: signal == "unknown" && index == 2 ? "UNRECOGNIZABLE" : "A1",
                    status: signal == "unknown" && index == 2 ? "UNRECOGNIZABLE" : "MATCH", luma: luma,
                    isControlBarVisible: signal != "changing_controls" || index.isMultiple(of: 2),
                    returnLag: signal == "half_boundary" ? 0.1875 : 0.19
                )
            }
            let bounded = signal == "short_stability" ? Array(samples.prefix(4)) : samples
            XCTAssertTrue(
                AccessLifecycleContract.tvOSContinueCalibrationSamples(
                    continueMark: "A1", baselineLuma: 0.497043, samples: bounded, intervalSeconds: 10
                ).isEmpty,
                signal
            )
        }

        // An already-dimming first-half frame must never replace the earlier original onset.
        let early = tvosDriftingBaselineSamples(start: 2.0, hasControlBarHide: false)
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: "A1", baselineLuma: 0.497043, samples: early, intervalSeconds: 10
            )
        ) { XCTAssertTrue($0.localizedDescription.hasPrefix("Automatic photo change occurred before T-2")) }
    }

    private func tvosDriftingBaselineSamples(
        start: TimeInterval, hasControlBarHide: Bool = true
    ) -> [AccessLifecycleContract.ContinueWatchSample] {
        let firstHalf = (0...23).map { index in
            watchSample(
                request: 0.2 + Double(index) * 0.2, mark: "A1",
                luma: index == 0 ? 0.497043 : 0.486, returnLag: 0.19
            )
        }.filter { $0.requestElapsed < start - 0.2 - AccessLifecycleContract.timingToleranceSeconds }
        let preFade: [AccessLifecycleContract.ContinueWatchSample]
        if hasControlBarHide {
            preFade = [
                watchSample(request: 8.0, mark: "A1", luma: 0.474632, returnLag: 0.19),
                watchSample(request: 8.2, mark: "A1", luma: 0.470984, isControlBarVisible: false, returnLag: 0.19),
                watchSample(request: 8.4, mark: "A1", luma: 0.470190, isControlBarVisible: false, returnLag: 0.19),
                watchSample(request: 8.6, mark: "A1", luma: 0.469633, returnLag: 0.19),
                watchSample(request: start - 0.2, mark: "A1", luma: 0.467417, returnLag: 0.19)
            ]
        } else {
            preFade = [watchSample(request: start - 0.2, mark: "A1", luma: 0.486, returnLag: 0.19)]
        }
        let dimLumas = hasControlBarHide ? [0.448, 0.420, 0.390] : [0.470, 0.448, 0.420]
        let dim = dimLumas.enumerated().map { index, luma in
            watchSample(request: start + Double(index) * 0.2, mark: "A1", luma: luma, returnLag: 0.19)
        }
        let newPhoto = (0...6).map { index in
            watchSample(request: max(start + 2, 8.2) + Double(index) * 0.2, mark: "A2", luma: 0.60, returnLag: 0.19)
        }
        return firstHalf + preFade + dim + newPhoto
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
