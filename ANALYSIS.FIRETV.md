# Firebat APK Ad System Analysis & Patch Documentation

## Overview

Amazon Fire TV does not use a standalone Prime Video APK for video playback. Instead, `com.amazon.firebat` is the system-level video playback engine that handles all Prime Video content, including ad insertion. This document details the internal ad architecture of firebat and explains the surgical patch applied to disable ad playback.

## APK Structure

The firebat APK contains 6 DEX files. The ad system spans primarily across `classes3.dex` (core ad logic) and `classes5.dex` (SDK-level UI), with ExoPlayer/Media3 ad infrastructure in `classes.dex`.

Key package namespaces:

| Package | Role |
|---------|------|
| `com.amazon.avod.ads.*` | Ad data fetching, VAST/VMAP parsing, config |
| `com.amazon.avod.media.ads.internal.*` | Core ad playback state machine and player wrapper |
| `com.amazon.avod.playbackclient.ads.*` | Ad UI controllers (skip button, countdown, scrub tooltip) |
| `com.amazon.avod.playback.player.*` | Core video playback engine and state machine |
| `com.amazon.avod.playback.session.*` | Session management, workflow tasks |
| `com.amazon.avod.fsm.*` | Generic finite state machine framework |
| `androidx.media3.exoplayer.source.ads.*` | ExoPlayer's ad source infrastructure |

## Ad System Architecture

The ad system is built in 4 layers, each depending on the one below it:

```
┌─────────────────────────────────────────────────────────┐
│  Layer 4: Ad UI / Controllers                           │
│  AdPlaybackFeature, AdSkipController, AdScrubTooltip,   │
│  countdown timers, "Go Ad Free" prompts                 │
├─────────────────────────────────────────────────────────┤
│  Layer 3: Ad Playback State Machine (FSM)               │
│  AdEnabledPlaybackStateMachine, AdBreakState,           │
│  AdClipState, PrimaryContentState, MonitoringState      │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Ad Data / Planning                            │
│  AdPlan, AdBreak, AdBreakSelector, PrepareAdPlan,       │
│  VMAP/VAST parsers, ad HTTP clients                     │
├─────────────────────────────────────────────────────────┤
│  Layer 1: Video Playback Engine                         │
│  AmazonVideoPlayer, ExoPlayer/Media3,                   │
│  PlaybackStateMachine, PlaybackSession                  │
└─────────────────────────────────────────────────────────┘
```

## Ad Network Architecture

### Ad Data Fetching Pipeline

The ad plan is fetched as part of the playback session startup:

```
PrepareAdPlan.execute()
    │
    ▼
getPlaybackResources()  ──►  URL Vending Service (single API call)
    │                        Returns: ManifestUrl, CuepointPlaylist,
    │                        AdInsertion type, DRM tokens, subtitles
    ▼
getCuepointPlaylist()   ──►  Extracts ad break positions from the
    │                        same PlaybackResources response
    ▼
AdPlanFactory.newAdPlan()  ──►  Builds AdPlan/AdBreak/AdClip objects
    │                           from CuepointPlaylist + VMAP/VAST data
    ▼
captureAndUploadAdManifest()  ──►  ManifestCapturer.uploadAdManifest()
```

### HTTP Clients

| Client | Purpose |
|--------|---------|
| `AdHttpClient` | VAST beacon sending (`sendVastBeacon`), audit pings (`processAuditPingHttpRequest`) |
| `BoltHttpAdClient` | Fetches VAST/VMAP XML documents (`AdDocument.retrieveAdDocument`) |
| `AdTEVSClient` | Timed Event Vending Service calls (live ad event metadata) |
| `DefaultAdHttpClient` | Default implementation of `AdHttpClient` |
| `RegolithServiceAccessor` | Fetches pause ads from Regolith API (separate from video ads) |

### Ad Insertion Modes

The `AdInsertion` enum (`com.amazon.urlvending.types.AdInsertion`) defines 4 modes:

| Value | Description |
|-------|-------------|
| `BURNED_IN` | Ads burned into the stream at transcode time (cannot be removed) |
| `NONE` | No ad insertion |
| `SSAI` | Server-Side Ad Insertion (ads stitched into manifest as separate periods) |
| `DYNAMIC` | Dynamic/client-side ad insertion |

Fire TV primarily uses **SSAI** — ads are separate periods in the DASH/HLS manifest, each tagged with a `ContentType` property.

### SSAI Manifest Structure

For SSAI streams, the DASH manifest contains multi-period content where each period is tagged:

| ContentType | Meaning |
|-------------|---------|
| `"MAIN"` | Feature content |
| `"AD"` at position 0 | Pre-roll advertisement |
| `"AD"` at position > 0 | Mid-roll advertisement |
| `"AUX"` | Auxiliary content (bumpers, interstitials) |
| `"AdTransition"` | Transition period between ad and content |

These are parsed by `ContentType.fromPropertyString(String, long)` in `com.amazon.avod.content.smoothstream.manifest.ContentType`.

The `ServerInsertedManifestTimelineManager` builds `TreeRangeMap` vectors from the `AdPlan` to translate positions between ad-inclusive and ad-exclusive timelines. This allows the seekbar to show content-only positions while the underlying player uses absolute manifest positions.

### Beacon/Tracking Domains

| Domain | Purpose |
|--------|---------|
| `*.aiv-delivery.net` | Media event reporting, TERS event reporting, SYE ad pixels |
| `aax*.amazon-adsystem.com` | Amazon Ad Exchange click/impression tracking |

Beacon URL templates use placeholders: `[EVENTTYPE]`, `[ATTIME]`, `[ERRORCODE]`, `[BID_CACHE_PLACEHOLDER]`, `[IMPRESSION_PLACEHOLDER]`.

### Live SSAI Signaling

For live content, ad break boundaries are signaled via **EMSG (Event Message) boxes** embedded in MP4 fragments. These are parsed by a native JNI library (`Mp4FragmentJni.getEventMessages`) and dispatched to `EventMessageListener` implementations.

### Pause Ads (Separate Pipeline)

Pause ads are completely independent from video ads:

```
User pauses video
    │
    ▼
PauseAdsDataFetcher.fetchPauseAds()
    │
    ▼
RegolithServiceAccessor.fetchPauseAdsResponse(regolithUrl)
    │
    ▼
RegolithResponseParser → PauseAds / PauseAdsTemplate
    │
    ▼
PauseAdsImageViewPresenter renders the ad image overlay
```

The Regolith service URL is dynamic (from server config), not hardcoded.

## Why Network-Level Blocking Doesn't Work

### DNS/Host Blocking (Pi-hole style)

Blocking beacon domains (`*.aiv-delivery.net`, `aax*.amazon-adsystem.com`) only stops **ad tracking**, not ad playback. The ads still play — they just go unreported. For SSAI content, ad video segments are served from the **same CDN** (CloudFront/Akamai) as the main content. Blocking the CDN blocks the entire stream.

### Blocking the Ad Plan Fetch

The ad break positions (`CuepointPlaylist`) are bundled inside the `PlaybackResources` response — the **same API call** that returns the content manifest URL, DRM tokens, and subtitle URLs. You cannot selectively block cuepoint data without also breaking content playback.

### MITM Proxy

A MITM proxy could theoretically intercept and modify PlaybackResources responses, strip CuepointPlaylist fields, or rewrite DASH manifests to remove AD periods. However:

- Amazon uses **certificate pinning** — the app won't trust a custom CA without patching the APK
- Fire TV's network stack makes proxy configuration difficult without root
- SSAI manifests change dynamically for live content
- If you're already patching the APK for cert pinning bypass, the `AdBreakSelector` patch is simpler

### What Network Blocking Can Do

| Target | Effect |
|--------|--------|
| Block beacon domains | Stops ad impression/tracking reporting. Ads still play. |
| Block Regolith API | Stops pause ads only. Video ads unaffected. |
| Block CDN domains | Breaks all video playback (content + ads). |
| Block URL Vending API | Breaks all video playback. |

## FSM Framework

Amazon built a custom hierarchical finite state machine framework in `com.amazon.avod.fsm`. Understanding this is critical to understanding ad flow.

### Core Classes

**`State<S, T>`** — Interface with `enter(Trigger)`, `exit(Trigger)`, and `getType()`.

**`StateBase`** — Abstract base. Its `doTrigger(Trigger)` method delegates up to the owning `BlockingStateMachine`, which looks up the transition table and executes the state change.

**`Trigger<T>`** — Interface with `getType()`. Implementations carry payload data (e.g., `AdBreakTrigger` carries the `AdBreak` object and seek positions).

**`TransitionTable`** — A `HashMap` keyed by `(fromState, triggerType)` pairs, mapping to `Transition` objects that define the destination state.

**`BlockingStateMachine`** — Thread-safe FSM engine. `doTrigger()` acquires a lock on `AtomicStateTransitioner`, looks up the transition, calls `exit()` on the current state, then `enter()` on the new state. If no transition is registered for the current state + trigger combination, the trigger is silently ignored.

**`StateMachineBase`** — Supports hierarchical states (parent-child). Transition lookup walks up the ancestor chain, so a trigger registered on a parent state applies to all children.

### State Registration

States and transitions are registered in `ServerInsertedAdEnabledPlaybackStateMachine.initialize()` (~1068 lines of smali) using a builder pattern:

```java
setupState(adBreakState, activeState)      // adBreakState is child of activeState
    .registerTransition(PLAY_AD, playingAdState)
    .registerTransition(NO_MORE_ADS, transitionState)
    .registerTransition(NO_MORE_ADS_SKIP_TRANSITION, monitoringState)
    .registerTransition(NEXT_AD_CLIP_SERVER_INSERTED, playingAdState)
    .registerTransition(AD_CLIP_ERROR, transitionState);
```

## Ad Playback State Machine

### Class Hierarchy

```
StateMachineBase (abstract, generic FSM framework)
  └─ BlockingStateMachine (thread-safe, transition table lookup)
      └─ AdPlaybackStateMachine (abstract, implements VideoPresentationEventListener + AdEnabledPlaybackManager)
          └─ AdEnabledPlaybackStateMachine (abstract, adds threading, config, volume management)
              └─ ServerInsertedAdEnabledPlaybackStateMachine (concrete, the one actually used on Fire TV)
```

### State Types (AdEnabledPlayerStateType enum)

| Ordinal | State | Purpose |
|---------|-------|---------|
| 0 | `ACTIVE` | Top-level parent state |
| 1 | `CHECK_PREROLL` | Decides whether to play pre-roll ads |
| 2 | `PREPARING_AD` | Loading an ad creative |
| 3 | `PREPARED_SEEKING` | Ad ready, seeking to position |
| 4 | `PLAYING_AD` | Actively playing an ad clip |
| 5 | `PAUSE` | Paused during ad playback |
| 6 | `AD_BREAK` | In an ad break (contains multiple clips) |
| 7 | `AD_CLIP` | Playing a single ad within a break |
| 8 | `WAITING_FOR_AD_PLAN` | Waiting for ad manifest from server |
| 9 | `AD_PLAN_READY` | Ad plan received |
| 10 | `MONITORING_FOR_AD_BREAK` | Watching content timeline for next ad cue |
| 11 | `POST_PRIMARY_STATE` | After main content ended |
| 12 | `CLIP_ERROR_STATE` | Error during ad clip |
| 13 | `TRANSITION_STATE` | Playing transition animation between ad and content |
| 14 | `WAITING_FOR_PRIMARY_PLAYER` | Waiting for primary player readiness |

### Trigger Types (AdEnabledPlayerTriggerType enum)

| Ordinal | Trigger | Purpose |
|---------|---------|---------|
| 0 | `WAIT_FOR_PREPARE` | Wait for media preparation |
| 1 | `PRIMARY_CONTENT_PREPARED` | Content is ready |
| 2 | `AD_PREPARED` | Ad clip finished loading |
| 3 | `BEGIN_AD_BREAK` | Initiate an ad break |
| 4 | `PLAY_PRE_ROLLS` | Play pre-roll ads |
| 5 | `PLAY_AD` | Play an individual ad |
| 6 | `NO_MORE_ADS` | All ads in break exhausted |
| 7 | `NO_MORE_ADS_SKIP_TRANSITION` | Ads done, skip transition animation |
| 8 | `SKIP_CURRENT_AD_CLIP` | Skip the current ad |
| 9 | `AD_PLAN_READY` | Ad plan is available |
| 10 | `AD_PLAN_ERROR` | Error fetching ad plan |
| 11 | `MONITOR_PRIMARY_CONTENT` | Resume monitoring content |
| 12 | `AD_CLIP_ERROR` | Error during ad clip |
| 13 | `NEXT_AD_CLIP_SERVER_INSERTED` | Advance to next server-inserted ad clip |

### Trigger Sources (TriggerSource enum)

| Value | Meaning |
|-------|---------|
| `CHAPTERING_DUE_TO_SEEK` | User seek crossed an ad break boundary |
| `NATURAL_TRANSITION` | Playback naturally reached the break point |
| `UNKNOWN` | Default |

## Complete Ad Playback Flow

### Phase 1: Ad Plan Loading

```
Session starts
    │
    ▼
PrepareAdPlan (workflow task)
    │ Fetches VMAP manifest from Amazon ad servers
    │ Parses VAST/VMAP into AdPlan with list of AdBreaks
    │ Each AdBreak has: startTime, adClips[], adPositionType (PRE_ROLL/MID_ROLL/POST_ROLL)
    │
    ▼
updateAdPlan(AdPlan) called on ServerInsertedAdEnabledPlaybackStateMachine
    │ Stores plan in AdEnabledPlaybackSharedContext
    │ Fires AD_PLAN_READY trigger
    │
    ▼
FSM transitions to AD_PLAN_READY state
```

### Phase 2: Pre-roll Check

```
AD_PLAN_READY state
    │
    ▼
CHECK_PREROLL state (ServerInsertedAdCheckPrerollState)
    │
    ├─ Calls AdBreakSelector.selectNextBreak(plan, videoStartTime)
    │   └─ Scans AdPlan breaks for one matching the start position
    │
    ├─ Calls PrerollStatus.getPrerollStatus(startTime, adBreak, context)
    │
    ├─ Always fires PLAY trigger (starts content playback pipeline)
    │
    └─ If prerollStatus.isAvailableForPlayback():
        │ Creates AdBreakTrigger(adBreak, null, null)
        │ Fires BEGIN_AD_BREAK trigger
        │ FSM transitions to AD_BREAK → AD_CLIP → plays preroll ads
        │
        └─ If not available: falls through to monitoring
```

### Phase 3: Content Monitoring

```
MONITORING_FOR_AD_BREAK state (ServerInsertedMonitoringPrimaryState)
    │
    ├─ Gets current playback position
    │
    ├─ Calls AdBreakSelector.selectNextBreak(plan, currentPosition)     ◄── PATCH TARGET
    │   └─ Returns the next unplayed break ahead of current position
    │
    ├─ If null, or PRE_ROLL, or already scheduled: just init live tracking and return
    │
    └─ If valid mid-roll break found:
        ├─ Creates TimelineMonitoringTask (inner class $1)
        │   └─ Fires BEGIN_AD_BREAK when playback reaches break's start time
        ├─ Marks break as scheduled: adBreak.adBreakScheduled()
        └─ Schedules task: timelineMonitor.scheduleTask(player, task)
```

### Phase 4: Ad Break Playback

```
BEGIN_AD_BREAK trigger fires (from monitoring task or seek detection)
    │
    ▼
AD_BREAK state (ServerInsertedAdBreakState / AdBreakState)
    │ Finds first unplayed clip in break
    │ Fires NEXT_AD_CLIP_SERVER_INSERTED trigger
    │
    ▼
AD_CLIP state (AdClipState) ─── 2667 lines of smali
    │
    ├─ enter(): Sets up ad clip playback
    │   ├─ Calculates clip end position (startTime + duration)
    │   ├─ Creates TimelineMonitoringTask for clip end
    │   ├─ Registers event bus handlers
    │   ├─ Manages volume (mute/scale)
    │   ├─ Reports AdClipBegin metric
    │   └─ Posts AdStartEvent
    │
    ├─ During playback: handles pause/resume events, IVA (interactive) ads
    │
    ├─ When clip ends: fires NEXT_AD_CLIP_SERVER_INSERTED for next clip
    │   └─ If no more clips: fires NO_MORE_ADS or NO_MORE_ADS_SKIP_TRANSITION
    │
    └─ exit(): Marks clip as played, sends VAST tracking beacons, cleanup
        │
        ▼
    TRANSITION_STATE (plays transition animation)
        │
        ▼
    Back to MONITORING_FOR_AD_BREAK (resume content, watch for next break)
```

### Phase 5: Seek-Over-Ad Detection

When the user seeks during content playback, the seek goes through the FSM:

```
User seeks from position A to position B
    │
    ▼
ServerInsertedAdEnabledPlaybackStateMachine.seekTo(TimeSpan)
    │ Creates SeekTrigger(position, RELATIVE)
    │ Calls doTrigger(seekTrigger)
    │
    ▼
ServerInsertedMonitoringPrimaryState handles SEEK
    │
    ├─ Calls AdBreakSelector.selectPriorBreakIfUnPlayed(plan, seekTarget, seekFrom)  ◄── PATCH TARGET
    │   ├─ getPriorBreakIfUnPlayed(plan, seekTarget) → break before destination
    │   ├─ getPriorBreakIfUnPlayed(plan, seekFrom) → break before origin
    │   └─ If different breaks: user seeked past an unplayed break → return it
    │
    └─ If unplayed break found between A and B:
        Creates AdBreakTrigger(break, seekTarget, seekFrom, CHAPTERING_DUE_TO_SEEK)
        Forces user to watch the skipped ad break before continuing
```

## The Chokepoint: AdBreakSelector

`AdBreakSelector` (`com.amazon.avod.media.ads.internal.AdBreakSelector`) is a single class with 4 methods that serve as the **sole decision point** for all ad break selection in the entire playback pipeline:

### Method 1: `selectNextBreak(AdPlan, TimeSpan)`

**Called by:**
- `ServerInsertedAdCheckPrerollState.enter()` — to find pre-roll ads at video start
- `ServerInsertedMonitoringPrimaryState.enter()` — to find the next mid-roll ad ahead of current position

**Logic:**
1. Iterates all breaks in the AdPlan
2. Skips breaks where `isPlayed() == true`
3. For non-Draper breaks: checks if `|break.startTime - currentTime| <= selectionTimeSpan` (tolerance window)
4. For Draper breaks or those outside tolerance: checks if `break.startTime >= currentTime`
5. Returns the first matching break, or `null` if none found

**If this returns `null`:** No pre-roll or mid-roll ad will ever be triggered. The CHECK_PREROLL state skips ad playback, and the MONITORING state doesn't schedule any timeline tasks.

### Method 2: `selectPriorBreakIfUnPlayed(AdPlan, TimeSpan seekTarget, TimeSpan seekFrom)`

**Called by:** Seek handling logic in the monitoring/content states.

**Logic:**
1. Finds the break just before the seek destination (`getPriorBreakIfUnPlayed(plan, seekTarget)`)
2. Finds the break just before the seek origin (`getPriorBreakIfUnPlayed(plan, seekFrom)`)
3. If they're different breaks, it means the user seeked past an unplayed break → returns it for forced playback
4. Special cases for Draper/WatchFromBeginning and aux clips

**If this returns `null`:** Seeking past an ad break position will never force the user to watch ads. The seek completes normally.

### Method 3: `getPriorBreakIfUnPlayed(AdPlan, TimeSpan)`

**Supporting method** for `selectPriorBreakIfUnPlayed`. Iterates breaks in reverse to find the first unplayed break whose `relativeStartTime <= targetTime`.

### Method 4: `getPriorBreakIfUnPlayedExcludingAux(AdPlan, TimeSpan)` (static)

**Supporting method**, same as above but uses `getRelativeStartTimeExcludingAux()` for position comparison. Used in aux-clip-aware seek handling within `AdClipState.enter()`.

## The Patch

All 4 methods in `AdBreakSelector` are patched to immediately return `null`:

```smali
.method public final selectNextBreak(...)Lcom/amazon/avod/media/ads/AdBreak;
    .locals 0
    const/4 p1, 0x0
    return-object p1
.end method
```

This is applied identically to all 4 methods, changing only the register name (`p0` for static, `p1` for instance methods) to match the method signature.

### Why This Works

The patch exploits the fact that the entire ad playback system funnels through a single decision class:

```
                    ┌──────────────────┐
                    │  AdBreakSelector  │
                    │                  │
  Pre-roll check ──►│ selectNextBreak()│──► null ──► No pre-roll
                    │                  │
  Mid-roll monitor─►│ selectNextBreak()│──► null ──► No mid-roll
                    │                  │
  Seek detection ──►│ selectPrior...() │──► null ──► No forced ad on seek
                    │                  │
                    └──────────────────┘
```

**Pre-rolls disabled:** `ServerInsertedAdCheckPrerollState.enter()` calls `selectNextBreak(plan, startTime)`. When it gets `null`, `PrerollStatus.getPrerollStatus()` receives a null break and returns a non-playable status. The `PLAY` trigger fires (starting content), but no `BEGIN_AD_BREAK` trigger is ever created.

**Mid-rolls disabled:** `ServerInsertedMonitoringPrimaryState.enter()` calls `selectNextBreak(plan, currentPosition)`. The null return hits the `if-eqz v1, :cond_3` check at line 107, jumping directly to `LiveAdTrackingManager.init()` and returning. No `TimelineMonitoringTask` is ever scheduled, so no ad break will ever fire during content playback.

**Seek-over-ads disabled:** Any seek operation that would normally detect an unplayed ad break between the origin and destination now gets `null` from `selectPriorBreakIfUnPlayed()`. No `AdBreakTrigger` with `CHAPTERING_DUE_TO_SEEK` source is created, so the seek completes without interruption.

### Patch Control Flow

The following diagrams show exactly how the patch affects each ad scenario. The left side shows the **original flow** and the right side shows the **patched flow**.

#### Pre-roll Ads

```
ORIGINAL:                                      PATCHED:

Session starts                                  Session starts
    │                                               │
    ▼                                               ▼
updateAdPlan(plan)                              updateAdPlan(plan)
    │                                               │
    ▼                                               ▼
AD_PLAN_READY trigger                           AD_PLAN_READY trigger
    │                                               │
    ▼                                               ▼
CheckPrerollState.enter()                       CheckPrerollState.enter()
    │                                               │
    ▼                                               ▼
selectNextBreak(plan, startTime)                selectNextBreak(plan, startTime)
    │                                               │
    ▼                                               ▼
Returns AdBreak (preroll at t=0)                Returns null ◄── PATCHED
    │                                               │
    ▼                                               ▼
PrerollStatus → isAvailableForPlayback()=true   PrerollStatus → null break → not available
    │                                               │
    ├─ fires PLAY trigger                           ├─ fires PLAY trigger
    ├─ fires BEGIN_AD_BREAK trigger                 └─ no BEGIN_AD_BREAK ──► content starts
    ▼                                                  immediately
AD_BREAK → AD_CLIP → plays 30s ad
    │
    ▼
NO_MORE_ADS → TRANSITION → content starts
```

#### Mid-roll Ads

```
ORIGINAL:                                      PATCHED:

Content playing at position t                   Content playing at position t
    │                                               │
    ▼                                               ▼
MonitoringPrimaryState.enter()                  MonitoringPrimaryState.enter()
    │                                               │
    ▼                                               ▼
selectNextBreak(plan, t)                        selectNextBreak(plan, t)
    │                                               │
    ▼                                               ▼
Returns AdBreak at t=900s                       Returns null ◄── PATCHED
    │                                               │
    ▼                                               ▼
Schedules TimelineMonitoringTask                if-eqz null → :cond_3
    │                                               │
    ▼                                               ▼
Player reaches t=900s                           LiveAdTrackingManager.init()
    │                                               │
    ▼                                               ▼
Task fires BEGIN_AD_BREAK                       return (no task scheduled)
    │                                               │
    ▼                                               ▼
AD_BREAK → AD_CLIP → plays ads                 Content plays uninterrupted
    │                                               through t=900s and beyond
    ▼
NO_MORE_ADS → back to monitoring
```

#### Seek Over Ad Break

```
ORIGINAL:                                      PATCHED:

User seeks from t=300s to t=1200s               User seeks from t=300s to t=1200s
(ad break exists at t=900s)                     (ad break exists at t=900s)
    │                                               │
    ▼                                               ▼
seekTo(1200s) → SeekTrigger                     seekTo(1200s) → SeekTrigger
    │                                               │
    ▼                                               ▼
selectPriorBreakIfUnPlayed(                     selectPriorBreakIfUnPlayed(
  plan, seekTarget=1200, seekFrom=300)            plan, seekTarget=1200, seekFrom=300)
    │                                               │
    ▼                                               ▼
getPriorBreak(plan, 1200) → break@900           Returns null ◄── PATCHED
getPriorBreak(plan, 300)  → null                    │
IDs differ → return break@900                       ▼
    │                                           Seek completes to t=1200s
    ▼                                           No interruption
AdBreakTrigger(break@900,
  source=CHAPTERING_DUE_TO_SEEK)
    │
    ▼
Forced to watch ad break at t=900s
    │
    ▼
After ads, resumes seek to t=1200s
```

### Why This Approach Over Alternatives

#### Detailed Comparison

| Approach | Preroll | Midroll | Seek-Forced | No Ad Traffic | Difficulty | Breakage Risk |
|----------|:-------:|:-------:|:-----------:|:-------------:|:----------:|:-------------:|
| **AdBreakSelector patch** | **Yes** | **Yes** | **Yes** | No | **Low** | **Very low** |
| DNS/host blocking | No | No | No | Beacons only | Low | None |
| MITM proxy | Maybe | Maybe | Maybe | Yes | Very high | High |
| Block ad plan API | — | — | — | Yes | Low | **Breaks all playback** |
| Patch `AdPlaybackFeature` | No | No | No | No | Medium | Low |
| Patch `AdClipState.enter()` | No | No | No | No | Medium | High (stuck state) |
| Patch `PrepareAdPlan` | Yes | Yes | Yes | Yes | Low | High (NPE risk) |
| Patch `hasPlayableAds()` | No | No | No | No | Low | Low |
| Patch `AdsConfig` flags | Partial | Partial | No | No | High | Medium |
| Patch `ContentType` parser | No* | No* | Yes | No | Low | Low |
| Force `AdInsertion.NONE` | Yes | Yes | Yes | Yes | Medium | Medium |
| Return `EmptyAdPlan` | Yes | Yes | Yes | Partial | Medium | Medium |
| Patch monitoring state only | No | Yes | No | No | Low | Low |

*\* ContentType patch: ads still play as video content, just without ad UI/controls*

#### Why AdBreakSelector Wins

| Property | Detail |
|----------|--------|
| **Surface area** | 4 methods in 1 class — minimal change |
| **Side effects** | None — `null` is an expected return (the no-ads code path) |
| **State corruption** | Impossible — FSM never enters ad states, no cleanup needed |
| **Coverage** | Pre-rolls + mid-rolls + seek-forced ads |
| **Ad insertion modes** | Both CSAI and SSAI use the same selector |
| **Crash risk** | Zero — every caller already handles `null` returns |

### Known Limitation: Pause Ads

The patch does **not** block pause ads. These use a completely separate pipeline (`PauseAdsDataFetcher` → Regolith API) that doesn't go through `AdBreakSelector`. Pause ads are image overlays shown when the user pauses, not video ad breaks.

### SSAI Behavior Note

For SSAI streams, ad segments are baked into the manifest by the server. With the patch applied, the player won't enter ad break states, show ad UI, or block seeking. However, the ad segments are still present in the stream. The player will seamlessly skip over them during normal playback since no `TimelineMonitoringTask` fires to halt content and enter the ad state. The seekbar will not show ad markers and the user can seek freely.

## Server-Side vs Client-Side Ads

Firebat supports both ad insertion modes:

- **CSAI (Client-Side Ad Insertion):** Separate ad video files stitched in by the client. Uses `AdEnabledPlaybackStateMachine`.
- **SSAI (Server-Side Ad Insertion):** Ads baked into the manifest/stream by the server. Uses `ServerInsertedAdEnabledPlaybackStateMachine` (extends the CSAI one) with additional classes like `ServerInsertedAdBreakState`, `ServerInsertedSeekState`, `ServerInsertedMonitoringPrimaryState`.

Both paths use `AdBreakSelector` to decide when to trigger ad breaks. The patch covers both.

## Installation Guide

### Root Is Required

Firebat (`com.amazon.firebat`) is a **privileged system app** installed in `/system/priv-app/`. Android enforces strict signature verification for system apps — you can only update one with an APK signed by the **same key**. Since the patched APK is signed with a self-generated key (not Amazon's platform key), standard installation methods fail:

- `adb install -r firebat_patched_signed.apk` → `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (signature mismatch)
- `adb install -r -d firebat_patched_signed.apk` → same error (downgrade flag doesn't bypass signature check)
- `pm uninstall --user 0` then `adb install` → package manager still tracks original signature; install still rejected

**Without root, there is no reliable way to replace a system app with a differently-signed APK.** The device must be rooted first.

### Why ADB-Only (Non-Root) Won't Work

| Attempt | Result |
|---------|--------|
| `adb install -r firebat_patched_signed.apk` | `INSTALL_FAILED_UPDATE_INCOMPATIBLE` — signature mismatch |
| `adb install -r -d firebat_patched_signed.apk` | Same error — `-d` only bypasses version downgrade, not signature |
| `pm uninstall --user 0 com.amazon.firebat` then install | Package manager retains original signature in its database; new signature still rejected |
| `pm uninstall com.amazon.firebat` (full) | Requires root for system apps; fails without it |
| Push to `/system/priv-app/` via `adb push` | `/system` is read-only; remounting requires root |

### Identifying Your Fire TV Model

Before rooting, identify your exact device:

```bash
adb shell "echo model=$(getprop ro.product.model); echo device=$(getprop ro.product.device); echo android=$(getprop ro.build.version.release); echo build=$(getprop ro.build.display.id)"
```

**Fire TV Cube models:**

| Model Code | Generation | SoC | Android | Codename |
|------------|-----------|-----|---------|----------|
| `AFTA` | Fire TV Cube 1st Gen (2018) | Amlogic S905Z | 7.1 | — |
| `AFTKA` / `AFTR` | Fire TV Cube 2nd Gen (2019) | Amlogic S922X (S922Z) | 9 | raven |
| `AFTGAZL` | Fire TV Cube 3rd Gen (2022) | Amlogic S905X4-K | 11 | gazelle |

### Root Methods for Fire TV Cube 2nd Gen (Raven)

All known root methods for the raven platform exploit vulnerabilities that Amazon has progressively patched in firmware updates. The exploits, their maximum supported firmware, and status:

| Method | Max Firmware | Exploit | Access Level |
|--------|-------------|---------|-------------|
| [Bootloader unlock (DFU)](https://xdaforums.com/t/4445971/) | ≤ PS7242/3516 | Amlogic bootrom USB DFU bug | Full root + TWRP + Magisk |
| [Bootloader unlock (no DFU)](https://xdaforums.com/t/4445971/) | ≤ PS7292/2984 | Amlogic bootrom variant | Full root + TWRP + Magisk |
| [Temp root (CVE-2022-38181)](https://xdaforums.com/t/4573691/) | ≤ PS7624/3337 | ARM Mali GPU driver | Temporary root shell + bootless Magisk |
| [Temp root (CVE-2022-46395)](https://xdaforums.com/t/4596735/) | ≤ PS7646 | ARM Mali GPU driver | Temporary root shell |
| [System User](https://xdaforums.com/t/4759215/) | ≤ PS7704/5024 | Undisclosed | System user (not full root — no `su`, but can enable/disable apps, block OTA) |

**Important:** The System User method is **not full root**. It cannot install patched system APKs, remount `/system`, or run `su`. It can disable apps and block OTA updates.

### Current Device Status

**Device:** Fire TV Cube 2nd Gen (AFTR / raven)
**Firmware:** FireOS 7.7.1.1 (PS7711/5272) — released 2026-01-05

**All known exploits are patched on this firmware.** The System User method was patched in PS7706 (October 2025). PS7711 is newer.

### Possible Paths Forward

1. **Firmware downgrade** — If possible, downgrade to PS7704 or earlier to use the System User method. However:
   - Amazon typically blocks firmware downgrades on Fire TV
   - The DFU-based downgrade method requires firmware ≤ PS7242 to enter DFU mode in the first place
   - Hardware-level downgrade (eMMC reflash) requires opening the device and shorting eMMC pins to enter Amlogic burn mode

2. **Hardware exploit (eMMC short)** — The Amlogic S922X has a bootrom DFU vulnerability that is unpatchable (it's in the chip's ROM). Accessing it on newer firmware requires physically opening the device and shorting specific eMMC data pins to prevent the eMMC from loading, forcing the SoC into USB burn mode. From there, the [raven-root](https://github.com/Pro-me3us/raven-root) bootrom exploit can bypass secure boot. This gives full root + bootloader unlock + TWRP + Magisk.

3. **Wait for a new exploit** — The XDA community ([raven root thread](https://xdaforums.com/t/4573691/), [system user thread](https://xdaforums.com/t/4759215/)) is active. New vulnerabilities may be discovered that affect PS7711.

4. **Buy a second Cube on older firmware** — Some sellers on eBay/Amazon have new-old-stock units that ship with older (rootable) firmware. Ensure you block OTA updates immediately after setup before Amazon forces an update.

### If You Obtain Root

Once you have root access (via any method), proceed with the installation methods below.

### Installation Methods (Once Rooted)

#### Method 1: Direct System App Replacement (Recommended)

Replaces the firebat APK in the system partition.

```bash
# 1. Connect to Fire TV via ADB
adb connect <fire-tv-ip>:5555

# 2. Open a root shell
adb shell
su

# 3. Find the current firebat installation path
pm path com.amazon.firebat
# Output example: package:/system/priv-app/firebat/firebat.apk
# Note the exact path for steps below.

# 4. Remount /system as read-write
mount -o rw,remount /system

# 5. Back up the original APK (important for reverting)
cp /system/priv-app/firebat/firebat.apk /sdcard/firebat_original.apk

# 6. Exit shell
exit
exit

# 7. Push patched APK to device
adb push firebat_patched_signed.apk /sdcard/firebat_patched.apk

# 8. Root shell again
adb shell
su

# 9. Replace the APK (use exact path from step 3)
cp /sdcard/firebat_patched.apk /system/priv-app/firebat/firebat.apk

# 10. Fix permissions (wrong permissions = bootloop)
chmod 644 /system/priv-app/firebat/firebat.apk
chown root:root /system/priv-app/firebat/firebat.apk

# 11. Remount read-only
mount -o ro,remount /system

# 12. Clear app cache
pm clear com.amazon.firebat

# 13. Reboot
reboot
```

#### Method 2: Magisk Module (Systemless, Survives OTA)

Overlays the patched APK over the original at boot without modifying `/system`.

```bash
# On your computer, create module structure:
mkdir -p firebat-noads/system/priv-app/firebat
cp firebat_patched_signed.apk firebat-noads/system/priv-app/firebat/firebat.apk
```

Create `firebat-noads/module.prop`:
```
id=firebat-noads
name=Firebat No Ads
version=1.0
versionCode=1
author=patch
description=Patches firebat to disable Prime Video ads
```

Create `firebat-noads/customize.sh`:
```bash
MODPATH="${0%/*}"
set_perm_recursive $MODPATH/system 0 0 0755 0644
```

```bash
# Package and install:
cd firebat-noads && zip -r ../firebat-noads.zip . && cd ..
adb push firebat-noads.zip /sdcard/
adb shell su -c "magisk --install-module /sdcard/firebat-noads.zip"
adb shell reboot
```

#### Method 3: pm install with Root (Simplest, Less Reliable)

```bash
adb push firebat_patched_signed.apk /sdcard/firebat_patched.apk
adb shell su -c "pm install -r -d /sdcard/firebat_patched.apk"
```

If this fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`:

```bash
adb shell su -c "pm uninstall -k com.amazon.firebat"
adb shell su -c "pm install /sdcard/firebat_patched.apk"
```

**Warning:** Uninstalling firebat may break video playback until the patched version is installed. Method 1 or 2 is safer.

### Post-Installation Verification

```bash
# Verify the patched APK is loaded
adb shell pm path com.amazon.firebat

# Test playback:
# - Play any ad-supported content on Prime Video
# - Expected: content plays immediately, no pre-roll ads
# - Expected: no mid-roll ad breaks during playback
# - Expected: seekbar has no ad markers, seeking is unrestricted
```

### Reverting the Patch

**Method 1 revert:**
```bash
adb shell
su
mount -o rw,remount /system
cp /sdcard/firebat_original.apk /system/priv-app/firebat/firebat.apk
chmod 644 /system/priv-app/firebat/firebat.apk
chown root:root /system/priv-app/firebat/firebat.apk
mount -o ro,remount /system
pm clear com.amazon.firebat
reboot
```

**Method 2 revert:**
```bash
adb shell su -c "magisk --remove-modules firebat-noads"
adb shell reboot
```

**Method 3 revert:**
```bash
adb shell su -c "pm install -r /system/priv-app/firebat/firebat.apk"
```

### Preventing OTA Updates from Overwriting the Patch

Amazon can push OTA updates that replace firebat:

```bash
# Disable automatic system updates
adb shell su -c "pm disable com.amazon.device.software.ota"
```

With Magisk (Method 2), the module overlay re-applies on every boot, so even if the base APK is updated by OTA, the patched version takes precedence — as long as Magisk itself survives the OTA.

## Files Modified

Only one file was changed:

```
smali_classes3/com/amazon/avod/media/ads/internal/AdBreakSelector.smali
```

Original: 848 lines (4 methods with full ad break selection logic)
Patched: 122 lines (4 stub methods returning null + unchanged constructor)
