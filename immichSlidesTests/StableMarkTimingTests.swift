import XCTest

final class StableMarkTimingTests: XCTestCase {
    func testConfirmWaitIsReservedInsideRemainingBudget() {
        XCTAssertEqual(AccessLifecycleContract.newStableMarkPollInterval, 0.1, accuracy: 0.0001)
        XCTAssertEqual(AccessLifecycleContract.newStableMarkConfirmWindow, 0.8, accuracy: 0.0001)
        XCTAssertEqual(AccessLifecycleContract.newStableMarkMinimumLuma, 0.20, accuracy: 0.0001)
        XCTAssertEqual(AccessLifecycleContract.confirmWait(remaining: 2), 0.8, accuracy: 0.0001)
        XCTAssertEqual(AccessLifecycleContract.confirmWait(remaining: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AccessLifecycleContract.confirmWait(remaining: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(AccessLifecycleContract.pollWait(remaining: 0.04), 0.04, accuracy: 0.0001)
    }

    func testLowLumaOrSameMarkIsNotConfirmed() {
        XCTAssertTrue(
            AccessLifecycleContract.isConfirmedNewStableMark(
                status: "MATCH",
                mark: "A4",
                candidateMark: "A4",
                initialMark: "A3",
                meanLuma: 0.20
            )
        )
        XCTAssertFalse(
            AccessLifecycleContract.isConfirmedNewStableMark(
                status: "MATCH",
                mark: "A4",
                candidateMark: "A4",
                initialMark: "A3",
                meanLuma: 0.10
            )
        )
        XCTAssertFalse(
            AccessLifecycleContract.isConfirmedNewStableMark(
                status: "TRANSITION",
                mark: "A4",
                candidateMark: "A4",
                initialMark: "A3",
                meanLuma: 0.50
            )
        )
        XCTAssertFalse(
            AccessLifecycleContract.isConfirmedNewStableMark(
                status: "MATCH",
                mark: "A3",
                candidateMark: "A3",
                initialMark: "A3",
                meanLuma: 0.50
            )
        )
        XCTAssertTrue(
            AccessLifecycleContract.isConfirmedNewStableMark(
                status: "MATCH",
                mark: "A4+A5",
                candidateMark: "A4+A5",
                initialMark: "A3+A5",
                meanLuma: 0.50
            )
        )
        XCTAssertFalse(
            AccessLifecycleContract.isConfirmedNewStableMark(
                status: "TRANSITION",
                mark: "A4+A5",
                candidateMark: "A4+A5",
                initialMark: "A3+A5",
                meanLuma: 0.50
            )
        )
    }

    func testHideWaitLeavesEvidenceBudgetBeforeAutoplay() {
        XCTAssertEqual(AccessLifecycleContract.wakeEvidenceBudgetSeconds, 2.5, accuracy: 0.0001)
        XCTAssertEqual(
            AccessLifecycleContract.hideWaitForWake(
                hideSeconds: 9,
                remainingToAutoplay: 9.5,
                evidenceBudget: 2.5
            ),
            7.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AccessLifecycleContract.hideWaitForWake(
                hideSeconds: 9,
                remainingToAutoplay: 12,
                evidenceBudget: 2.5
            ),
            9.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AccessLifecycleContract.hideWaitForWake(
                hideSeconds: 9,
                remainingToAutoplay: 2.0,
                evidenceBudget: 2.5
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertTrue(
            AccessLifecycleContract.shouldWaitForAutoplayBeforeWake(
                remainingToAutoplay: 2.0,
                evidenceBudget: 2.5
            )
        )
        XCTAssertFalse(
            AccessLifecycleContract.shouldWaitForAutoplayBeforeWake(
                remainingToAutoplay: 9.5,
                evidenceBudget: 2.5
            )
        )
    }
}
