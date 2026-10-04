import XCTest

extension SettingsResumeContractTests {
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

        let controlsPrefix: [AccessLifecycleContract.ContinueWatchSample] = (0...40).map { index in
            let luma: Double
            switch index {
            case ..<22: luma = 0.53
            case 22: luma = 0.49
            case 23: luma = 0.35
            case 40: luma = 0.47
            default: luma = 0.16
            }
            return watchSample(
                request: 10.1 + Double(index) * 0.1,
                mark: index == 40 ? "A1" : "A5",
                luma: luma,
                isControlBarVisible: index < 22,
                returnLag: 0.05
            )
        }
        let latePhotoFrames: [AccessLifecycleContract.ContinueWatchSample] = (1...12).map { index in
            watchSample(
                request: 14.1 + Double(index) * 0.1, mark: "A1", luma: 0.47, isControlBarVisible: false, returnLag: 0.05
            )
        }
        let controlsOnly = controlsPrefix + latePhotoFrames
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: controlsOnly, intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("reliable screenshot of the previous photo"))
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
