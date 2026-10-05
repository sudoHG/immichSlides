# Architecture

A map of the code for contributors and their coding agents. It tells you where things live, which types own which job, and what the domain words in code and tests mean. Source code and tests describe actual behavior; if this guide disagrees with them, the code wins and the guide should be fixed. Working rules are in [AGENTS.md](../AGENTS.md), test rules in [TESTING.md](TESTING.md).

## 1. Overview

immichSlides is a SwiftUI slideshow client for [Immich](https://immich.app) servers. It runs on iPhone, iPad and Apple TV from one multiplatform app target. The user connects to a server with a URL and an API key, chooses what to play (random photos from the whole library, or a filtered set of albums and people), and the app plays photos full screen. In the default display mode, SmartFill, one screen ("scene") can show one, two or three photos laid out so faces are not cropped. The alternative, single photo mode, shows one photo per scene. Both modes use the same scene lifecycle, fades and slow motion ("Ken Burns" style) animation.

### Main user flows

The root flow is `ContentView` with `AppFlowStateMachine` and `AppRoute` (`firstBoot`, `modeSelection`, `filterSummary`, `slideshow`).

1. **First boot / server config.** No saved server → `FirstBootView` hosts `ServerConfigFormView`. `ImmichServer.testConnection` probes the server; a successful save writes the API key to the Keychain first, then the URL (`ImmichServer.save`).
   `SettingsServerViewModel` appends localized URL, API key and reachability guidance after connection-test errors, including input validation errors. Save errors retain their existing messages.
2. **Mode selection.** `ModeSelectionView` offers `SlideMode.random` (go straight to playback) or `SlideMode.filtered` (go to the filter summary).
3. **Filter summary.** `FilterSummaryView` shows the current `FilterSelection` and leads to `AlbumFilterView` / `PersonFilterView`. "Start" calls `SlideShowViewModel.preparePlaybackSourceForPresentation(to: .filtered(selection))` and switches to the slideshow route without waiting for the pool.
4. **Slideshow.** `SlideShowView` forwards to `SlideShowViewIOS` or `SlideShowViewTV`, both driven by the shared `SlideShowViewModel`. On a cold launch with a saved server the app goes straight here, using the saved default mode (`ContentView.initialPlaybackSourceForColdLaunch`).
5. **Settings.** Opened from the slideshow control bar. `SettingsView` forwards to `SettingsViewIOS` / `SettingsViewTV`; sections are listed in `SettingSelection` (playback, access protection, server, cache, about). Playback settings are the `PlaybackSettings` value, persisted by `PlaybackSettingsStore` and edited through `PlaybackSettingsViewModel`. Changing the server posts `.serverConfigurationDidChange`, which clears stale filters.
6. **Access protection (PIN).** When enabled, opening settings from the slideshow requires a 6-digit PIN (`PinEntrySheetView`), and the onboarding back paths are hidden. The PIN is stored as a salted hash in the Keychain (`AccessProtectionStore`); `AccessProtectionViewModel` enables, disables and changes it. If the flag is on but the Keychain material is gone, `isRecoveryNeeded` offers a reset.

## 2. Module map

| Path | What belongs there |
|---|---|
| `immichSlides/Shared/Model/` | All non-view logic for both platforms: API client and models, stores, view models, playback pool, SmartFill planner, playback session engine and scene presentation reducer, motion math, image download and cache. |
| `immichSlides/Shared/Core/` | Shared screen entry points (`ContentView`, `SlideShowView`, `SettingsView`, `FilterSummaryView`, …). Many only switch between the iOS and tvOS screen with `#if os(tvOS)`. |
| `immichSlides/Shared/Component/` | Reusable views and view-level helpers used by both platforms: scene renderers (`SmartFillSceneView`, `SlideItemView`), `ExifInfoView`, `SlidePlaybackLoadingView`, `SceneVisibleFrameReporter`, `PlatformCompat`, `ViewLayoutTraits`. |
| `immichSlides/iOS/Core/`, `iOS/Component/` | iPhone/iPad screens and components (suffix `IOS`), app entry `immichSlidesApp_iOS.swift`. |
| `immichSlides/tvOS/Core/`, `tvOS/Component/`, `tvOS/Model/` | Apple TV screens, focus and remote handling (suffix `TV` / `TVOS`, `TV` prefix for some components), tvOS-only view models, app entry `immichSlidesApp_tvOS.swift`. |
| `Config/` | `env.example.xcconfig` and `Debug.xcconfig`. The optional, git-ignored `env.xcconfig` is included by `Debug.xcconfig`, which is referenced only by Debug configurations. |
| `immichSlides/Localizable.xcstrings` | Every user-visible string. |
| `immichSlidesTests/` | Unit tests (Swift Testing). Files with `Live` in the name (for example `PlaybackPoolResolverLiveIntegrationTests`) need a real server and skip without one. |
| `immichSlidesUITests/` | UI tests (XCTest), including the `StrictE2E*` flows run by `scripts/run_strict_e2e.py`. |
| `TestSupport/` | Helpers shared by test targets (server config, strict E2E inputs, evidence manifests). Never used by production code. |
| `scripts/` | Test runners, lint and release checks, localization tools, privacy gate. Most scripts have a matching `test_*.py`. |

Target membership: the app is one Xcode target built for iOS and tvOS, using synchronized folders. Files under `iOS/` and `tvOS/` are kept to their platform by per-file platform filters in the project (a few use a file-wide `#if os(...)` instead). A new file in those folders builds for both platforms until you set its filter, so check it and state it in your report. Every other file in the folder is compiled or copied into the app bundle, so keep notes, backups and scratch files outside `immichSlides/`. The target's membership exceptions keep two files out of automatic membership: `Info.plist` (read through the `INFOPLIST_FILE` build setting) and `PrivacyInfo.xcprivacy` (bundled through its own file reference). Local build configuration lives in the repository-root `Config/`, outside the app folder. `scripts/check_release_guards.py` fails if any file in a `Config/` folder or any `.xcconfig` file (including backups such as `env.xcconfig.bak`) sits inside `immichSlides/`, even when it is listed as an exception, if a stale config exception remains in the app target, or if an `.xcconfig` is added to a build phase.

### Where does new code go?

- **New setting.** Add a field to `PlaybackSettings` (in `ImmichModels.swift`) with a default and a `decodeIfPresent` fallback so old saved data still loads. Edit it through `PlaybackSettingsViewModel`; `SlideShowViewModel` picks up changes from the `.playbackSettingsDidChange` notification. Add the UI in both `SettingsView+Sections.swift` (iOS) and the matching `SettingsViewTV+*Pages.swift` file (tvOS). Strings go into `Localizable.xcstrings`.
- **New Immich API call.** Add a method on `ImmichAPIService` and the Codable types in `ImmichModels.swift` / `ImmichTypes.swift`. Authenticated image requests go through `ImmichRequestModifier` / `ImmichHTTPHeaders`. Views never call the API; a view model, store or resolver does.
- **New playback behavior.** Decide which layer owns it:
  - which photos are eligible: `PlaybackPoolResolver`
  - source generation, ordered candidates and loading status: `PlaybackPoolLoader`
  - candidate traversal, selection reservations and planning context: `PlaybackCandidateProgression`
  - how photos are grouped and cropped on one screen: `PlaybackSmartFillPlanner` / `PlaybackSmartFillLayoutPolicy`
  - when scenes change, fade, pause or retry: the reducer in `PlaybackSessionEngine+ScenePresentationState.swift`; its private layer timeline owns fade and motion samples, and its presentation values remain in `ScenePresentationTypes.swift`
  - motion inside a scene: `SceneAnimationProfile`, `MotionTransformResolver` and related `Motion*` types
  - wiring it together: `SlideShowViewModel`

  Keep pure logic in `nonisolated` value types so it can be unit tested without the UI.
- **New platform-specific UI.** Put the screen in `iOS/Core` or `tvOS/Core` with the platform suffix, and keep the shared entry in `Shared/Core` as a thin `#if os(...)` switch. tvOS focus code stays in `tvOS/`. Put platform branches for colors and modifiers in `PlatformCompat`, and device and size-class checks in `ViewLayoutTraits`. Don't put them inline in shared views.
- **New test helper.** Helpers used by one unit test file stay in that file. Helpers shared across unit tests go next to them in `immichSlidesTests/` (for example `AsyncTestWait.swift`). Helpers shared by unit and UI tests go in `TestSupport/`. Production hooks for tests end in `ForTesting` and are usually inside `#if DEBUG`.

## 3. Key types

| Type | File | Responsibility |
|---|---|---|
| `ImmichServer` | `Shared/Model/immichServer.swift` | Server URL and API key: validate, test connection, save (Keychain + UserDefaults), load. |
| `ImmichAPIService` | `Shared/Model/ImmichAPIService.swift` | Singleton HTTP client: albums, people, person asset counts, random assets, asset by id, thumbnail URLs. |
| `FilterViewModel`, `FilterSelectionStore` | `Shared/Model/` | Album and people lists for the filter screens; persist the user's `FilterSelection`. |
| `PlaybackPoolResolver` | `Shared/Model/PlaybackPoolResolver.swift` | Turns a `FilterSelection` into a list of `Asset`s (the playback pool). Splits a request budget across album and person rules, deduplicates, and keeps a recently played cooling list. |
| `PlaybackPoolLoader` | `Shared/Model/SlideShowViewModel.swift` (file-private type) | Privately owns the playback source, integer source generation, ordered pool, initial-load identities and refill request ownership. Acquires uncommitted results, validates supplied session values, and directs synchronous loading publications without storing duplicate loading flags. |
| `PlaybackCandidateProgression` | `Shared/Model/PlaybackCandidateProgression.swift` | Privately owns the candidate cursor, pending cursor, displayed and reserved asset IDs, refill-resume marker, surface and protection snapshot for single photo and SmartFill planning. Receives pool values and synchronous selection/acceptance commands; never owns the engine or publishes state. |
| `SoloVisionPoolFilter`, `VisionFaceAuditService` | `Shared/Model/` | For solo-only person rules, re-checks candidates on device with Vision and keeps photos with exactly one face. |
| `PlaybackSmartFillPlanner` | `Shared/Model/PlaybackSmartFillPlanner.swift` | Pure, synchronous planner. From candidate summaries, surface size and protection snapshot, chooses a single, double or triple layout with crop rects, or a fallback with a reason. No network, cache or SwiftUI. |
| `SmartFillPreparedPlanBuilder` | `Shared/Model/PlaybackSmartFillTypes.swift` | Runs the planner on a captured `SmartFillPreparedPlanRequest` off the main actor and returns a `SmartFillPreparedPlanResult`. Both prepared and synchronous planning use the pure `nonisolated` `PlaybackSmartFillSceneReadback.fromPlannerResult` conversion. |
| `PlaybackScene`, `PhotoSlot` | `Shared/Model/PlaybackScene.swift` | What one screen shows: slots (asset + planning snapshot), fallback reason, protection snapshot, SmartFill readback. |
| `PlaybackSessionEngine` | `Shared/Model/PlaybackSessionEngine.swift` | Pure state for one playback session: scene list, current index, pending transition, prepared scene ring, and the `ScenePresentationState`. |
| `ScenePresentationState` (reducer) | `Shared/Model/PlaybackSessionEngine+ScenePresentationState.swift` | The only presentation policy owner: phases, targets, readiness, hold/transition decisions, pause and background suspension, Reduce Motion, visible history and deadlines. Takes `ScenePresentationEvent`s and returns `ScenePresentationEffect`s. |
| `ScenePresentationLayerTimeline` (private value) | Same reducer file | Owns the ordered layers, opacity/fade sampling, layer motion clocks, freeze/resume mechanics and immutable render-layer snapshots. Executes synchronous reducer decisions without owning phases, targets, suspension reasons or effects. |
| `ScenePresentationEffect` | `Shared/Model/ScenePresentationEffect.swift` | Commands the reducer emits (`plan`, `download`, `retry`, `loadMore`, `scheduleWakeUp`, `cancelWakeUp`, `cancel`, …). Planning carries an explicit purpose and demand tag. Plain values, no tasks. |
| `ScenePresentationPrerenderBarrier` | `Shared/Model/ScenePresentationPrerenderBarrier.swift` | Tracks when every renderer of a hidden incoming scene has decoded. Decoded does not mean seen. |
| `SceneVisibleFrameReporter` | `Shared/Component/SceneVisibleFrameReporter.swift` | Reports a scene as visible only on the display tick after its render transaction completes. That report is what commits history. |
| `SlideShowViewModel` | `Shared/Model/SlideShowViewModel.swift` | `@MainActor` coordinator for playback. Delegates pool loading and candidate progression, plans scenes, runs reducer effects, starts downloads, keeps `PlaybackHistoryLedger` (previous / redo / next), and publishes render state to the platform views. |
| `PlaybackRuntimeEvidenceRecorder` | `Shared/Model/PlaybackRuntimeEvidenceRecorder.swift` | Owns startup timestamps and first-plan metrics, pending action timestamps, presentation counters, Debug frame accumulation and the Debug sequence recorder. Observes supplied values and exposes immutable startup snapshots and serialized summaries; never owns the engine or changes playback. |
| `AssetsDownloadManager` | `Shared/Model/AssetsDownloadManager.swift` | `@MainActor` singleton around SDWebImage. Loads and preloads images by `(assetId, ThumbnailSize)` with high/low priority, merges duplicate in-flight requests, tracks readiness and clears caches. `PlaybackImageCachePolicy` sets memory cache limits. |
| `SmartFillSceneView`, `SlideItemView` | `Shared/Component/` | Render a scene. `SmartFillSceneView` lays out planner slots; it uses `SlideItemView` (single photo, legacy renderer) when a scene has no SmartFill readback, or is a fallback without a motion context. |
| `ExifInfoView`, `ExifForegroundAnalyzer` | `Shared/Component/` | EXIF overlay (camera, exposure, date, place) and choosing a readable text tone against the photo behind it. |
| `PlaybackSettingsStore`, `AccessProtectionStore` | `Shared/Model/` | Persistence for playback settings (UserDefaults JSON) and PIN protection (flag in UserDefaults, PIN hash in Keychain). |
| `SettingsPromptStore` | `Shared/Core/SettingsView.swift` | Observable prompt state shared by settings detail pages, including blocked-mode and cache-clear alerts. |
| `PlatformCompat`, `ViewLayoutTraits` | `Shared/Component/` | Platform branches for colors, view modifiers, tvOS focus helpers and debug switches; device and size-class checks. |

Large implementations use adjacent `TypeName+Topic.swift` extensions. `SlideShowViewModel` keeps its playback state, collaborator references and initializer in its primary file; scene presentation, navigation, planning and initial preload methods live in those topic extensions. Its file-private pool loader and synchronous mutation adapters are co-located with the stored `@Published private(set)` projections so Swift access control can keep both the loader instance and projection writer private; `applyPlaybackAssets` and `resetScenePresentationRuntime` live there too because they write the pool through that adapter. The pool-loading extension retains refill eligibility, scene readiness, `currentPlaybackMode`, the Debug Vision-probe flag and `loadIndexChangePhoto`. Its navigation and runtime evidence extensions sample the clocks that `PlaybackRuntimeEvidenceRecorder` stores; the evidence extension also samples download records and applies scene publication timing annotations from the recorder's consumed action timestamp. `PlaybackSmartFillPlanner` similarly separates search, evaluation, geometry and readback. `AssetsDownloadManager+Diagnostics.swift` holds its Debug diagnostics, while `SDWebImageAsyncBridge.swift` owns the callback bridge. `ImmichServer` separates connection probes and test configuration; its persistence and Keychain operations remain in `immichServer.swift`. Runtime manifest validation remains in `PlaybackRuntimeEvidenceManifest.swift`, and scene QA lives in `PlaybackScene+RuntimeQA.swift` with the original Debug guards.

Evidence observations remain synchronous at their original call sites. Reading the startup summary can record missing readiness milestones, with one clock sample per newly recorded phase; reading the presentation probe accumulates Debug frame evidence from an immutable render snapshot, motion progress and history count. The existing readiness metric still allows pending or failed slots after a ready slot has been observed. Startup reset clears only startup evidence, presentation reset clears only decode/readiness counters and history flags, and action reset clears only pending action timings; sequence history and frame accumulation survive these resets. The recorder does not access the download manager, Vision auditing or the engine itself. The facade supplies startup/action timestamps; sequence output still delegates its clock sampling, redaction, JSONL limits and serialization to `PlaybackSequenceDebugRecorder`, and the facade retains the existing Debug enablement and OSLog path.

The private pool adapter in `SlideShowViewModel.swift` supplies immutable session values from the engine before acquisition and again before application; the loader never queries the engine or stores a live session-context copy. After applying a successful initial replacement, the facade explicitly records the applied identity with the post-reset session values at that same synchronous point. Initial results validate source generation, source summary, session ID and scene ID; refill results deliberately omit scene ID so navigation within a session does not discard them. Initial preload receives an opaque read-only identity from the facade. Random and filtered acquisition, failure handling and source-specific evidence remain separate. Their validated successful refills share the loader's private `appendRefillAssets` mutation, which returns an explicit `Update.refillFinished` for application after the existing loading and result-evidence writes.

The loader owns the ordered pool, while `SlideShowViewModel.assets`, `isLoading`, `isLoadingMore` and `emptyPlaybackMessage` remain synchronous `@Published private(set)` projections. The only stored loading booleans are those facade projections; the loader owns their transitions and refill cleanup identity, and the private adapter applies every requested publication, including repeated values. Application preserves separate append and trim emissions: append, filtered-only cursor resume against the untrimmed pool, empty-message update, cache eviction, prefix removal, cursor adjustment and engine readback. Trim observations use a separate required non-escaping callback, so a generic update callback alone cannot apply a refill. Loading and evidence writes remain at their original points. No callback is deferred or moved to another task. The existing published `maxAssetCount` setting synchronizes the loader's capacity via `didSet`; its declaration documents that initialization must supply the same value to both because property observers do not run during `init`. Both types join both platforms through the synchronized `Shared/` folder; Debug fixture commands change only the corresponding pool or loading value and are covered by the release guard. `overwritePlaybackPoolWithoutResetForTesting` deliberately preserves the session and cursor, unlike the full-reset `replacePlaybackAssetsForTesting` command.

The iOS and tvOS slideshow views keep their property wrappers in the primary declarations and place diagnostics, rendering and EXIF methods in platform-filtered extensions. tvOS settings server/cache, About/licenses and bundled privacy pages have separate extension files; their focus state remains owned by `SettingsViewTV`.

`SlideShowViewModel+SettingsApplication.swift` owns the settings refresh run on slideshow entry and on `UserDefaults.didChangeNotification`. The platform EXIF adapters supply synchronous visibility setters. The refresh applies the view model's playback settings, reads the presentation settings, updates EXIF then debug-overlay visibility, decides whether the source changed, and schedules an asynchronous source switch only when needed. Cold-launch source selection stays in `ContentView.initialPlaybackSourceForColdLaunch()`. This extension has no stored state and joins both platforms through the app's synchronized `Shared/` folder.

Playback QA strings, overlay download metrics, ViewModel injection hooks and diagnostic Vision state compile only in Debug. Their numeric runtime timing records, ordinary download logs and the Vision service used by solo-person filtering remain available in Release. UI-test preparation, hint suppression, reset and contract-probe switches are owned by `PlatformCompat`; focus marker exposure uses `shouldExposeUITestProbes` without changing tvOS focus routing. Release settings-resume suites launch through the real UI with no `UI_TEST_*` overrides.

The reducer's `ScenePresentationLayerTimeline` is co-located with it so the value type and its layer storage stay private. The reducer chooses when to hold, transition, settle, suspend or resume, and passes the timing and motion conditions into synchronous timeline operations. It also keeps the stable-visible clock that determines automatic deadlines; each layer's independent motion clock belongs to the timeline. Manual restoration carries a value copy of the timeline alongside its existing reducer fields. Attempt accounting, restoration policy, event/effect order and the frozen planning interface stay in the reducer.

### Data flow: "play the next scene"

1. **Deadline.** When a scene becomes stable, the reducer emits `scheduleWakeUp`. `SlideShowViewModel.executeScenePresentationEffects` sleeps until the deadline and sends `.wakeUp` back. The reducer answers with a `.plan` effect.
2. **Choose the scene.** For `.plan`, or for a manual `requestNextScene()`, the view model does one of these:
   - replays the redo entry from `PlaybackHistoryLedger`
   - consumes the prepared next scene from the engine's `PlaybackPreparedSceneRing`
   - plans a SmartFill scene from the candidate cursor
   - builds a single photo scene

   The engine records a `PlaybackSessionTransition` (`requestNext` / `requestTransition`).
3. **Start presenting.** `beginPendingScenePresentationIfNeeded` captures the pending candidate reservation, then calls `PlaybackSessionEngine.beginScenePresentation`. On successful transition acceptance, the view model records publication timing and synchronously applies the reservation through `PlaybackCandidateProgression`: displayed IDs advance, and a newly appended tail scene advances the candidate cursor. It then installs a ready lookahead proposal (`applySmartFillMotionLookaheadPreparedPlanIfReady`); otherwise, it refreshes the prepared ring in the background (`refreshPreparedSmartFillSceneRingIfPossible`). Next, it starts the renderer barrier and executes the reducer's effects (`download` and wake-ups).
4. **Download.** The `download` effect runs a `@MainActor` task keyed by the target's generation. It calls `AssetsDownloadManager.loadPhoto` for each slot, then preloads the next candidate window and playback window.
5. **Decode.** The platform view renders the incoming scene as a hidden layer. Each renderer reports decoded or failed through `rendererDecoded` / `rendererFailed`. When the barrier is complete, the reducer marks the target ready and starts the transition: outgoing fade, incoming delay, incoming fade. If the target is not ready at the deadline, the current photo stays up for a grace period, then a loading transition shows. Failed targets are retried up to a limit.
6. **Visible.** `SceneVisibleFrameReporterModifier` calls `onSceneBecameVisible` for eligible stable or incoming scene roots; platform views forward it to `SlideShowViewModel.incomingBecameVisible`. The reducer appends the identity to its history, and the view model commits the scene to `PlaybackHistoryLedger` and asks for more pool assets if the pool is running low (`loadMore`). Candidate progression already advanced at successful transition acceptance.

Platform views only forward system events (scene phase, Reduce Motion, remote/touch input) to the view model and draw the `SceneRenderSnapshot` they get back. They hold no playback state machine of their own.

### Frozen planning event/effect interface

The reducer owns demand and validates its lifetime. The facade executes navigation and barriers;
planning computes and delivers proposals. Later extractions of planning, scheduling, effect execution,
session ownership and reducer internals preserve this value interface:

- `ScenePresentationEffect.plan(ScenePresentationPlanningRequest)` carries an immutable `tag: UInt64`,
  `target: ScenePresentationEffectRequest` (the full presentation identity and source), and
  `purpose: ScenePresentationPlanningPurpose`. The reducer increments its sequence before each new
  command (first tag: 1); retries reuse that tag. Identical event sequences produce identical effects.
  A command emitted during user pause is skipped by the executor and does not replace the reducer's
  outstanding demand; both reducer and facade retain the previously executed demand, if any.
  Reset replaces reducer state and the navigation generation, so a restarted sequence cannot accept
  a completion from the old session. The tag is neither a navigation token nor a proposal fingerprint.
- `ScenePresentationEvent.effectResult(.planningCompleted(request))` carries the facade's last executed
  automatic demand at proposal delivery time. The reducer may reissue `.plan(request)` unchanged.
  Admission requires an exact outstanding-request match, its target still being current or pending,
  and either a stable current presentation or a failed pending target. User pause rejects completion;
  background suspension alone does not, matching the facade's existing `isAutoPlay` admission gate.
  This relies on an invariant: the executor's `isAutoPlay` gate and the reducer's `.userPaused`
  suspension change together (`updateAutoPlayEnabled`, and readback sync after a reset). A caller that
  turns autoplay off without suspending the reducer breaks demand matching.
  Purpose records why demand was issued, rather than imposing a stricter completion policy: a stable
  photo's demand can still complete after an intervening manual target fails or is cancelled back to
  that photo. Replacing a pending target retires matching demand through an explicit
  `retirePlanningDemand(for:)` call outside attempt bookkeeping (manual restoration cannot hold matching
  demand, so it has no such call); registering
  a different pending target does not retire demand retained by the current photo. Stale completion
  returns no effects and does not append diagnostics. Known theoretical difference from the previous
  facade: an executed automatic navigation keeps the photo's old demand instead of clearing it, so a
  stale manual-hold restore that makes that photo current again (an already inconsistent state) could
  later accept it.
- `ScenePresentationEffect.restartPreparation(ScenePresentationEffectRequest)` is a separate barrier
  command for an existing target. It allocates no planning tag, creates no navigation demand and has
  no planning completion. It may run while paused.
- Other effect and event payloads are unchanged, including renderer-ready/failed identities, retry
  attempt numbers, manual direction, load-more generations and generation/deadline wake-up pairs.

| Planning purpose | Reducer decision | Executor command |
|---|---|---|
| `nextAutomaticTarget` | The stable deadline needs a new automatic target. | Ask the facade to request the next scene, using redo, the prepared ring, or the existing single-photo path. A SmartFill miss refreshes preparation without synchronous fallback planning. |
| `replaceExhaustedTarget` | The automatic target exhausted retries. | Ask the facade for a new automatic target through the same navigation path. |

Purposes are commands, not hints for the executor to reinterpret from presentation phases or readiness.
Startup and ordinary pending targets already have their barrier, so `restartPreparation` is
idempotent; a restored grace target rebuilds the cancelled barrier before its download command runs.
The facade retains the existing autoplay admission guard and executes the effect array synchronously
in order. Prepared completion dispatch does not add a publication beyond the existing navigation
publications. No new task, actor hop or deferred dispatch is introduced by this protocol.

Prepared proposal delivery is independent of demand. Every fresh install, including lookahead begun
before demand existed, reads the facade's last executed automatic demand at delivery time. Freshness
is checked before installing the session-stamped ring, then prepared and lookahead image preloads run in their existing
order, and only then is a tagged completion sent. This lets the first eligible proposal satisfy waiting
demand without waiting for another refresh to install and stamp the same next scene. A rejected or
paused demand leaves the fresh proposal installed. Speculative delivery with no transported demand only
prepares the ring. If `pendingTransition != nil`, the facade drops the completion before it reaches the
reducer, retaining the installed proposal and the existing transition admission order.
Lookahead stays unstamped in planning storage until its source cursor matches the current prepared
cursor and freshness checks pass; the engine stamps/installs it and alone consumes it on navigation.
Planning code neither inspects presentation policy nor initiates navigation.

`ScenePresentationState.outstandingPlanningRequest` is private reducer state. The facade's
`pendingAutomaticScenePlanningRequest` transports the last executed automatic demand at delivery,
independently of proposal computation lifetime. User-paused commands do not replace this copy or the
reducer's outstanding request: if an automatic grace target exhausts retries while paused, a proposal
arriving after Play can still satisfy the original photo's demand before grace expires. Resume itself
only restores the wake-up; after grace expires, the original photo is no longer current or pending,
so its completion is rejected. Matching cancellation and `resetScenePresentationRuntime()` clear
it; transition acceptance does not. Engine reset/invalidation (including display-mode rebuild) resets
reducer demand but can leave the facade field stale; the reducer rejects that old request. A completion
dropped while user-paused is not buffered or reissued on resume: a consumed stable wake-up can leave
autoplay waiting indefinitely, a pre-existing pause/resume gap preserved by this refactor. Candidate
progression still advances at transition acceptance; reducer and retained history still advance at
the renderer visible tick. The executor, task storage, barrier and session owner remain in the facade.

## 4. Concurrency and state rules

- **Default isolation is `MainActor`.** The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are main-actor unless marked otherwise. View models, stores and `AssetsDownloadManager` run on the main actor. Pure logic that must run elsewhere is marked `nonisolated` and `Sendable` (the SmartFill planner and its types, protection snapshots, motion types, lifecycle contracts).
- **Planning runs detached.** SmartFill ring refresh and lookahead planning capture an immutable `SmartFillPreparedPlanRequest` on the main actor, then run `SmartFillPreparedPlanBuilder.makeResult` in `Task.detached(priority: .utility)`. The result is applied only if it is still fresh: request id, source cursor, asset pool identity and `playbackSourceGeneration` must all still match (`isPreparedSmartFillPlanResultFresh`). Otherwise it is dropped.
- **Generation guards.** Every async result carries the identity it was started for, and stale results are ignored instead of written back:
  - switching the playback source increments the loader's generation exactly once; the facade exposes `playbackSourceGeneration` as a read-only projection for the unchanged SmartFill seed and freshness checks, while the loader validates initial and refill identities before applying results
  - scene presentation targets carry a `ScenePresentationIdentity` (generation + scene id); effect tasks are stored per generation in `scenePresentationEffectTasks`
  - the reducer rejects stale wake-ups and `loadMore` requests
- **Load-more loading ownership.** `PlaybackPoolLoader` records a separate request ID whenever a random or filtered refill sets `isLoadingMore`. Only that request or a source reset clears the flag: the facade's operation-scoped defer asks the loader to finish on every exit (success, failure, stale result, cancellation), and a source reset clears both the flag and the owner ID. Success and current failures also retain their existing earlier loading publication. This cleanup ID does not participate in result validation: existing source-generation and session checks still decide which assets can be appended, and scene advances within the session remain valid.
- **Cancellation.**
  - Starting a new effect for a generation cancels the old task for it, and `.cancel` effects cancel explicitly.
  - Detached planning is wrapped in `withTaskCancellationHandler`, so cancelling the owning task also cancels the planner task. The builder checks `Task.isCancelled` between steps.
  - `Task.cancel` does not stop an SDWebImage request, so `AssetsDownloadManager` also keeps and cancels the `SDWebImageOperation`.
  - In `PlaybackPoolResolver`, cancellation errors are rethrown, never turned into an empty pool.
- **Settings ignore download activity.** `SettingsView` holds `AssetsDownloadManager.shared` as a plain reference instead of observing it. Observing it re-rendered every settings page on each download event while the slideshow kept loading behind Settings. In UI tests on the iOS 27 simulator, a `UISegmentedControl` switches its selection on touch-up but sends `.valueChanged` only after the next Core Animation commit, through the accessibility layer that UI automation loads; a SwiftUI update in between writes the old binding value back, so the tap reads as the old segment and is lost. Whether taps are also lost without automation or assistive technologies is not verified. On iOS the cache figures refresh from `activeTaskCountChanges` only while the cache page is on screen; on tvOS they refresh for as long as Settings is open, because the settings root entry reads the cache size.
- **One owner for on-screen state.** Only the reducer decides phases, fades and history. The view model executes effects and feeds results back as events. Views do not keep their own lifecycle timers.
- **Paused time does not count.** `SceneActiveTimeClock` excludes paused and background time. The reducer tracks pause and background as separate suspension reasons (`userPaused`, `background`), so resuming from one does not undo the other.
- **Actors.** `SoloVisionPoolFilter` is an `actor` with a bounded LRU cache of Vision results. It is cleared when the server changes.
- **Debug and diagnostics.** The playback sequence recorder, request lifecycle diagnostics and `UI_TEST_*` launch switches are debug-only. Production decisions must not depend on them. `scripts/check_release_guards.py` enforces this and keeps image cache and diagnostics code out of `PlaybackSessionEngine.swift`, `PlaybackSmartFillPlanner.swift` and their adjacent `<Primary>+*.swift` split files.
  `PlatformCompat` owns XCTest detection, long-person-name injection, screenshot connection prefill and the sequence recording switch. XCTest detection returns false in Release. Replay parsing, runtime evidence validation and playback readback injection are compiled only in Debug; their serialized keys stay unchanged.
  The EXIF sampling overlay, snapshots, benchmark entry points and playback debug panel declarations and callers are compiled only in Debug. `PlatformCompat` owns the `UI_TEST_SHOW_EXIF_SAMPLING_DEBUG` switch; normal EXIF tone analysis stays available in both configurations.

## 5. Glossary

Use these words, and the code names in backticks, instead of inventing new ones.

- **asset**: one Immich item (`Asset`) as returned by the API, with EXIF and people.
- **playback source**: what is being played, `PlaybackSource.random` or `.filtered(FilterSelection)`. The persisted default is `DefaultPlaybackMode`; the onboarding choice is `SlideMode`.
- **filter selection**: `FilterSelection`, the chosen album ids and `PersonFilter`s. It also has tag, rating and favorite fields that count toward `isEmpty`, but the pool resolver only uses albums and people.
- **rule**: one album or one person in a filter selection. The pool is the union across rules, with a per-rule request budget.
- **playback pool**: the ordered list of candidate `Asset`s privately owned by `PlaybackPoolLoader` and published through `SlideShowViewModel.assets`, filled by `ImmichAPIService.getRandomAsset` (random) or `PlaybackPoolResolver` (filtered).
- **load more**: appending more assets to the pool when the remaining candidates run low (`loadMoreAssets`, reducer event `.loadMoreNeeded`).
- **cooling pool**: the resolver's recently played list, used to avoid repeats across resolves.
- **candidate cursor**: the index in the pool where planning of the next scene starts.
- **solo-only person filter**: `PersonMatchMode.soloOnly`. A photo passes only if Immich lists one person and Vision finds exactly one face. `.normal` means the person appears. Album rules have no solo constraint.
- **display mode**: `PlaybackDisplayMode`, either `.smartFill` (default) or `.singlePhoto`. It is separate from the playback source.
- **single photo mode**: `PlaybackDisplayMode.singlePhoto`. Every scene has one slot, rendered by `SlideItemView`.
- **SmartFill**: the planner-driven display mode that fills the screen with a single, double or triple layout (`PlaybackSmartFillSceneType`), protecting faces and screen regions. If no layout is acceptable it returns `.fallback` with a `PlaybackSmartFillFallbackReason`.
- **scene**: one screen of playback (`PlaybackScene`), holding one or more slots. Scenes are what fade in and out, and what history records.
- **slot**: one photo position inside a scene (`PhotoSlot`; planner output `PlaybackSmartFillSlot` with role primary/secondary/tertiary and a crop rect in source coordinates).
- **surface**: the drawable playback area the planner lays out for (`PlaybackSmartFillSurface`).
- **readback**: `PlaybackSmartFillSceneReadback`, the planner decision stored on a scene (scene type, fallback category, QA summary). A scene with no readback uses the legacy single photo renderer.
- **protection snapshot**: `PlaybackProtectionSnapshot`, regions of the screen that must not cover important content, such as the system safe area, the top obstruction, the EXIF panel and the control bar, each with a `PlaybackProtectionPriority`. Planner input; a change invalidates prepared scenes.
- **face protection**: keeping detected faces (`FaceBox`, normalized via `FaceBoxGeometry`) fully inside a slot's crop.
- **prepared plan / prepared scene ring**: a SmartFill scene planned ahead of time off the main actor (`SmartFillPreparedPlanRequest` → `SmartFillPreparedPlanResult`), stored as previous/current/next in `PlaybackPreparedSceneRing` and invalidated by `PlaybackPreparedSceneFingerprint` changes.
- **lookahead**: planning one more scene beyond the prepared next scene so its images can load early.
- **prewarm**: in test names, loading the full-size images of prepared or lookahead slots before they are shown (`preloadSmartFillMotionPreparedSlotsIfNeeded`, `preloadSmartFillCandidateWindowIfNeeded`). This is a download, not a decode; the old decode prewarm path was removed and `check_release_guards.py` blocks its symbols.
- **preload window**: the assets around the current index kept loaded (`preloadCount`, `AssetsDownloadManager.preloadPhotos`).
- **playback session**: one run of `PlaybackSessionEngine` (`playbackSessionId`). It is invalidated when the source, filter, solo-only rule or server changes, or the pool is reloaded (`PlaybackSessionInvalidationReason`).
- **transition / navigation token**: a requested scene change (`PlaybackSessionTransition`) and the UUID that identifies it, used to discard late image results.
- **presentation**: the reducer's view of what is on screen (`ScenePresentationState`). Its phases (`ScenePresentationPhase`) are `empty`, `stablePhoto`, `grace`, `transition`, `loading`, `incomingFromLoading`, `paused` and `sourceError`. Layers have roles `stable`, `outgoing` and `incoming`.
- **fade**: the outgoing fade, incoming delay and incoming fade of a transition (`ScenePresentationPacingPolicy`, `SceneLifecycleContract`). Manual navigation uses a shorter pacing than automatic playback.
- **grace**: the current scene stays up while the next target is not ready. After an automatic deadline it lasts a limited time, then a loading transition is shown. After a manual Next or Previous it lasts until the target is ready (then the short manual crossfade) or cancelled; there is no loading gap. A settled photo keeps playing during it. When the press lands mid-transition, the photo the transition was heading to comes back to full opacity with the short manual fade if the user has already seen it, otherwise the photo that was fading out does; anything else still visible fades out behind it. A target that is ready before that photo is fully up cross fades only once it is (while playing).
- **interval**: the user's seconds per scene (`PlaybackSettings.intervalSeconds`). It is raised to a minimum (`PlaybackIntervalPolicy`) and frozen per scene (`SceneLifecycleContract.frozenInterval`).
- **target / readiness**: the scene the reducer is moving to (`ScenePresentationTarget`) and whether its images are `pending`, `ready` or `failed`.
- **prerender barrier**: the wait for every renderer of a hidden incoming scene to decode (`ScenePresentationPrerenderBarrier`, `SceneRendererIdentity`).
- **visible tick**: the display frame after a render transaction completes, reported by `SceneVisibleFrameReporter`. Only this counts as "seen".
- **history (reducer)**: the identities the reducer has seen become visible, in `ScenePresentationState.history`.
- **retained history**: `PlaybackHistoryLedger`, an in-memory list of seen scenes (capped by `PlaybackHistoryLedgerLimits.retainedEntryLimit`) with a cursor. Previous and redo move the cursor; next at the tail appends. It stores scene recipes, not images.
- **manual pending restore**: when the user presses Previous before a manually requested scene became visible, the reducer drops that target and continues the presentation it was holding (`cancelUnseenManualPendingPresentation`): the photo on screen carries on from where it is. A raised photo that the interrupted transition was heading to settles; a photo that was fading out stays up while the transition target decodes again, then the transition runs from it; when that target is automatic, as it usually is, a slow or failed decode falls back to the loading transition after its grace period, as for any automatic target, while a manual one is waited for.
- **suspension**: pausing the reducer for `userPaused` or `background`. Paused time is excluded by `SceneActiveTimeClock`. A user pause in the gap between an automatic fade-out and the delayed fade-in, when nothing is visible, fades the next photo in with the manual pacing and holds it still instead of freezing an empty frame; backgrounding still freezes it. Otherwise a pause freezes the frame where it is, except that a photo being raised for a manual hold finishes its short fade; going to the background ends that fade at once.
- **motion**: slow zoom and pan inside a scene. Allowed per scene by `MotionEligibilityPolicy`, shaped by `SceneAnimationProfile` and `SinglePhotoAnimationTunables`, and solved by `MotionTransformResolver` from a `MotionRuntimeContext`. Rendered motion stops at the end of the scene's longest visible window (`SlideShowViewModel.renderedMotionActiveTime`), which only matters while a photo is held for a manual target that is still loading.
- **Reduce Motion handling**: the system setting is forwarded to the view model (`updateSmartFillMotionReduceMotionEnabled`) and the reducer (`.reduceMotionChanged`). Scenes not yet seen start without motion. A scene already moving freezes on its last sample instead of jumping back, and stays frozen when the setting is turned off.
- **EXIF overlay**: the photo info panel (`ExifInfoView`, toggled by `PlaybackSettings.showExif`). Its text tone comes from `ExifForegroundAnalyzer`. It is kept for single and fallback scenes, not for double and triple layouts (`shouldPreserveExistingExifOverlay`).
- **debug overlay**: the playback diagnostics panel (`DebugOverlayView`, `showDebugOverlay`), available only in debug builds with the debug entry enabled (`PlatformCompat.isPlaybackDebugPanelEnabled`).
- **access protection**: optional PIN gate on settings (`AccessProtectionStore`, `AccessProtectionViewModel`, `PinEntrySheetView`). **recovery** is the state where the flag is on but the PIN is missing from the Keychain (`isRecoveryNeeded`).
- **onboarding session**: the first-boot → mode selection → filter summary sequence (`AppFlowStateMachine.isOnboardingSession`). Only it allows going back to mode selection.
- **live test**: a test that needs a real Immich server configured in `env.xcconfig`; it skips without one.
- **strict E2E**: UI flows run against a local public fixture server by `scripts/run_strict_e2e.py`.
- **evidence**: screenshot, capture and measurement tooling that does not pass or fail. It runs only in the `Evidence` test plans.

## 6. Testing and tooling

- Test rules, naming, test plans and the `Evidence` split: [docs/TESTING.md](TESTING.md).
- Commands for offline unit tests, script tests, localization and release checks: the Commands section of [AGENTS.md](../AGENTS.md).
- End-to-end runners and suites: [docs/TESTING.md](TESTING.md#running-controlled-integration-and-end-to-end-tests).
- Scripts:
  - `run_offline_unit_tests.py`: offline unit tests per platform
  - `run_strict_e2e.py`: strict E2E flows
  - `check_test_conventions.py`: test naming and structure lint
  - `check_release_guards.py`: debug-only code, test hooks and layer boundaries
  - `validate_localization_catalog.py`, `scan_chinese_strings.py`, `clean_stale_catalog_entries.py`: localization
  - `check_smartfill_visual_fallbacks.py`: flags visual fallbacks and SmartFill renderer changes in a diff
  - `install_git_privacy_hooks.sh`, `git_privacy_gate.py`: privacy gate

  All of these are in `scripts/`.
- Good starting tests for the playback core:
  - `ScenePresentationReducerTests`
  - `PlaybackSessionEngineTests`
  - `PlaybackSmartFillPlannerTests`
  - `PlaybackPoolResolverTests`
  - `SlideShowViewModelNavigationSemanticsTests`
  - `SlideShowViewModelStartupTests`
