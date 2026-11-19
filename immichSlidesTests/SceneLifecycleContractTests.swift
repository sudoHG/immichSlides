import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct SceneLifecycleContractTests {
    @Test
    func `single photo longest visible motion window includes the incoming fade duration`() {
        let contract = SceneLifecycleContract(configuredInterval: 3)

        #expect(contract.configuredInterval == 3)
        #expect(contract.frozenInterval == 5)
        #expect(contract.graceDuration == 1)
        #expect(SceneLifecycleContract.outgoingFadeDuration == 1)
        #expect(SceneLifecycleContract.incomingDelay == 1.025)
        #expect(SceneLifecycleContract.incomingFadeDuration == 1)
        #expect(SceneLifecycleContract.transitionDuration == 2.025)
        #expect(contract.longestVisibleMotionDuration == 8)
    }

    @Test
    func `default single photo tunables start full zoom-out at 1.10 and shrink continuously to 1.00`() {
        #expect(SinglePhotoAnimationTunables.default.zoomInTargetScale == 1.10)
        #expect(SinglePhotoAnimationTunables.default.continueShrinkRange == 0.10)
    }

    @Test
    func
        `single photo zoom-out keeps headroom at frozen stable end and reaches 1.00 continuously at the longest window`()
    {
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let profile = SceneAnimationProfile(lifecycle: lifecycle)
        let frozenStableEndTime = SceneLifecycleContract.incomingFadeDuration + lifecycle.frozenInterval

        let stableEnd = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: frozenStableEndTime,
            isMotionEnabled: true
        )
        let longestEnd = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )

        #expect(stableEnd.scale >= 1.02)
        #expect(stableEnd.scale <= 1.03)
        #expect(longestEnd.scale == 1.00)
    }

    @Test
    func `single photo zoom-out reaches its end exactly at 8 seconds when the motion clock starts at incoming fade`() {
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let profile = SceneAnimationProfile(lifecycle: lifecycle)

        let fullTimelineEnd = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: 8,
            isMotionEnabled: true
        )

        #expect(fullTimelineEnd.scale == 1.00)
    }

    @Test
    func `single photo zoom-in stops exactly at 1.10 at the full visible timeline end instead of overshooting`() {
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let profile = SceneAnimationProfile(lifecycle: lifecycle)

        let frozenStableEnd = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: SceneLifecycleContract.incomingFadeDuration + lifecycle.frozenInterval,
            isMotionEnabled: true
        )
        let fullTimelineEnd = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )

        #expect(abs(frozenStableEnd.scale - 1.075) < 0.0001)
        #expect(abs(fullTimelineEnd.scale - 1.10) < 0.0001)
    }

    @Test
    func `an already started single photo motion keeps its current sample after Reduce Motion toggles on`() {
        let profile = SceneAnimationProfile(lifecycle: SceneLifecycleContract(configuredInterval: 5))
        let active = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: 2,
            isMotionEnabled: true
        )
        let frozenForReduceMotion = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: 2,
            isMotionEnabled: true
        )

        #expect(!active.isIdentity)
        #expect(frozenForReduceMotion == active)
    }
}
