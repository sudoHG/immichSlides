import Foundation
import Testing

@MainActor
@Suite
struct AsyncTestWaitTests {
    @Test(arguments: [
        "complete", "extended-progress", "missing-render", "missing-opacity", "missing-progress",
        "invalid-progress", "negative-progress", "wrong-phase", "wrong-role",
        "not-ready", "missing-readiness", "empty-reference", "coverage", "gap", "overlap",
        "paused", "previous-paused", "missing-paused", "no-progress", "insufficient-progress",
        "layer-ids-changed", "missing-layer-ids", "missing-transition"
    ])
    func `publication timeout suffix requires complete unpaused evidence of the same progressing fade`(scenario: String)
    {
        var observation = [
            "render":
                "phase=transition;layerIDs=old|new;layerRoles=outgoing|incoming;layerOpacities=0.4|0;motionRawProgress=0.2|0;loadingVisible=false;playbackPaused=false",
            "manifest":
                "sceneType=double;slotCount=2;slotReadiness=ready,ready;canvasCoverage=1;emptyCanvasRatio=0;gapPixelCount=0;overlapPixelCount=0;ledgerSceneAssets=first,second"
        ]
        let firstTransition = [
            "render": observation["render"]!.replacingOccurrences(
                of: "layerOpacities=0.4|0", with: "layerOpacities=0.8|0")
        ]
        var previous = observation
        switch scenario {
        case "extended-progress":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "motionRawProgress=0.2|0", with: "motionRawProgress=1.116401|0")
        case "missing-render": observation["render"] = ""
        case "missing-opacity":
            observation["render"] = observation["render"]?.replacingOccurrences(of: "layerOpacities=0.4|0;", with: "")
        case "missing-progress":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "motionRawProgress=0.2|0;", with: "")
        case "invalid-progress":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "motionRawProgress=0.2|0", with: "motionRawProgress=nan|0")
        case "negative-progress":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "motionRawProgress=0.2|0", with: "motionRawProgress=-0.2|0")
        case "wrong-phase":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "phase=transition", with: "phase=stablePhoto")
        case "wrong-role":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "outgoing|incoming", with: "stable|incoming")
        case "not-ready":
            observation["manifest"] = observation["manifest"]?.replacingOccurrences(
                of: "ready,ready", with: "ready,pending")
        case "missing-readiness":
            observation["manifest"] = observation["manifest"]?.replacingOccurrences(
                of: "slotReadiness=ready,ready;", with: "")
        case "empty-reference":
            observation["manifest"] = observation["manifest"]?.replacingOccurrences(of: "first,second", with: "first,")
        case "coverage":
            observation["manifest"] = observation["manifest"]?.replacingOccurrences(
                of: "canvasCoverage=1", with: "canvasCoverage=0.9")
        case "gap":
            observation["manifest"] = observation["manifest"]?.replacingOccurrences(
                of: "gapPixelCount=0", with: "gapPixelCount=1")
        case "overlap":
            observation["manifest"] = observation["manifest"]?.replacingOccurrences(
                of: "overlapPixelCount=0", with: "overlapPixelCount=1")
        case "paused":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "playbackPaused=false", with: "playbackPaused=true")
        case "missing-paused":
            observation["render"] = observation["render"]?.replacingOccurrences(of: ";playbackPaused=false", with: "")
        case "no-progress":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "layerOpacities=0.4|0", with: "layerOpacities=0.8|0")
        case "insufficient-progress":
            observation["render"] = observation["render"]?.replacingOccurrences(
                of: "layerOpacities=0.4|0", with: "layerOpacities=0.795|0")
        case "layer-ids-changed":
            observation["render"] = observation["render"]?.replacingOccurrences(of: "old|new", with: "other|new")
        case "missing-layer-ids":
            observation["render"] = observation["render"]?.replacingOccurrences(of: "layerIDs=old|new;", with: "")
        default: break
        }
        if scenario == "previous-paused" {
            previous["render"] = previous["render"]?.replacingOccurrences(
                of: "playbackPaused=false", with: "playbackPaused=true")
        }
        #expect(!StrictE2ESceneCapture.isStableWindow(observation))
        #expect(
            StrictE2ESceneCapture.hasProgressingPublicationFacts(
                firstTransition: scenario == "missing-transition" ? [:] : firstTransition,
                before: previous, after: observation)
                == (scenario == "complete" || scenario == "extended-progress"))
    }

    @Test(arguments: [0.0, 10.0])
    func `deducted preparation taps extend the receipt budget without restarting its elapsed clock`(
        originalDeadlineSeconds: Double
    ) {
        var timeline = FirstFailureTimeline()
        timeline.waitStarted(seconds: originalDeadlineSeconds, at: 100)
        timeline.waitStarted(seconds: 2, at: 101)
        timeline.waitReturned(at: 102)
        timeline.extendWait(by: 3)
        timeline.waitReturned(at: 113.2)
        let timing = timeline.timing(at: 120)
        #expect(timing["deadline_seconds"] as? Double == (originalDeadlineSeconds > 0 ? 13 : 0))
        #expect(abs((timing["wait_elapsed_seconds"] as? Double ?? 0) - 13.2) < 0.0001)
    }

    @Test(arguments: [
        "late-query", "expired-query", "late-action", "missing-outcome", "single-action", "shared-deadline", "probe",
        "focused-late-query", "unfocused-late-query", "expired-focus-query"
    ])
    func `hang guards accept in flight success without starting expired work or repeating actions`(scenario: String) {
        var now = 10.0
        var queries = 0
        var actions = 0
        var pauses = 0
        let guardSeconds = TestWait.seconds(.product(2))
        let navigation = TestWait.hangGuard(
            timeoutSeconds: guardSeconds, nowForTesting: { now },
            pauseForTesting: { seconds in
                pauses += 1
                now += seconds
            })
        let transaction = navigation.transaction()
        switch scenario {
        case "focused-late-query", "unfocused-late-query", "expired-focus-query":
            if scenario == "expired-focus-query" { now = 12.1 }
            let isReady = transaction.until {
                queries += 1
                now = 13
                return scenario != "unfocused-late-query"
            }
            #expect(isReady == (scenario == "focused-late-query"))
            #expect(queries == (scenario == "expired-focus-query" ? 0 : 1))
            #expect(
                !transaction.probe {
                    queries += 1; return true
                })
            #expect(queries == (scenario == "expired-focus-query" ? 0 : 1))
            #expect(actions == 0)
        case "late-query":
            #expect(
                transaction.until {
                    queries += 1; now = 13; return true
                })
            #expect(queries == 1)
        case "expired-query":
            now = 12
            #expect(
                !transaction.until {
                    queries += 1; return true
                })
            #expect(queries == 0)
        case "late-action", "missing-outcome":
            #expect(
                transaction.perform("tap") {
                    actions += 1; now = 13
                })
            #expect(!transaction.perform("tap") { actions += 1 })
            #expect(
                transaction.until {
                    queries += 1; return scenario == "late-action"
                } == (scenario == "late-action"))
            #expect(
                !transaction.probe {
                    queries += 1; return true
                })
            #expect(actions == 1)
            #expect(queries == 1)
        case "shared-deadline":
            now = 11.5
            let child = navigation.transaction()
            #expect(
                !child.until {
                    queries += 1; return false
                })
            #expect(!transaction.perform("tap") { actions += 1 })
            #expect(
                !transaction.probe {
                    queries += 1; return true
                })
            #expect(now == 12)
            #expect(actions == 0)
        case "single-action":
            #expect(transaction.perform("tap") { actions += 1 })
            #expect(!transaction.perform("tap") { actions += 1 })
            #expect(actions == 1)
        default:
            #expect(
                !transaction.probe {
                    queries += 1; return false
                })
            #expect(queries == 1)
            #expect(pauses == 0)
            #expect(now == 10)
        }
    }

    @Test(arguments: ["expired", "late", "timely"])
    func `product deadline accepts success only when polling finishes before expiry`(scenario: String) {
        var checks = 0
        let satisfied = TestWait.until(.product(scenario == "expired" ? 0 : (scenario == "late" ? 0.01 : 1))) {
            checks += 1
            // A synchronous UI predicate can finish after its budget even when it reports success.
            if scenario == "late" { Thread.sleep(forTimeInterval: TestWait.seconds(.product(0.03))) }
            return true
        }
        #expect(satisfied == (scenario == "timely"))
        #expect(checks == (scenario == "expired" ? 0 : 1))
    }

    @Test func `returns true as soon as the condition holds`() async {
        var checks = 0
        let satisfied = await waitUntil {
            checks += 1
            return checks >= 3
        }
        #expect(satisfied)
        #expect(checks == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func `returns false instead of hanging when the condition never holds`() async {
        let satisfied = await waitUntil(timeout: .milliseconds(200)) { false }
        #expect(!satisfied)
    }

    @Test func `sees state changed by another main actor task while yielding`() async {
        var isConditionSatisfied = false
        Task { @MainActor in isConditionSatisfied = true }
        let satisfied = await waitUntil { isConditionSatisfied }
        #expect(satisfied)
    }

    @Test func `polls with sleep when an interval is given`() async {
        var isConditionSatisfied = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            isConditionSatisfied = true
        }
        let satisfied = await waitUntil(pollInterval: .milliseconds(1)) { isConditionSatisfied }
        #expect(satisfied)
    }
}
