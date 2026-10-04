import Foundation

extension PlaybackSessionEngine {
    private enum ScenePresentationWakeUpPurpose: Equatable, Sendable {
        case stableDeadline
        case graceDeadline
        case transitionCompletion
    }

    private struct ScenePresentationScheduledWakeUp: Equatable, Sendable {
        let generation: UUID
        let purpose: ScenePresentationWakeUpPurpose
        let deadline: TimeInterval
    }

    private struct ScenePresentationSuspendedWakeUp: Equatable, Sendable {
        let generation: UUID
        let purpose: ScenePresentationWakeUpPurpose
        let remaining: TimeInterval
    }

    private enum ScenePresentationTransitionKind: Equatable, Sendable {
        case readyPhoto
        case loading
    }

    private struct ScenePresentationLayerState: Equatable, Sendable {
        let identity: ScenePresentationIdentity
        var role: ScenePresentationLayerRole
        var opacityAtFadeStart: Double
        var fadeStartTime: TimeInterval?
        var fadeDuration: TimeInterval
        var suspendedFadeDelay: TimeInterval?
        var motionClock: SceneActiveTimeClock
        var isMotionEnabled: Bool
        /// A seen photo keeps its current sample when Reduce Motion is on; turning the setting off later must not
        /// restart it on a background/foreground return.

        var isMotionFrozenByReduceMotion: Bool
        var isPresentationReady: Bool
        /// Raised back to full opacity out of a transition that a manual press interrupted.
        var isRaisedForHold = false

        func opacity(at time: TimeInterval) -> Double {
            guard let fadeStartTime, fadeDuration > 0 else {
                return min(1, max(0, opacityAtFadeStart))
            }

            let elapsed = max(0, time - fadeStartTime)
            switch role {
            case .outgoing:
                return min(1, max(0, opacityAtFadeStart * (1 - elapsed / fadeDuration)))
            case .incoming:
                return min(1, max(0, opacityAtFadeStart + (1 - opacityAtFadeStart) * elapsed / fadeDuration))
            case .stable:
                return min(1, max(0, opacityAtFadeStart))
            }
        }

        func renderLayer(at time: TimeInterval) -> SceneRenderLayer {
            SceneRenderLayer(
                identity: identity,
                role: role,
                opacity: opacity(at: time),
                motionActiveTime: motionClock.activeTime(at: time),
                isMotionEnabled: isMotionEnabled,
                fadeStartTime: fadeStartTime,
                fadeDuration: fadeDuration,
                isPresentationReady: isPresentationReady
            )
        }
    }

    /// The only presentation owner on the product path; callers can only send events and run the returned effects.
    struct ScenePresentationState: Equatable, Sendable {
        /// Opacity at or below which a fading-out layer counts as gone; far below anything a display can show.
        private static let fadedOutOpacity = 0.000_001

        private(set) var underlyingPhase: ScenePresentationPhase
        private(set) var currentTarget: ScenePresentationTarget?
        private(set) var pendingTarget: ScenePresentationTarget?
        private(set) var targetReadiness: [ScenePresentationIdentity: ScenePresentationTargetReadiness]
        private(set) var history: [ScenePresentationIdentity]
        private(set) var attemptRecords: [TargetAttemptRecord]
        private(set) var suspensionReasons: Set<ScenePresentationSuspensionReason>
        private(set) var isReduceMotionEnabled: Bool
        private(set) var nextConfiguredInterval: TimeInterval
        private(set) var diagnostics: [String]

        private var layers: [ScenePresentationLayerState]
        private var stableVisibleClock: SceneActiveTimeClock?
        private(set) var graceDeadline: TimeInterval?
        private var isTransitionCompletionPending = false
        private var transitionKind: ScenePresentationTransitionKind?
        private var scheduledWakeUp: ScenePresentationScheduledWakeUp?
        private var suspendedWakeUp: ScenePresentationSuspendedWakeUp?
        /// Short manual crossfade window while paused; does not restart in-scene motion.
        private var isManualNavigationWhilePaused = false
        /// After manual navigation while paused, keep in-scene motion progress at 0 until the user resumes autoplay.
        private var isCurrentSceneManualStatic = false
        /// Previous on an unseen manual target must restore the same seen presentation, not re-request the old scene
        /// and flash Loading.

        private struct ManualPendingPresentationRestore: Equatable, Sendable {
            let underlyingPhase: ScenePresentationPhase
            let currentTarget: ScenePresentationTarget?
            let pendingTarget: ScenePresentationTarget?
            let targetReadiness: [ScenePresentationIdentity: ScenePresentationTargetReadiness]
            var layers: [ScenePresentationLayerState]
            let stableVisibleClock: SceneActiveTimeClock?
            let graceDeadline: TimeInterval?
            let isTransitionCompletionPending: Bool
            let transitionKind: ScenePresentationTransitionKind?
            let wakeUp: ScenePresentationSuspendedWakeUp?
            let isManualNavigationWhilePaused: Bool
            let isCurrentSceneManualStatic: Bool
            /// A settled photo stays live on screen while the manual target loads, so cancelling continues from it.
            let shouldKeepHeldPhotoLive: Bool

            /// The state Previous returns to after an interrupted transition was raised: it continues from the live picture.
            func resolved(
                underlyingPhase: ScenePresentationPhase,
                transitionKind: ScenePresentationTransitionKind?,
                pendingTarget: ScenePresentationTarget?,
                targetReadiness: [ScenePresentationIdentity: ScenePresentationTargetReadiness],
                wakeUp: ScenePresentationSuspendedWakeUp?
            ) -> Self {
                Self(
                    underlyingPhase: underlyingPhase,
                    currentTarget: currentTarget,
                    pendingTarget: pendingTarget,
                    targetReadiness: targetReadiness,
                    layers: [],
                    stableVisibleClock: nil,
                    graceDeadline: nil,
                    isTransitionCompletionPending: false,
                    transitionKind: transitionKind,
                    wakeUp: wakeUp,
                    isManualNavigationWhilePaused: isManualNavigationWhilePaused,
                    isCurrentSceneManualStatic: false,
                    shouldKeepHeldPhotoLive: true
                )
            }
        }

        private var manualPendingPresentationRestore: ManualPendingPresentationRestore?

        /// If the pause came before a layer was built, the new layer also inherits the freeze; a SmartFill that becomes
        /// Ready later must not run its own clock in the background.

        private var shouldFreezeNewLayersForCurrentSuspension: Bool {
            !suspensionReasons.isEmpty && (!isManualNavigationWhilePaused || suspensionReasons.contains(.background))
        }

        init(
            nextConfiguredInterval: TimeInterval = SceneLifecycleContract.minimumInterval,
            isReduceMotionEnabled: Bool = false
        ) {
            underlyingPhase = .empty
            currentTarget = nil
            pendingTarget = nil
            targetReadiness = [:]
            history = []
            attemptRecords = []
            suspensionReasons = []
            self.isReduceMotionEnabled = isReduceMotionEnabled
            self.nextConfiguredInterval = SceneLifecycleContract.normalizedInterval(nextConfiguredInterval)
            diagnostics = []
            layers = []
            stableVisibleClock = nil
            graceDeadline = nil
            transitionKind = nil
            scheduledWakeUp = nil
            suspendedWakeUp = nil
        }

        var phase: ScenePresentationPhase {
            suspensionReasons.isEmpty ? underlyingPhase : .paused
        }

        var attemptSummary: TargetAttemptSummary {
            TargetAttemptSummary(records: attemptRecords)
        }

        var hasUnseenManualPendingPresentation: Bool {
            guard manualPendingPresentationRestore != nil,
                let pendingTarget,
                !history.contains(pendingTarget.identity)
            else {
                return false
            }
            return latestAttemptSource(for: pendingTarget.identity)?.isManual == true
        }

        /// When a manual pending target covers an automatic one, the caller must keep the automatic target's mapping
        /// for now, so the original load can be re-sent after a cancel.

        var manualPendingRestorePendingTarget: ScenePresentationTarget? {
            manualPendingPresentationRestore?.pendingTarget
        }

        /// When an unseen manual pending target is cancelled, the seen scene is still the current index; the mapping
        /// stays until the automatic target actually shows its first frame.

        var manualPendingRestoreCurrentTarget: ScenePresentationTarget? {
            manualPendingPresentationRestore?.currentTarget
        }

        /// Synchronous, pure-value, exhaustive reducer; invalid events append diagnostics and produce no effects.
        @discardableResult
        mutating func reduce(
            _ event: ScenePresentationEvent,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            switch event {
            case let .start(target, readiness):
                guard underlyingPhase == .empty else {
                    return reject("start-not-empty")
                }
                register(target: target, readiness: readiness, source: .automatic, at: time)
                if readiness == .ready {
                    return beginIncomingFromLoading(target: target, source: .automatic, at: time)
                }
                underlyingPhase = .loading
                return [
                    .plan(effectRequest(for: target, source: .automatic)),
                    .download(effectRequest(for: target, source: .automatic))
                ]

            case let .request(target, source, readiness):
                return request(target: target, source: source, readiness: readiness, at: time)

            case .cancelUnseenManualPendingPresentation:
                return cancelUnseenManualPendingPresentation(at: time)

            case let .stableDeadlineReached(target, readiness):
                guard underlyingPhase == .stablePhoto, suspensionReasons.isEmpty else {
                    return reject("deadline-not-stable")
                }
                register(target: target, readiness: readiness, source: .automatic, at: time)
                if readiness == .ready {
                    return beginTransition(to: target, source: .automatic, at: time)
                }
                pendingTarget = target
                underlyingPhase = .grace
                let deadline = time + (currentTarget?.lifecycle.graceDuration ?? target.lifecycle.graceDuration)
                graceDeadline = deadline
                return [.download(effectRequest(for: target, source: .automatic))]
                    + scheduleWakeUp(
                        generation: target.identity.generation,
                        purpose: .graceDeadline,
                        deadline: deadline,
                        at: time
                    )

            case let .targetReady(identity):
                return receiveReady(identity: identity, at: time)

            case let .targetFailed(identity):
                return receiveFailure(identity: identity, at: time)

            case .graceExpired:
                guard underlyingPhase == .grace,
                    suspensionReasons.isEmpty,
                    let pendingTarget
                else {
                    return reject("grace-not-active")
                }
                if targetReadiness[pendingTarget.identity] == .ready {
                    return beginTransition(
                        to: pendingTarget,
                        source: latestAttemptSource(for: pendingTarget.identity) ?? .automatic,
                        at: time
                    )
                } else {
                    return beginLoadingTransition(to: pendingTarget, source: .automatic, at: time)
                }

            case .transitionCompleted:
                guard suspensionReasons.isEmpty || (isManualNavigationWhilePaused && suspensionReasons == [.userPaused])
                else {
                    isTransitionCompletionPending = true
                    return []
                }
                return completeTransition(at: time)

            case let .wakeUp(generation, deadline):
                guard
                    (suspensionReasons.isEmpty
                        || (isManualNavigationWhilePaused && suspensionReasons == [.userPaused])),
                    let wakeUp = scheduledWakeUp,
                    wakeUp.generation == generation,
                    wakeUp.deadline == deadline
                else {
                    return reject("stale-wake-up")
                }
                scheduledWakeUp = nil
                switch wakeUp.purpose {
                case .stableDeadline:
                    guard underlyingPhase == .stablePhoto,
                        let currentTarget
                    else {
                        return reject("stable-wake-not-stable")
                    }
                    return [.plan(effectRequest(for: currentTarget, source: .automatic))]
                case .graceDeadline:
                    return reduce(.graceExpired, at: time)
                case .transitionCompletion:
                    return reduce(.transitionCompleted, at: time)
                }

            case let .incomingBecameVisible(identity):
                guard
                    layers.contains(where: {
                        $0.identity == identity && ($0.role == .incoming || $0.role == .stable)
                            && $0.isPresentationReady && $0.opacity(at: time) > 0
                    })
                else {
                    return reject("incoming-not-visible")
                }
                if !history.contains(identity) {
                    history.append(identity)
                }
                return []

            case let .suspend(reason):
                return suspend(reason: reason, at: time)

            case let .resume(reason):
                return resume(reason: reason, at: time)

            case let .reduceMotionChanged(isEnabled):
                updateReduceMotion(isEnabled, at: time)
                return []

            case let .intervalTemplateChanged(interval):
                nextConfiguredInterval = SceneLifecycleContract.normalizedInterval(interval)
                return []

            case let .loadMoreNeeded(generation):
                guard let target = pendingTarget ?? currentTarget,
                    target.identity.generation == generation
                else {
                    return reject("stale-load-more")
                }
                return [.loadMore(generation: generation)]

            case .sourceExhausted:
                let noVisibleLayers = !layers.contains { $0.opacity(at: time) > 0 }
                let allKnownTargetsFailed =
                    !targetReadiness.isEmpty && targetReadiness.values.allSatisfy { $0 == .failed }
                guard noVisibleLayers,
                    pendingTarget == nil || allKnownTargetsFailed
                else {
                    return reject("source-not-exhausted")
                }
                underlyingPhase = .sourceError
                return []

            case let .effectResult(result):
                switch result {
                case let .ready(identity):
                    return receiveReady(identity: identity, at: time)
                case let .failed(identity):
                    return receiveFailure(identity: identity, at: time)
                case let .sourceExhausted(generation):
                    guard
                        generation == pendingTarget?.identity.generation
                            || generation == currentTarget?.identity.generation
                    else {
                        return reject("stale-source-exhausted")
                    }
                    return reduce(.sourceExhausted, at: time)
                case let .cancelled(identity):
                    cancelAttempt(identity: identity)
                    return []
                }
            }
        }

        func renderSnapshot(at time: TimeInterval) -> SceneRenderSnapshot {
            let renderLayers = layers.map { $0.renderLayer(at: time) }
            return SceneRenderSnapshot(
                phase: phase,
                underlyingPhase: underlyingPhase,
                layers: renderLayers,
                currentTarget: currentTarget,
                frozenInterval: currentTarget?.lifecycle.frozenInterval,
                activeTime: stableVisibleClock?.activeTime(at: time) ?? 0,
                suspensionReasons: suspensionReasons,
                isReduceMotionEnabled: isReduceMotionEnabled,
                isPendingTargetReady: pendingTarget.flatMap { targetReadiness[$0.identity] } == .ready
            )
        }

        private mutating func request(
            target: ScenePresentationTarget,
            source: ScenePresentationRequestSource,
            readiness: ScenePresentationTargetReadiness,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            guard underlyingPhase != .sourceError else {
                return reject("request-after-source-error")
            }
            let canNavigateManuallyWhilePaused = source.isManual && suspensionReasons == [.userPaused]
            let previousTarget = pendingTarget
            var cancellationEffects: [ScenePresentationEffect] = []
            let hadPresentedLayer = layers.contains { $0.opacity(at: time) > 0 }
            // A photo that just faded out of an automatic transition can still be brought back for a manual hold.
            let canHoldPresentation = hadPresentedLayer || (source.isManual && layers.contains { $0.role == .outgoing })
            // Replacing a held manual target keeps the first capture: Previous must return to the last seen scene.
            let isReplacingHeldManualTarget = hasUnseenManualPendingPresentation
            let manualPendingRestore =
                source.isManual && readiness == .pending && canHoldPresentation && !isReplacingHeldManualTarget
                ? captureManualPendingPresentationRestore(at: time)
                : nil
            if canNavigateManuallyWhilePaused {
                beginManualNavigationWhilePaused()
            }
            // A hold keeps its short fades running: freezing them would leave a photo half faded behind the held one.
            if !(isReplacingHeldManualTarget && underlyingPhase == .grace) {
                materializeLayers(at: time)
            }
            if let previousTarget, previousTarget.identity != target.identity {
                let cancellationSource = latestAttemptSource(for: previousTarget.identity) ?? source
                cancellationEffects.append(
                    .cancel(effectRequest(for: previousTarget, source: cancellationSource))
                )
                cancelAttempt(identity: previousTarget.identity)
            }
            register(target: target, readiness: readiness, source: source, at: time)

            guard suspensionReasons.isEmpty || canNavigateManuallyWhilePaused else {
                pendingTarget = target
                return cancellationEffects + effectsForPendingTarget(target, source: source)
            }

            if !canHoldPresentation {
                if readiness == .ready {
                    return cancellationEffects + beginIncomingFromLoading(target: target, source: source, at: time)
                }
                // Nothing is on screen: drop never-shown layers of replaced targets and their pending wake-up.
                cancellationEffects +=
                    scheduledWakeUp.map { wakeUp in
                        [ScenePresentationEffect.cancelWakeUp(generation: wakeUp.generation)]
                    } ?? []
                scheduledWakeUp = nil
                suspendedWakeUp = nil
                layers.removeAll { $0.identity != target.identity }
                transitionKind = nil
                underlyingPhase = .loading
                pendingTarget = target
                return cancellationEffects + effectsForPendingTarget(target, source: source)
            }

            if readiness == .ready {
                return cancellationEffects + beginTransition(to: target, source: source, at: time)
            }
            return cancellationEffects
                + beginLoadingTransition(
                    to: target,
                    source: source,
                    manualPendingRestore: manualPendingRestore,
                    at: time
                )
                + effectsForPendingTarget(target, source: source)
        }

        private func captureManualPendingPresentationRestore(
            at time: TimeInterval
        ) -> ManualPendingPresentationRestore {
            let visibleLayers = layers.filter { $0.opacity(at: time) > 0 }
            var restoredLayers = layers
            freezeLayerFadeSamples(&restoredLayers, at: time)
            for index in restoredLayers.indices {
                restoredLayers[index].motionClock.suspend(at: time)
            }
            var restoredStableVisibleClock = stableVisibleClock
            restoredStableVisibleClock?.suspend(at: time)
            let wakeUp =
                scheduledWakeUp.map {
                    ScenePresentationSuspendedWakeUp(
                        generation: $0.generation,
                        purpose: $0.purpose,
                        remaining: max(0, $0.deadline - time)
                    )
                } ?? suspendedWakeUp
            return ManualPendingPresentationRestore(
                underlyingPhase: underlyingPhase,
                currentTarget: currentTarget,
                pendingTarget: pendingTarget,
                targetReadiness: targetReadiness,
                layers: restoredLayers,
                stableVisibleClock: restoredStableVisibleClock,
                graceDeadline: graceDeadline,
                isTransitionCompletionPending: isTransitionCompletionPending,
                transitionKind: transitionKind,
                wakeUp: wakeUp,
                isManualNavigationWhilePaused: isManualNavigationWhilePaused,
                isCurrentSceneManualStatic: isCurrentSceneManualStatic,
                shouldKeepHeldPhotoLive: !visibleLayers.isEmpty && visibleLayers.allSatisfy { $0.role == .stable }
            )
        }

        private mutating func cancelUnseenManualPendingPresentation(
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            guard hasUnseenManualPendingPresentation,
                let restore = manualPendingPresentationRestore,
                let cancelledTarget = pendingTarget
            else {
                return reject("cancel-unseen-manual-pending-invalid")
            }
            let cancelledSource = latestAttemptSource(for: cancelledTarget.identity) ?? .manualPrevious
            cancelAttempt(identity: cancelledTarget.identity)

            underlyingPhase = restore.underlyingPhase
            currentTarget = restore.currentTarget
            pendingTarget = restore.pendingTarget
            targetReadiness = restore.targetReadiness
            if restore.shouldKeepHeldPhotoLive {
                return continueLiveHeldPhoto(
                    restore,
                    cancelling: cancelledTarget,
                    source: cancelledSource,
                    at: time
                )
            }
            layers = restore.layers
            Self.reconcileReduceMotion(
                isReduceMotionEnabled,
                in: &layers,
                at: time,
                canResumeUnseenMotion: false
            )
            stableVisibleClock = restore.stableVisibleClock
            graceDeadline = restore.graceDeadline
            isTransitionCompletionPending = restore.isTransitionCompletionPending
            transitionKind = restore.transitionKind
            scheduledWakeUp = nil
            suspendedWakeUp = nil
            isManualNavigationWhilePaused = restore.isManualNavigationWhilePaused
            isCurrentSceneManualStatic = restore.isCurrentSceneManualStatic
            manualPendingPresentationRestore = nil

            let resumesRestoredPresentation = suspensionReasons.isEmpty && !isCurrentSceneManualStatic
            let resumesRestoredManualFadeWhilePaused =
                isManualNavigationWhilePaused && suspensionReasons == [.userPaused] && !isCurrentSceneManualStatic
                && (underlyingPhase == .transition || underlyingPhase == .incomingFromLoading)
            if resumesRestoredPresentation {
                stableVisibleClock?.resume(at: time)
                for index in layers.indices
                where layers[index].isMotionEnabled && !layers[index].isMotionFrozenByReduceMotion
                    && !isReduceMotionEnabled
                {
                    let defersIncomingMotionUntilFade =
                        underlyingPhase == .transition && layers[index].role == .incoming
                        && layers[index].suspendedFadeDelay != nil
                    guard !defersIncomingMotionUntilFade else { continue }
                    layers[index].motionClock.resume(at: time)
                }
            }
            // A pause/background restore brings back the frozen fade, so cancelling an unseen pending target must not
            // rewrite the fade start; a manual short crossfade that was just triggered continues from the same sample.

            if resumesRestoredPresentation || resumesRestoredManualFadeWhilePaused {
                resumeLayerFades(at: time, shouldResumeMotion: resumesRestoredPresentation)
            }

            var effects: [ScenePresentationEffect] = [
                .cancel(effectRequest(for: cancelledTarget, source: cancelledSource))
            ]
            if let restoredPendingTarget = restore.pendingTarget,
                targetReadiness[restoredPendingTarget.identity] == .pending
            {
                effects += restartRestoredPendingTarget(
                    restoredPendingTarget,
                    at: time
                )
            }
            if let wakeUp = restore.wakeUp {
                let deadline = time + wakeUp.remaining
                if wakeUp.purpose == .graceDeadline {
                    graceDeadline = deadline
                }
                if shouldFreezeNewLayersForCurrentSuspension {
                    suspendedWakeUp = ScenePresentationSuspendedWakeUp(
                        generation: wakeUp.generation,
                        purpose: wakeUp.purpose,
                        remaining: wakeUp.remaining
                    )
                } else {
                    effects += scheduleWakeUp(
                        generation: wakeUp.generation,
                        purpose: wakeUp.purpose,
                        deadline: deadline,
                        at: time
                    )
                }
            }
            return effects
        }

        /// The held photo kept its own clocks on screen, so only the withheld deadline and hidden targets come back.
        private mutating func continueLiveHeldPhoto(
            _ restore: ManualPendingPresentationRestore,
            cancelling cancelledTarget: ScenePresentationTarget,
            source cancelledSource: ScenePresentationRequestSource,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            layers.removeAll { $0.identity == cancelledTarget.identity }
            if let restartedTarget = restore.pendingTarget,
                restore.targetReadiness[restartedTarget.identity] == .pending
            {
                // A target that goes back to loading decodes again behind the held photo, from a fresh hidden layer.
                layers.removeAll { $0.identity == restartedTarget.identity && $0.role == .outgoing }
            }
            let liveIdentities = Set(layers.map(\.identity))
            layers += restore.layers.filter { $0.opacity(at: time) <= 0 && !liveIdentities.contains($0.identity) }
            graceDeadline = restore.graceDeadline
            isTransitionCompletionPending = restore.isTransitionCompletionPending
            transitionKind = restore.transitionKind
            scheduledWakeUp = nil
            suspendedWakeUp = nil
            isManualNavigationWhilePaused = restore.isManualNavigationWhilePaused
            // A manual static photo that started moving during the hold is an ordinary scene again.
            isCurrentSceneManualStatic =
                restore.isCurrentSceneManualStatic && !suspensionReasons.isEmpty
                && (stableVisibleClock?.activeTime(at: time) ?? 0) == 0
            manualPendingPresentationRestore = nil

            var effects: [ScenePresentationEffect] = [
                .cancel(effectRequest(for: cancelledTarget, source: cancelledSource))
            ]
            if let restoredPendingTarget = restore.pendingTarget,
                targetReadiness[restoredPendingTarget.identity] == .pending
            {
                installHiddenLayerIfNeeded(target: restoredPendingTarget, at: time)
                effects += restartRestoredPendingTarget(restoredPendingTarget, at: time)
            }
            if underlyingPhase == .transition, let pendingTarget {
                // The raised picture finishes its short fades, then the interrupted target settles as usual.
                let remaining =
                    layers.compactMap { layer in
                        layer.fadeStartTime.map { max(0, $0 + layer.fadeDuration - time) }
                    }.max() ?? 0
                effects += scheduleWakeUp(
                    generation: pendingTarget.identity.generation,
                    purpose: .transitionCompletion,
                    deadline: time + remaining,
                    at: time
                )
            } else if underlyingPhase == .stablePhoto, !isCurrentSceneManualStatic,
                let currentTarget,
                let stableVisibleClock
            {
                // The stable clock kept running with the photo, so the deadline it implies has not moved.
                let remaining = max(0, currentTarget.lifecycle.frozenInterval - stableVisibleClock.activeTime(at: time))
                effects += scheduleWakeUp(
                    generation: currentTarget.identity.generation,
                    purpose: .stableDeadline,
                    deadline: time + remaining,
                    at: time
                )
            } else if let wakeUp = restore.wakeUp {
                let deadline = time + wakeUp.remaining
                if wakeUp.purpose == .graceDeadline {
                    graceDeadline = deadline
                }
                effects += scheduleWakeUp(
                    generation: wakeUp.generation,
                    purpose: wakeUp.purpose,
                    deadline: deadline,
                    at: time
                )
            }
            return effects
        }

        /// An automatic target cancelled by a manual pending target must re-enter the caller with a new attempt; the
        /// old task/barrier was already ended by the cancel.

        private mutating func restartRestoredPendingTarget(
            _ target: ScenePresentationTarget,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            let source = latestAttemptSource(for: target.identity) ?? .automatic
            let attemptNumber =
                attemptRecords.filter {
                    $0.generation == target.identity.generation
                        && $0.privateIdentifier == target.identity.privateIdentifier
                }.count + 1
            attemptRecords.append(
                TargetAttemptRecord(
                    identity: target.identity,
                    source: source,
                    attemptNumber: attemptNumber,
                    startedAt: time,
                    outcome: .pending
                )
            )
            targetReadiness[target.identity] = .pending
            return effectsForPendingTarget(target, source: source)
        }

        private mutating func beginManualNavigationWhilePaused() {
            // The old automatic deadline was frozen at pause; after a manual slide change, only Play may create a new
            // full deadline.
            scheduledWakeUp = nil
            suspendedWakeUp = nil
            isTransitionCompletionPending = false
            isManualNavigationWhilePaused = true
            isCurrentSceneManualStatic = false
        }

        private mutating func register(
            target: ScenePresentationTarget,
            readiness: ScenePresentationTargetReadiness,
            source: ScenePresentationRequestSource,
            at time: TimeInterval
        ) {
            pendingTarget = target
            targetReadiness[target.identity] = readiness
            installHiddenLayerIfNeeded(target: target, at: time)
            let attemptNumber =
                attemptRecords.filter {
                    $0.generation == target.identity.generation
                        && $0.privateIdentifier == target.identity.privateIdentifier
                }.count + 1
            attemptRecords.append(
                TargetAttemptRecord(
                    identity: target.identity,
                    source: source,
                    attemptNumber: attemptNumber,
                    startedAt: time,
                    outcome: readiness == .ready ? .ready : readiness == .failed ? .failed : .pending
                )
            )
        }

        private func effectRequest(
            for target: ScenePresentationTarget,
            source: ScenePresentationRequestSource
        ) -> ScenePresentationEffectRequest {
            ScenePresentationEffectRequest(identity: target.identity, source: source)
        }

        private func effectsForPendingTarget(
            _ target: ScenePresentationTarget,
            source: ScenePresentationRequestSource
        ) -> [ScenePresentationEffect] {
            let request = effectRequest(for: target, source: source)
            return [.plan(request), .download(request)]
        }

        private mutating func beginTransition(
            to target: ScenePresentationTarget,
            source: ScenePresentationRequestSource,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            manualPendingPresentationRestore = nil
            let pacing =
                source.isManual
                ? ScenePresentationPacingPolicy.manualReady
                : ScenePresentationPacingPolicy.automatic
            convertVisibleLayersToOutgoing(pacing: pacing, at: time)
            pendingTarget = target
            targetReadiness[target.identity] = .ready
            currentTarget = target
            promoteHiddenLayer(
                target: target,
                fadeStartTime: time + pacing.incomingDelay,
                fadeDuration: pacing.incomingFadeDuration,
                at: time
            )
            underlyingPhase = .transition
            transitionKind = .readyPhoto
            stableVisibleClock = nil
            graceDeadline = nil
            return scheduleWakeUp(
                generation: target.identity.generation,
                purpose: .transitionCompletion,
                deadline: time + pacing.completionDuration,
                at: time
            )
        }

        private mutating func beginLoadingTransition(
            to target: ScenePresentationTarget,
            source: ScenePresentationRequestSource,
            manualPendingRestore: ManualPendingPresentationRestore? = nil,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            if source.isManual {
                return holdPresentationForManualTarget(target, manualPendingRestore: manualPendingRestore, at: time)
            }
            convertVisibleLayersToOutgoing(pacing: ScenePresentationPacingPolicy.automatic, at: time)
            installHiddenLayerIfNeeded(target: target, at: time)
            pendingTarget = target
            currentTarget = target
            underlyingPhase = .transition
            transitionKind = .loading
            stableVisibleClock = nil
            graceDeadline = nil
            return scheduleWakeUp(
                generation: target.identity.generation,
                purpose: .transitionCompletion,
                deadline: time + SceneLifecycleContract.transitionDuration,
                at: time
            )
        }

        /// Keeps what the user was looking at on screen while the manual target decodes behind it, so there is no loading gap.
        private mutating func holdPresentationForManualTarget(
            _ target: ScenePresentationTarget,
            manualPendingRestore: ManualPendingPresentationRestore?,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            if let manualPendingRestore {
                manualPendingPresentationRestore = manualPendingRestore
            }
            let cancellationEffects =
                scheduledWakeUp.map { wakeUp in
                    [ScenePresentationEffect.cancelWakeUp(generation: wakeUp.generation)]
                } ?? []
            scheduledWakeUp = nil
            suspendedWakeUp = nil
            if let manualPendingRestore, !manualPendingRestore.shouldKeepHeldPhotoLive,
                let raised = raiseInterruptedTransition(manualPendingRestore, at: time)
            {
                // A frame caught mid-transition may be dim: bring a photo the user has seen back up instead.
                layers = raised.layers
                manualPendingPresentationRestore = raised.restore
                stableVisibleClock = nil
            } else {
                // A settled or already raised photo keeps its own clocks; never-shown layers of replaced targets leave.
                layers.removeAll { $0.identity != target.identity && $0.opacity(at: time) <= 0 }
            }
            installHiddenLayerIfNeeded(target: target, at: time)
            pendingTarget = target
            currentTarget = manualPendingPresentationRestore?.currentTarget ?? currentTarget
            underlyingPhase = .grace
            transitionKind = nil
            graceDeadline = nil
            return cancellationEffects
        }

        /// Resolves a transition interrupted by a manual press. The photo the transition was heading to comes back up to
        /// full opacity if the user has already seen it, otherwise the photo that was fading out does; any other visible
        /// layer fades out behind it with the short manual pacing, so the screen never drops. Motion keeps running unless
        /// playback is suspended. The returned restore lets Previous continue from this picture rather than the dim frame.
        private func raiseInterruptedTransition(
            _ capture: ManualPendingPresentationRestore,
            at time: TimeInterval
        ) -> (layers: [ScenePresentationLayerState], restore: ManualPendingPresentationRestore)? {
            let transitionTarget = capture.pendingTarget ?? capture.currentTarget
            let visibleLayers = capture.layers.filter { $0.opacity(at: time) > 0 }
            let seenTargetLayer = transitionTarget.flatMap { target in
                history.contains(target.identity) ? visibleLayers.first { $0.identity == target.identity } : nil
            }
            guard
                let heldIdentity = seenTargetLayer?.identity
                    ?? (visibleLayers.last { $0.role == .outgoing } ?? capture.layers.last { $0.role == .outgoing })?
                    .identity
            else {
                return nil
            }
            let pacing = ScenePresentationPacingPolicy.manualReady
            var raisedLayers: [ScenePresentationLayerState] = []
            for var layer in capture.layers {
                let opacity = layer.opacity(at: time)
                let isHeld = layer.identity == heldIdentity
                guard isHeld || opacity > 0 else { continue }
                layer.role = isHeld ? .incoming : .outgoing
                layer.isRaisedForHold = isHeld
                layer.opacityAtFadeStart = opacity
                layer.fadeStartTime = time
                layer.fadeDuration =
                    isHeld ? pacing.incomingFadeDuration * (1 - opacity) : pacing.outgoingFadeDuration * opacity
                layer.suspendedFadeDelay = nil
                layer.isPresentationReady = isHeld || layer.isPresentationReady
                // The capture suspended every clock; only a photo that was actually moving picks its motion up again.
                if suspensionReasons.isEmpty, layer.isMotionEnabled, !layer.isMotionFrozenByReduceMotion {
                    layer.motionClock.resume(at: time)
                }
                raisedLayers.append(layer)
            }
            // Outgoing layers sit below incoming ones, so the held photo is drawn on top of what fades out.
            let restore: ManualPendingPresentationRestore
            if let seenTargetLayer, let transitionTarget, seenTargetLayer.identity == transitionTarget.identity {
                restore = capture.resolved(
                    underlyingPhase: .transition,
                    transitionKind: .readyPhoto,
                    pendingTarget: transitionTarget,
                    targetReadiness: capture.targetReadiness.merging([transitionTarget.identity: .ready]) { $1 },
                    wakeUp: nil
                )
            } else {
                var readiness = capture.targetReadiness
                if let transitionTarget {
                    readiness[transitionTarget.identity] = .pending
                }
                restore = capture.resolved(
                    underlyingPhase: .grace,
                    transitionKind: nil,
                    pendingTarget: transitionTarget,
                    targetReadiness: readiness,
                    // Only an automatic target falls back to loading after grace; a manual one is waited for.
                    wakeUp: transitionTarget.flatMap { target in
                        latestAttemptSource(for: target.identity)?.isManual == true
                            ? nil
                            : ScenePresentationSuspendedWakeUp(
                                generation: target.identity.generation,
                                purpose: .graceDeadline,
                                remaining: target.lifecycle.graceDuration
                            )
                    }
                )
            }
            return (raisedLayers, restore)
        }

        private mutating func beginIncomingFromLoading(
            target: ScenePresentationTarget,
            source: ScenePresentationRequestSource,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            manualPendingPresentationRestore = nil
            let pacing =
                source.isManual
                ? ScenePresentationPacingPolicy.manualReady
                : ScenePresentationPacingPolicy.automaticIncoming
            materializeLayers(at: time)
            currentTarget = target
            pendingTarget = target
            targetReadiness[target.identity] = .ready
            promoteHiddenLayer(
                target: target,
                fadeStartTime: time + pacing.incomingDelay,
                fadeDuration: pacing.incomingFadeDuration,
                at: time
            )
            underlyingPhase = .incomingFromLoading
            transitionKind = .readyPhoto
            stableVisibleClock = nil
            graceDeadline = nil
            return scheduleWakeUp(
                generation: target.identity.generation,
                purpose: .transitionCompletion,
                deadline: time + pacing.completionDuration,
                at: time
            )
        }

        private mutating func installHiddenLayerIfNeeded(
            target: ScenePresentationTarget,
            at time: TimeInterval
        ) {
            guard !layers.contains(where: { $0.identity == target.identity }) else { return }
            layers.append(
                ScenePresentationLayerState(
                    identity: target.identity,
                    role: .incoming,
                    opacityAtFadeStart: 0,
                    fadeStartTime: nil,
                    fadeDuration: SceneLifecycleContract.incomingFadeDuration,
                    suspendedFadeDelay: nil,
                    motionClock: shouldFreezeNewLayersForCurrentSuspension
                        ? SceneActiveTimeClock(accumulatedActiveTime: 0, activeAnchorTime: nil)
                        : SceneActiveTimeClock(startedAt: time),
                    isMotionEnabled: !isReduceMotionEnabled && !isManualNavigationWhilePaused
                        && !shouldFreezeNewLayersForCurrentSuspension,
                    isMotionFrozenByReduceMotion: false,
                    isPresentationReady: false
                ))
        }

        private mutating func promoteHiddenLayer(
            target: ScenePresentationTarget,
            fadeStartTime: TimeInterval,
            fadeDuration: TimeInterval,
            at time: TimeInterval
        ) {
            installHiddenLayerIfNeeded(target: target, at: fadeStartTime)
            for index in layers.indices where layers[index].identity == target.identity {
                layers[index].role = .incoming
                layers[index].opacityAtFadeStart = 0
                layers[index].fadeDuration = fadeDuration
                if shouldFreezeNewLayersForCurrentSuspension {
                    layers[index].fadeStartTime = nil
                    layers[index].suspendedFadeDelay = max(0, fadeStartTime - time)
                    layers[index].motionClock = SceneActiveTimeClock(
                        accumulatedActiveTime: 0,
                        activeAnchorTime: nil
                    )
                } else {
                    layers[index].fadeStartTime = fadeStartTime
                    layers[index].suspendedFadeDelay = nil
                    layers[index].motionClock =
                        isManualNavigationWhilePaused
                        ? SceneActiveTimeClock(accumulatedActiveTime: 0, activeAnchorTime: nil)
                        : SceneActiveTimeClock(startedAt: fadeStartTime)
                }
                layers[index].isMotionEnabled =
                    !isReduceMotionEnabled && !isManualNavigationWhilePaused
                    && !shouldFreezeNewLayersForCurrentSuspension
                // A new presentation does not inherit the previous scene's Reduce Motion freeze.
                layers[index].isMotionFrozenByReduceMotion = false
                layers[index].isPresentationReady = true
            }
        }

        private mutating func completeTransition(at time: TimeInterval) -> [ScenePresentationEffect] {
            materializeLayers(at: time)
            switch underlyingPhase {
            case .transition:
                guard let pendingTarget else {
                    diagnostics.append("transition-without-target")
                    return []
                }
                switch transitionKind {
                case .readyPhoto:
                    return settleIncoming(target: pendingTarget, at: time)
                case .loading:
                    layers.removeAll { $0.role == .outgoing }
                    if targetReadiness[pendingTarget.identity] == .ready {
                        return beginIncomingFromLoading(
                            target: pendingTarget,
                            source: latestAttemptSource(for: pendingTarget.identity) ?? .automatic,
                            at: time
                        )
                    }
                    underlyingPhase = .loading
                    transitionKind = nil
                    return []
                case .none:
                    diagnostics.append("transition-without-kind")
                    return []
                }
            case .incomingFromLoading:
                guard let currentTarget else {
                    diagnostics.append("incoming-without-target")
                    return []
                }
                return settleIncoming(target: currentTarget, at: time)
            default:
                diagnostics.append("transition-complete-invalid-phase")
                return []
            }
        }

        private mutating func settleIncoming(
            target: ScenePresentationTarget,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            layers = layers.map { layer in
                guard layer.identity == target.identity else { return layer }
                var settled = layer
                settled.role = .stable
                settled.opacityAtFadeStart = 1
                settled.fadeStartTime = nil
                settled.fadeDuration = 0
                return settled
            }
            // Fades that end together can leave rounding residue (about 1e-16) on a photo that has faded out.
            layers.removeAll { $0.role == .outgoing && $0.opacity(at: time) <= Self.fadedOutOpacity }
            let settlesAsManualStaticScene = isManualNavigationWhilePaused
            let startsStableClockFrozen = settlesAsManualStaticScene || shouldFreezeNewLayersForCurrentSuspension
            let settledTarget =
                startsStableClockFrozen
                ? target.replacingVisibleIncomingFadeDuration(0)
                : target
            currentTarget = settledTarget
            pendingTarget = nil
            underlyingPhase = .stablePhoto
            stableVisibleClock =
                startsStableClockFrozen
                ? SceneActiveTimeClock(accumulatedActiveTime: 0, activeAnchorTime: nil)
                : SceneActiveTimeClock(startedAt: time)
            transitionKind = nil
            isCurrentSceneManualStatic = settlesAsManualStaticScene
            isManualNavigationWhilePaused = false
            guard !settlesAsManualStaticScene else { return [] }
            return scheduleWakeUp(
                generation: settledTarget.identity.generation,
                purpose: .stableDeadline,
                deadline: time + settledTarget.lifecycle.frozenInterval,
                at: time
            )
        }

        private mutating func receiveReady(
            identity: ScenePresentationIdentity,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            guard pendingTarget?.identity == identity,
                targetReadiness[identity] != nil
            else {
                return reject("stale-ready")
            }
            targetReadiness[identity] = .ready
            updateLatestAttempt(identity: identity, outcome: .ready)
            // With autoplay off at startup, the first scene must still become visible after Ready; only settle the
            // presentation, without resuming motion or the automatic deadline.

            if suspensionReasons == [.userPaused],
                !isManualNavigationWhilePaused,
                underlyingPhase == .loading,
                let pendingTarget
            {
                _ = beginIncomingFromLoading(target: pendingTarget, source: .automatic, at: time)
                return settleIncoming(target: pendingTarget, at: time)
            }
            if suspensionReasons == [.userPaused], !isManualNavigationWhilePaused, let pendingTarget,
                let effects = beginPausedManualCrossfadeIfHeld(to: pendingTarget, at: time)
            {
                return effects
            }
            // After a pause, manual next/back plays a short ~0.3 s crossfade and then stays still; other pause reasons
            // still must not advance Ready.

            guard suspensionReasons.isEmpty || (isManualNavigationWhilePaused && suspensionReasons == [.userPaused])
            else { return [] }
            let source = latestAttemptSource(for: identity) ?? .automatic
            switch underlyingPhase {
            case .grace:
                // When the target becomes Ready during grace, start the photo transition at once instead of waiting out
                // the old scene's remaining grace.

                if let pendingTarget {
                    if suspensionReasons.isEmpty, let raiseEnd = raisedHeldPhotoEnd(at: time) {
                        // A crossfade from a photo still coming back up would start dim; it starts once it is up.
                        return scheduleWakeUp(
                            generation: pendingTarget.identity.generation,
                            purpose: .graceDeadline,
                            deadline: raiseEnd,
                            at: time
                        )
                    }
                    return beginTransition(to: pendingTarget, source: source, at: time)
                }
            case .loading:
                if let pendingTarget {
                    return beginIncomingFromLoading(target: pendingTarget, source: source, at: time)
                }
            case .transition:
                break
            default:
                break
            }
            return []
        }

        /// A pause that arrives while a manual target is held still lets that target cross fade in, then hold still.
        private mutating func beginPausedManualCrossfadeIfHeld(
            to pendingTarget: ScenePresentationTarget,
            at time: TimeInterval
        ) -> [ScenePresentationEffect]? {
            guard underlyingPhase == .grace,
                hasUnseenManualPendingPresentation,
                targetReadiness[pendingTarget.identity] == .ready
            else {
                return nil
            }
            isManualNavigationWhilePaused = true
            suspendedWakeUp = nil
            return beginTransition(
                to: pendingTarget,
                source: latestAttemptSource(for: pendingTarget.identity) ?? .manualNext,
                at: time
            )
        }

        private mutating func receiveFailure(
            identity: ScenePresentationIdentity,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            guard pendingTarget?.identity == identity,
                targetReadiness[identity] != nil
            else {
                return reject("stale-failure")
            }
            targetReadiness[identity] = .failed
            updateLatestAttempt(identity: identity, outcome: .failed)
            guard let pendingTarget else { return [] }

            let recordsForTarget = attemptRecords.filter {
                $0.generation == identity.generation && $0.privateIdentifier == identity.privateIdentifier
            }
            let failedAttemptCount = recordsForTarget.filter { $0.outcome == .failed }.count
            let source = latestAttemptSource(for: identity) ?? .automatic
            let request = effectRequest(for: pendingTarget, source: source)
            if failedAttemptCount <= SceneLifecycleContract.retryLimit {
                let nextAttempt = recordsForTarget.count + 1
                attemptRecords.append(
                    TargetAttemptRecord(
                        identity: identity,
                        source: source,
                        attemptNumber: nextAttempt,
                        startedAt: time,
                        outcome: .pending
                    )
                )
                targetReadiness[identity] = .pending
                return [.retry(request, attemptNumber: nextAttempt)]
            }

            updateLatestAttempt(identity: identity, outcome: .exhausted)
            if source == .automatic {
                return [.plan(request)]
            }
            return [.requestManualDirection(source)]
        }

        private mutating func updateLatestAttempt(
            identity: ScenePresentationIdentity,
            outcome: TargetAttemptOutcome
        ) {
            guard
                let index = attemptRecords.lastIndex(where: {
                    $0.generation == identity.generation && $0.privateIdentifier == identity.privateIdentifier
                })
            else {
                return
            }
            attemptRecords[index].outcome = outcome
        }

        private mutating func cancelAttempt(identity: ScenePresentationIdentity) {
            guard
                let index = attemptRecords.lastIndex(where: {
                    $0.generation == identity.generation && $0.privateIdentifier == identity.privateIdentifier
                        && $0.outcome == .pending
                })
            else {
                return
            }
            attemptRecords[index].outcome = .cancelled
        }

        private func latestAttemptSource(
            for identity: ScenePresentationIdentity
        ) -> ScenePresentationRequestSource? {
            attemptRecords.last(where: {
                $0.generation == identity.generation && $0.privateIdentifier == identity.privateIdentifier
            })?.source
        }

        private mutating func convertVisibleLayersToOutgoing(
            pacing: ScenePresentationPacingPolicy,
            at time: TimeInterval
        ) {
            materializeLayers(at: time)
            layers = layers.compactMap { layer in
                let opacity = layer.opacity(at: time)
                guard opacity > 0 else { return nil }
                var outgoing = layer
                outgoing.role = .outgoing
                outgoing.opacityAtFadeStart = opacity
                outgoing.fadeStartTime = time
                outgoing.fadeDuration = pacing.outgoingFadeDuration
                outgoing.suspendedFadeDelay = nil
                return outgoing
            }
        }

        private mutating func materializeLayers(at time: TimeInterval) {
            layers = layers.compactMap { layer in
                let opacity = layer.opacity(at: time)
                guard opacity > 0 || layer.role != .outgoing else { return nil }
                var materialized = layer
                materialized.opacityAtFadeStart = opacity
                materialized.fadeStartTime = nil
                materialized.suspendedFadeDelay = nil
                if layer.role == .incoming,
                    layer.isPresentationReady,
                    opacity < 1
                {
                    materialized.fadeStartTime = time
                    materialized.opacityAtFadeStart = opacity
                    materialized.fadeDuration = max(
                        0, layer.fadeDuration - max(0, time - (layer.fadeStartTime ?? time)))
                }
                return materialized
            }
        }

        private mutating func suspend(
            reason: ScenePresentationSuspensionReason,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            let shouldFreeze =
                !suspensionReasons.contains(reason) && (suspensionReasons.isEmpty || reason == .background)
            suspensionReasons.insert(reason)
            guard shouldFreeze else { return [] }
            if let effects = fadeInNextPhotoIfPausedInFadeGap(at: time) {
                return effects
            }
            stableVisibleClock?.suspend(at: time)
            for index in layers.indices {
                layers[index].motionClock.suspend(at: time)
            }
            if raisedHeldPhotoEnd(at: time) != nil {
                // A photo being raised for a manual hold, or kept up after Previous cancelled that hold, finishes its
                // short fade during a user pause, like manual navigation. Nobody sees the background, so there it ends
                // at once rather than coming back dim.
                if reason == .background {
                    finishRaisingHeldPhoto()
                }
            } else {
                freezeLayerFades(at: time)
            }
            var effects: [ScenePresentationEffect] = []
            if let wakeUp = scheduledWakeUp {
                scheduledWakeUp = nil
                suspendedWakeUp = ScenePresentationSuspendedWakeUp(
                    generation: wakeUp.generation,
                    purpose: wakeUp.purpose,
                    remaining: max(0, wakeUp.deadline - time)
                )
                effects.append(.cancelWakeUp(generation: wakeUp.generation))
            }
            // A ready manual target waiting for its raised photo to come fully up would wait for a wake-up that does not
            // run while paused; like any held target that is ready during a pause, it cross fades in now.
            if reason == .userPaused, suspensionReasons == [.userPaused], let pendingTarget,
                let crossfade = beginPausedManualCrossfadeIfHeld(to: pendingTarget, at: time)
            {
                return effects + crossfade
            }
            return effects
        }

        /// When the photo raised out of an interrupted transition reaches full opacity, or nil once it has.
        private func raisedHeldPhotoEnd(at time: TimeInterval) -> TimeInterval? {
            layers.compactMap { layer in
                guard layer.isRaisedForHold, layer.role == .incoming, layer.opacity(at: time) < 1,
                    let fadeStartTime = layer.fadeStartTime
                else { return nil }
                return fadeStartTime + layer.fadeDuration
            }.max()
        }

        private mutating func finishRaisingHeldPhoto() {
            layers.removeAll { $0.role == .outgoing }
            for index in layers.indices where layers[index].isRaisedForHold && layers[index].role == .incoming {
                layers[index].opacityAtFadeStart = 1
                layers[index].fadeStartTime = nil
                layers[index].fadeDuration = 0
                layers[index].suspendedFadeDelay = nil
            }
        }

        /// The automatic fade-out ends before the delayed fade-in starts, so a user pause in that gap would freeze an
        /// empty frame. The next photo fades in with the short manual pacing instead and then holds still, as it does
        /// for manual navigation while paused.
        private mutating func fadeInNextPhotoIfPausedInFadeGap(at time: TimeInterval) -> [ScenePresentationEffect]? {
            guard suspensionReasons == [.userPaused],
                underlyingPhase == .transition,
                transitionKind == .readyPhoto,
                !layers.contains(where: { $0.opacity(at: time) > 0 }),
                let pendingTarget,
                let incomingIndex = layers.firstIndex(where: {
                    $0.identity == pendingTarget.identity && $0.role == .incoming && $0.isPresentationReady
                })
            else {
                return nil
            }
            beginManualNavigationWhilePaused()
            let pacing = ScenePresentationPacingPolicy.manualReady
            // The faded-out photo stays as an invisible outgoing layer, so EXIF keeps it until the next photo shows.
            layers[incomingIndex].opacityAtFadeStart = 0
            layers[incomingIndex].fadeStartTime = time + pacing.incomingDelay
            layers[incomingIndex].fadeDuration = pacing.incomingFadeDuration
            layers[incomingIndex].suspendedFadeDelay = nil
            layers[incomingIndex].motionClock = SceneActiveTimeClock(accumulatedActiveTime: 0, activeAnchorTime: nil)
            layers[incomingIndex].isMotionEnabled = false
            return scheduleWakeUp(
                generation: pendingTarget.identity.generation,
                purpose: .transitionCompletion,
                deadline: time + pacing.completionDuration,
                at: time
            )
        }

        private mutating func resume(
            reason: ScenePresentationSuspensionReason,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            guard suspensionReasons.remove(reason) != nil else {
                diagnostics.append("resume-missing-reason")
                return []
            }
            let shouldResumeAutomaticPlayback = suspensionReasons.isEmpty
            let shouldResumeManualTransitionWhilePaused =
                isManualNavigationWhilePaused && suspensionReasons == [.userPaused]
            let shouldReconcilePausedReadyLoadingTarget: Bool
            if let pendingTarget {
                shouldReconcilePausedReadyLoadingTarget =
                    suspensionReasons == [.userPaused] && targetReadiness[pendingTarget.identity] == .ready
                    && (underlyingPhase == .loading
                        || (underlyingPhase == .grace && hasUnseenManualPendingPresentation))
            } else {
                shouldReconcilePausedReadyLoadingTarget = false
            }
            guard
                shouldResumeAutomaticPlayback || shouldResumeManualTransitionWhilePaused
                    || shouldReconcilePausedReadyLoadingTarget
            else {
                return []
            }
            if isCurrentSceneManualStatic,
                let currentTarget
            {
                guard shouldResumeAutomaticPlayback else { return [] }
                resumeManualStaticMotion(currentTarget: currentTarget, time: time)
                suspendedWakeUp = nil
                return scheduleWakeUp(
                    generation: currentTarget.identity.generation,
                    purpose: .stableDeadline,
                    deadline: time + currentTarget.lifecycle.frozenInterval,
                    at: time
                )
            }
            if shouldResumeAutomaticPlayback {
                resumeAutomaticLayerMotion(time: time)
            }
            if shouldResumeAutomaticPlayback, isManualNavigationWhilePaused {
                // After Play is pressed during a pending target or short crossfade, later Ready/completion must follow
                // autoplay semantics again.

                updateCurrentTargetForResumedManualIncoming(at: time)
                isManualNavigationWhilePaused = false
            }
            resumeLayerFades(at: time, shouldResumeMotion: shouldResumeAutomaticPlayback)
            if isTransitionCompletionPending {
                isTransitionCompletionPending = false
                suspendedWakeUp = nil
                return completeTransition(at: time)
            }
            if let pendingTarget,
                targetReadiness[pendingTarget.identity] == .ready
            {
                if suspensionReasons == [.userPaused],
                    !isManualNavigationWhilePaused,
                    underlyingPhase == .loading
                {
                    _ = beginIncomingFromLoading(target: pendingTarget, source: .automatic, at: time)
                    return settleIncoming(target: pendingTarget, at: time)
                }
                if suspensionReasons == [.userPaused], !isManualNavigationWhilePaused,
                    let effects = beginPausedManualCrossfadeIfHeld(to: pendingTarget, at: time)
                {
                    return effects
                }
                switch underlyingPhase {
                case .grace:
                    // No progress in the background; on returning to the foreground, a grace target that is already
                    // Ready starts its photo transition at once.

                    suspendedWakeUp = nil
                    if suspensionReasons.isEmpty, let raiseEnd = raisedHeldPhotoEnd(at: time) {
                        // Play during a raise waits for the raised photo, as a target that is ready while playing does.
                        return scheduleWakeUp(
                            generation: pendingTarget.identity.generation,
                            purpose: .graceDeadline,
                            deadline: raiseEnd,
                            at: time
                        )
                    }
                    return beginTransition(
                        to: pendingTarget,
                        source: latestAttemptSource(for: pendingTarget.identity) ?? .automatic,
                        at: time
                    )
                case .loading:
                    suspendedWakeUp = nil
                    return beginIncomingFromLoading(
                        target: pendingTarget,
                        source: latestAttemptSource(for: pendingTarget.identity) ?? .automatic,
                        at: time
                    )
                default:
                    break
                }
            }
            guard let suspendedWakeUp else { return [] }
            self.suspendedWakeUp = nil
            return scheduleWakeUp(
                generation: suspendedWakeUp.generation,
                purpose: suspendedWakeUp.purpose,
                deadline: time + suspendedWakeUp.remaining,
                at: time
            )
        }

        /// On Play, a visible manual short crossfade continues from the current sample; a hidden layer that is not
        /// Ready keeps its original window.

        private mutating func updateCurrentTargetForResumedManualIncoming(at time: TimeInterval) {
            guard let currentTarget,
                underlyingPhase == .transition || underlyingPhase == .incomingFromLoading,
                let index = layers.firstIndex(where: {
                    $0.identity == currentTarget.identity && $0.role == .incoming && $0.isPresentationReady
                })
            else {
                return
            }

            let layer = layers[index]
            let remainingFade: TimeInterval
            if let delay = layer.suspendedFadeDelay {
                remainingFade = max(0, delay) + max(0, layer.fadeDuration)
            } else if let fadeStartTime = layer.fadeStartTime {
                let remainingDelay = max(0, fadeStartTime - time)
                let elapsed = max(0, time - fadeStartTime)
                remainingFade = remainingDelay + max(0, layer.fadeDuration - elapsed)
            } else if layer.opacityAtFadeStart < 1 {
                remainingFade = max(0, layer.fadeDuration)
            } else {
                remainingFade = 0
            }

            let adjustedTarget = currentTarget.replacingVisibleIncomingFadeDuration(remainingFade)
            self.currentTarget = adjustedTarget
            if pendingTarget?.identity == adjustedTarget.identity {
                pendingTarget = adjustedTarget
            }
        }

        private mutating func updateReduceMotion(_ isEnabled: Bool, at time: TimeInterval) {
            guard isEnabled != isReduceMotionEnabled else { return }
            isReduceMotionEnabled = isEnabled
            if isEnabled || !isManualNavigationWhilePaused {
                Self.reconcileReduceMotion(
                    isEnabled,
                    in: &layers,
                    at: time,
                    canResumeUnseenMotion: !isEnabled && suspensionReasons.isEmpty
                )
            }

            // The capture behind a held manual target must follow the toggle too, or cancelling restores a stale freeze.

            if var restore = manualPendingPresentationRestore {
                Self.reconcileReduceMotion(
                    isEnabled,
                    in: &restore.layers,
                    at: time,
                    canResumeUnseenMotion: false
                )
                manualPendingPresentationRestore = restore
            }
        }

        /// An unseen incoming follows the latest Reduce Motion setting; once a seen photo is frozen it stays frozen,
        /// and turning the setting off does not restart it.

        private static func reconcileReduceMotion(
            _ isEnabled: Bool,
            in layerStates: inout [ScenePresentationLayerState],
            at time: TimeInterval,
            canResumeUnseenMotion: Bool
        ) {
            for index in layerStates.indices {
                if isUnseenDelayedIncoming(layerStates[index], at: time) {
                    if isEnabled {
                        layerStates[index].motionClock.suspend(at: time)
                        layerStates[index].isMotionEnabled = false
                        layerStates[index].isMotionFrozenByReduceMotion = true
                    } else {
                        layerStates[index].isMotionFrozenByReduceMotion = false
                        layerStates[index].isMotionEnabled = true
                        if canResumeUnseenMotion,
                            let fadeStart = layerStates[index].fadeStartTime
                        {
                            layerStates[index].motionClock.resume(at: fadeStart)
                        }
                    }
                    continue
                }

                guard isEnabled, layerStates[index].isMotionEnabled else { continue }
                // A seen photo keeps its current sample and only freezes active time; new layers are still created per
                // isReduceMotionEnabled.

                layerStates[index].motionClock.suspend(at: time)
                layerStates[index].isMotionFrozenByReduceMotion = true
            }
        }

        /// An incoming that is not yet visible has no user-visible sample, so it must use identity like a future fade.

        private static func isUnseenDelayedIncoming(
            _ layer: ScenePresentationLayerState,
            at time: TimeInterval
        ) -> Bool {
            guard layer.role == .incoming, layer.opacity(at: time) == 0 else { return false }
            return layer.fadeStartTime.map { $0 > time } == true || layer.suspendedFadeDelay != nil
        }

        /// Pausing must save each layer's opacity progress so far and any incoming delay that has not started yet.
        private mutating func freezeLayerFades(at time: TimeInterval) {
            freezeLayerFadeSamples(&layers, at: time)
        }

        private func freezeLayerFadeSamples(
            _ layerStates: inout [ScenePresentationLayerState],
            at time: TimeInterval
        ) {
            for index in layerStates.indices {
                guard let fadeStart = layerStates[index].fadeStartTime else { continue }
                let originalOpacity = layerStates[index].opacityAtFadeStart
                let originalDuration = layerStates[index].fadeDuration
                if time < fadeStart {
                    layerStates[index].suspendedFadeDelay = fadeStart - time
                    layerStates[index].fadeStartTime = nil
                    continue
                }

                let opacity = layerStates[index].opacity(at: time)
                layerStates[index].opacityAtFadeStart = opacity
                layerStates[index].fadeStartTime = nil
                layerStates[index].suspendedFadeDelay = nil
                switch layerStates[index].role {
                case .outgoing:
                    guard originalOpacity > 0 else { continue }
                    layerStates[index].fadeDuration = max(0, originalDuration * opacity / originalOpacity)
                case .incoming:
                    // A second freeze must keep the previous opacity speed; it must not shorten the already-shortened
                    // remaining duration again by the absolute opacity.

                    let remainingAmplitude = 1 - originalOpacity
                    guard remainingAmplitude > 0 else {
                        layerStates[index].fadeDuration = 0
                        continue
                    }
                    layerStates[index].fadeDuration = max(
                        0,
                        originalDuration * (1 - opacity) / remainingAmplitude
                    )
                case .stable:
                    break
                }
            }
        }

        /// Resume only rebuilds frozen fades; it does not make up for the paused time.
        private mutating func resumeLayerFades(
            at time: TimeInterval,
            shouldResumeMotion: Bool
        ) {
            for index in layers.indices {
                let delay = layers[index].suspendedFadeDelay
                if let delay {
                    layers[index].fadeStartTime = time + delay
                    layers[index].suspendedFadeDelay = nil
                    if shouldResumeMotion,
                        layers[index].isMotionEnabled,
                        !isReduceMotionEnabled,
                        !layers[index].isMotionFrozenByReduceMotion
                    {
                        layers[index].motionClock.resume(at: time + delay)
                    }
                    continue
                }

                // A manual short crossfade that was not frozen still runs on the wall clock; resume must not move the
                // fade start to now, or the opacity would go backwards.

                let hasActiveFade = layers[index].fadeStartTime != nil

                if shouldResumeMotion,
                    layers[index].isMotionEnabled,
                    !isReduceMotionEnabled,
                    !layers[index].isMotionFrozenByReduceMotion
                {
                    layers[index].motionClock.resume(at: time)
                }
                guard !hasActiveFade else { continue }
                switch layers[index].role {
                case .outgoing where layers[index].opacityAtFadeStart > 0:
                    layers[index].fadeStartTime = time
                case .incoming where layers[index].isPresentationReady && layers[index].opacityAtFadeStart < 1:
                    layers[index].fadeStartTime = time
                case .stable, .outgoing, .incoming:
                    break
                }
            }
        }

        private mutating func reject(_ diagnostic: String) -> [ScenePresentationEffect] {
            diagnostics.append(diagnostic)
            return []
        }

        private mutating func scheduleWakeUp(
            generation: UUID,
            purpose: ScenePresentationWakeUpPurpose,
            deadline: TimeInterval,
            at time: TimeInterval
        ) -> [ScenePresentationEffect] {
            if shouldFreezeNewLayersForCurrentSuspension {
                scheduledWakeUp = nil
                suspendedWakeUp = ScenePresentationSuspendedWakeUp(
                    generation: generation,
                    purpose: purpose,
                    remaining: max(0, deadline - time)
                )
                return []
            }
            scheduledWakeUp = ScenePresentationScheduledWakeUp(
                generation: generation,
                purpose: purpose,
                deadline: deadline
            )
            suspendedWakeUp = nil
            return [.scheduleWakeUp(generation: generation, deadline: deadline)]
        }
        private mutating func resumeManualStaticMotion(
            currentTarget: ScenePresentationTarget,
            time: TimeInterval
        ) {
            isCurrentSceneManualStatic = false
            stableVisibleClock?.resume(at: time)
            for index in layers.indices where layers[index].identity == currentTarget.identity {
                if !isReduceMotionEnabled, !layers[index].isMotionFrozenByReduceMotion {
                    layers[index].isMotionEnabled = true
                    layers[index].motionClock.resume(at: time)
                }
            }
        }

        private mutating func resumeAutomaticLayerMotion(
            time: TimeInterval
        ) {
            stableVisibleClock?.resume(at: time)
            for index in layers.indices where !layers[index].isMotionFrozenByReduceMotion {
                // With a visible transition in progress, an incoming that has not started must wait for its
                // original delay; the first scene has no old layer, so motion can restart at once.

                let defersIncomingMotionUntilFade =
                    underlyingPhase == .transition && layers[index].role == .incoming
                    && layers[index].suspendedFadeDelay != nil
                guard !defersIncomingMotionUntilFade else { continue }
                guard !isReduceMotionEnabled else { continue }
                layers[index].isMotionEnabled = true
                layers[index].motionClock.resume(at: time)
            }
        }

    }
}
