import Testing
@testable import immichSlides

@MainActor
@Suite
struct MotionEligibilityPolicyTests {

    @Test
    func `accepted scene runtime policy enables runtime animation for accepted SmartFill on iOS`() {
        let result = MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
            MotionEligibilityInput(
                platform: .iOS,
                sceneCapability: .smartFillAccepted,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: false,
                renderRole: .settled,
                slotReadiness: .ready
            )
        )

        #expect(result.isTransformEnabled)
        #expect(result.isScheduleEnabled)
        #expect(result.identityReason == nil)
        #expect(result.platformScope == .iOSAndIPadOS)
        #expect(result.runtimeIntegration == .acceptedSceneRuntime)
    }

    @Test
    func `accepted scene runtime policy enables iPadOS runtime motion in the same iOS family scope`() {
        let result = MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
            MotionEligibilityInput(
                platform: .iPadOS,
                sceneCapability: .smartFillAccepted,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: false,
                renderRole: .settled,
                slotReadiness: .ready
            )
        )

        #expect(result.isTransformEnabled)
        #expect(result.isScheduleEnabled)
        #expect(result.identityReason == nil)
        #expect(result.platformScope == .iOSAndIPadOS)
        #expect(result.runtimeIntegration == .acceptedSceneRuntime)
    }

    @Test
    func `accepted scene runtime policy uses shared runtime animation for a SmartFill single scene on iOS`() {
        let result = MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
            MotionEligibilityInput(
                platform: .iOS,
                sceneCapability: .smartFillSingle,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: false,
                renderRole: .settled,
                slotReadiness: .ready
            )
        )

        #expect(result.isTransformEnabled)
        #expect(result.isScheduleEnabled)
        #expect(result.identityReason == nil)
        #expect(result.platformScope == .iOSAndIPadOS)
        #expect(result.runtimeIntegration == .acceptedSceneRuntime)
    }

    @Test
    func `accepted scene runtime policy keeps a SmartFill fallback scene outside runtime animation on iOS`() {
        let result = MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
            MotionEligibilityInput(
                platform: .iOS,
                sceneCapability: .smartFillFallback,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: false,
                renderRole: .settled,
                slotReadiness: .ready
            )
        )

        #expect(!result.isTransformEnabled)
        #expect(!result.isScheduleEnabled)
        #expect(result.identityReason == .fallbackDisabled)
        #expect(result.platformScope == .iOSAndIPadOS)
        #expect(result.runtimeIntegration == .acceptedSceneRuntime)
    }

    @Test
    func `architecture-only policy keeps SmartFill ambient motion disabled on tvOS`() {
        let result = MotionEligibilityPolicy.architectureOnly.evaluate(
            MotionEligibilityInput(
                platform: .tvOS,
                sceneCapability: .smartFillAccepted,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: false,
                renderRole: .settled,
                slotReadiness: .ready
            )
        )

        #expect(!result.isTransformEnabled)
        #expect(!result.isScheduleEnabled)
        #expect(result.identityReason == .platformDisabled)
        #expect(result.platformScope == .tvOSDisabled)
    }

    @Test
    func `accepted and SmartFill single scenes use shared runtime animation on tvOS`() {
        for sceneCapability in [MotionSceneCapability.smartFillAccepted, .smartFillSingle] {
            let result = MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
                MotionEligibilityInput(
                    platform: .tvOS,
                    sceneCapability: sceneCapability,
                    displayMode: .smartFill,
                    focalAdapter: .smartFill,
                    reduceMotionEnabled: false,
                    renderRole: .settled,
                    slotReadiness: .ready
                )
            )

            #expect(result.isTransformEnabled, "\(sceneCapability.rawValue) should animate on tvOS")
            #expect(result.isScheduleEnabled, "\(sceneCapability.rawValue) should use shared schedule on tvOS")
            #expect(result.identityReason == nil)
            #expect(result.platformScope.rawValue == "tvOSAcceptedSceneRuntime")
            #expect(result.runtimeIntegration == .acceptedSceneRuntime)
        }
    }

    @Test
    func `tvOS fallback legacy person soloOnly Reduce Motion and unready slot cases stay disabled`() {
        let disabledCases:
            [(
                name: String,
                sceneCapability: MotionSceneCapability,
                displayMode: MotionDisplayMode,
                focalAdapter: MotionFocalAdapter,
                reduceMotionEnabled: Bool,
                renderRole: MotionRenderRole,
                slotReadiness: MotionSlotReadiness,
                reason: MotionIdentityReason
            )] = [
                ("fallback", .smartFillFallback, .smartFill, .smartFill, false, .settled, .ready, .fallbackDisabled),
                (
                    "legacy single photo", .legacySinglePhoto, .singlePhoto, .slotCenter, false, .settled, .ready,
                    .legacyUnchanged
                ),
                (
                    "person", .smartFillAccepted, .smartFill, .person, false, .settled, .ready,
                    .futureVisualBehaviorDeferred
                ),
                (
                    "soloOnly", .smartFillAccepted, .smartFill, .soloOnly, false, .settled, .ready,
                    .futureVisualBehaviorDeferred
                ),
                ("Reduce Motion", .smartFillAccepted, .smartFill, .smartFill, true, .settled, .ready, .reduceMotion),
                ("pending slot", .smartFillAccepted, .smartFill, .smartFill, false, .settled, .pending, .slotNotReady),
                ("failed slot", .smartFillAccepted, .smartFill, .smartFill, false, .settled, .failed, .slotNotReady),
                ("prerender", .smartFillAccepted, .smartFill, .smartFill, false, .prerender, .ready, .prerender)
            ]

        for disabledCase in disabledCases {
            let result = MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
                MotionEligibilityInput(
                    platform: .tvOS,
                    sceneCapability: disabledCase.sceneCapability,
                    displayMode: disabledCase.displayMode,
                    focalAdapter: disabledCase.focalAdapter,
                    reduceMotionEnabled: disabledCase.reduceMotionEnabled,
                    renderRole: disabledCase.renderRole,
                    slotReadiness: disabledCase.slotReadiness
                )
            )

            #expect(!result.isTransformEnabled, "\(disabledCase.name) must not transform")
            #expect(!result.isScheduleEnabled, "\(disabledCase.name) must not schedule")
            #expect(result.identityReason == disabledCase.reason, "\(disabledCase.name) disabled reason changed")
            #expect(result.platformScope.rawValue == "tvOSAcceptedSceneRuntime")
            #expect(result.runtimeIntegration == .acceptedSceneRuntime)
        }
    }

    @Test
    func `fallback and legacy scenes remain unchanged`() {
        let fallback = MotionEligibilityPolicy.architectureOnly.evaluate(
            MotionEligibilityInput(
                platform: .iOS,
                sceneCapability: .smartFillFallback,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: false,
                renderRole: .settled,
                slotReadiness: .ready
            )
        )
        #expect(!fallback.isTransformEnabled)
        #expect(!fallback.isScheduleEnabled)
        #expect(fallback.identityReason == .fallbackDisabled)

        let legacy = MotionEligibilityPolicy.architectureOnly.evaluate(
            MotionEligibilityInput(
                platform: .iOS,
                sceneCapability: .legacySinglePhoto,
                displayMode: .singlePhoto,
                focalAdapter: .slotCenter,
                reduceMotionEnabled: false,
                renderRole: .settled,
                slotReadiness: .ready
            )
        )
        #expect(!legacy.isTransformEnabled)
        #expect(!legacy.isScheduleEnabled)
        #expect(legacy.identityReason == .legacyUnchanged)
    }

    @Test
    func `person and soloOnly adapters are future-capable but do not add visual behavior`() {
        for adapter in [MotionFocalAdapter.person, .soloOnly] {
            let result = MotionEligibilityPolicy.architectureOnly.evaluate(
                MotionEligibilityInput(
                    platform: .iOS,
                    sceneCapability: .smartFillAccepted,
                    displayMode: .smartFill,
                    focalAdapter: adapter,
                    reduceMotionEnabled: false,
                    renderRole: .settled,
                    slotReadiness: .ready
                )
            )

            #expect(!result.isTransformEnabled)
            #expect(!result.isScheduleEnabled)
            #expect(result.identityReason == .futureVisualBehaviorDeferred)
            #expect(result.runtimeIntegration == .architectureOnly)
        }
    }

    @Test
    func `with Reduce Motion, unready slots and prerender all return identity`() {
        let reduceMotion = MotionEligibilityPolicy.architectureOnly.evaluate(
            MotionEligibilityInput(
                platform: .iOS,
                sceneCapability: .smartFillAccepted,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: true,
                renderRole: .settled,
                slotReadiness: .ready
            )
        )
        #expect(reduceMotion.identityReason == .reduceMotion)

        let pendingSlot = MotionEligibilityPolicy.architectureOnly.evaluate(
            MotionEligibilityInput(
                platform: .iOS,
                sceneCapability: .smartFillAccepted,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: false,
                renderRole: .settled,
                slotReadiness: .pending
            )
        )
        #expect(pendingSlot.identityReason == .slotNotReady)

        let prerender = MotionEligibilityPolicy.architectureOnly.evaluate(
            MotionEligibilityInput(
                platform: .iOS,
                sceneCapability: .smartFillAccepted,
                displayMode: .smartFill,
                focalAdapter: .smartFill,
                reduceMotionEnabled: false,
                renderRole: .prerender,
                slotReadiness: .ready
            )
        )
        #expect(prerender.identityReason == .prerender)
    }
}
