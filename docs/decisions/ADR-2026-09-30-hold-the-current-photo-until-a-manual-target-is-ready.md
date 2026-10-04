# Hold the current photo until a manual target is ready

Status: accepted by the maintainer on 2026-09-30.

## Context

Every scene becomes visible only after its renderers have decoded behind a zero-opacity layer (the prerender barrier). A manual Next or Previous always creates a new target, so the target is never decoded when the button is pressed.

The reducer used to answer a pending manual target by removing every visible layer and entering `loading`, then fading the new scene in from the empty backdrop once it decoded. That kept the press responsive, but the user saw the dark backdrop for the decode time plus the start of the fade, about 0.2 to 0.6 seconds on the tvOS simulator, on every manual navigation, with or without autoplay. The repository treats a visible blank screen as a failure.

## Decision

A pending manual target puts the presentation in `grace`: what the user is looking at stays on screen while the target decodes behind it. When the target is ready, the usual short manual crossfade starts from that picture. There is no time limit and no extra indicator; a slow download keeps the current photo longer.

- A settled photo keeps playing during the hold: it moves while autoplay runs and stays still while paused, and that motion carries into the crossfade. Its rendered motion stops at the end of its longest visible window, so a very long hold cannot zoom it past the area planned to stay covered.
- A press in the middle of a transition, which may be dim or even black, raises a photo the user has already seen back to full opacity with the short manual fade and holds it: the photo the transition was heading to once it has been shown, otherwise the photo that was fading out. Anything else still visible fades out behind it with the same pacing, so the screen does not drop. A user pause during this short fade lets it finish, also after Previous kept the raised photo; going to the background ends it at once, so the app does not come back to a dim frame. While playing, a target that is ready before the raised photo is fully up starts its crossfade only once it is. Known gap: after a quick Next, Previous, Next and Previous during one raise, the last Previous can return to the frame kept at the second Next, a little dimmer or with the motion a fraction of a second back.
- Previous during the hold cancels the target and continues from what is on screen. A settled photo carries on with its own clocks and deadline. A raised photo that the interrupted transition was heading to settles. A raised photo that was fading out stays up while the transition target decodes again, then the transition runs from it. When that target is automatic, as it usually is, a slow or failed decode falls back to the loading transition after its grace period, as for any automatic target; a manual one is waited for.
- A pause that arrives during the hold still lets the target cross fade in once ready, then holds it still, as for manual navigation while paused.

A related fix in the same change: a user pause that lands in the 25 ms gap between the automatic fade-out and the delayed fade-in no longer freezes an empty frame. The next photo fades in with the manual pacing and is held still until Play.

## Consequences

- The screen never drops to the loading backdrop on Next or Previous while a photo is showing or has just faded out. When nothing has been shown yet (for example before the first scene), `loading` remains, and it no longer keeps layers or wake-ups of the targets it replaces.
- A press during the dim middle of an automatic transition raises a photo from that dim frame, so the screen stays below half a photo until it is about half raised. While playing, a target that decodes before the raised photo is fully up starts its crossfade only once it is. While paused, the crossfade starts at once from the partly raised photo, which can add up to about 60 ms below half a photo; waiting there as well needs a wake-up that runs while paused, left for a separate decision.
- The crossfade can start a fraction of a second after the press, while the target decodes. Decoding the next scene ahead of time would remove that delay; it was left for a separate decision.
- The scene contract UI test rejects any loading or incoming-only sample after Next, requires the same old photo (checked by hashed layer identity, `layerIDs` in the contract probe) to stay on screen until the crossfade, and fails if any drawn frame after Next shows less than half a photo (`lowCoverageFrameCount`). The probe also records the last crossfade frame by frame (`crossfadeFrameCount`, `lastCrossfade`), so a crossfade shorter than the sampling interval is still checked: both photos must show together in at least one frame, counting the incoming photo drawn on top (a hard switch or an opaque cut fails), and the old photo's motion must stay still while paused, or keep moving from where it was held without going backwards while playing.
