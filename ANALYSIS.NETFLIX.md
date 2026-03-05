# Netflix Android APK Ad System Analysis

## APK Metadata

| Field | Value |
|-------|-------|
| Package | `com.netflix.mediaclient` |
| Version | 9.0.0 build 4 62189 |
| Target SDK | 34 (Android 14) |
| Min SDK | 28 (Android 9) |
| DEX files | 8 (classes.dex through classes8.dex, ~38MB total) |
| Architecture | arm64-v8a, armeabi-v7a, x86, x86_64 |

## Executive Summary

**YES — Netflix Basic (with ads) has significant client-side ad orchestration logic.** The APK contains two distinct ad systems:

1. **Video Ad Breaks** (mid-roll/pre-roll) — Managed by an `AdvertsManager` + SCTE-35 marker system using Server-Side Ad Insertion (SSAI) with client-side hydration
2. **Pause Ads** (display ads shown when paused) — Fully client-driven, fetched and rendered entirely by client code

Both systems have client-side chokepoints that could theoretically be patched, though the SSAI approach makes video ad breaks significantly harder than Amazon's implementation.

---

## Ad System Architecture

### Layer 1: Video Ad Breaks (SSAI + Client Hydration)

Netflix uses **Server-Side Ad Insertion (SSAI)** combined with **SCTE-35 markers** in the media stream. Unlike Amazon's approach (which is also SSAI but with a fully client-side `AdBreakSelector` chokepoint), Netflix splits the decision-making:

#### Key Classes

| Class | Location | Role |
|-------|----------|------|
| `AdvertsManager` | `classes4.dex` (obfuscated as `Lo/efs;`) | Central ad orchestration — manages hydration requests, data providers, break state |
| `AdBreakType` | `classes4.dex` | Enum with 4 values (a/b/c/d) — likely: PRE_ROLL, MID_ROLL, POST_ROLL, UNKNOWN |
| `AdBreak` | `classes.dex` (`ui.player.v2`) | UI-layer ad break model with fields: `isPreRoll`, `SegmentationType`, locationMs, duration |
| `AdBreak$SegmentationType` | `classes.dex` | Enum with 4 values (b/c/d/e) — segmentation types for SCTE-35 markers |
| `AdBreakHydrationException` | `classes4.dex` | Exception for failed hydration requests |
| `PlayerAdBreakState` | `classes.dex` | State object: `PlayerAdBreakState(isPreRoll=...)` |
| `PlayerAdsUIExperienceState` | `classes.dex` | UI state: `PlayerAdsUIExperienceState(adBreakState=...)` |
| `PlayerAdsListenerImpl` | `classes4.dex` | Player event listener with `onAdsInterstitial` handler |
| `EmbeddedAdsState` | `classes4.dex` | Tracks SCTE ad break start times: `EmbeddedAdsState(adBreakStartTimeScteMs=...)` |
| `Scte35Data` | `classes4.dex` | SCTE-35 signal data with `segmentationEventId` and `segmentationTypeId` |

#### How It Works

```
1. Content stream contains SCTE-35 markers signaling ad break positions
2. Client detects markers → EmbeddedAdsState tracks break timing
3. AdvertsManager.requestHydration() calls /playapi/android/adbreakhydration
4. Server returns ad creative URLs for that break
5. Player transitions into ad break state (PlayerAdBreakState)
6. UI shows ad break progress indicator
7. After ads complete, content resumes
```

#### API Endpoint
- **`/playapi/android/adbreakhydration`** — The hydration endpoint fetched by `AdvertsManager`
- **`/playapi/android/event/1`** — Event tracking/reporting endpoint

#### Key Difference from Amazon
Amazon's `AdBreakSelector` makes **all** decisions client-side (pre-roll eligibility, mid-roll scheduling, seek-over-ad detection). Netflix's `AdvertsManager` acts more as a **coordinator** — it calls the server to hydrate ad breaks that are already embedded in the stream via SCTE-35 markers. The server has much more control.

### Layer 2: Pause Ads (Client-Driven Display Ads)

This is a **fully client-side ad system** and the most promising patch target. When the user pauses playback, Netflix displays a static/display advertisement overlay.

#### Key Classes

| Class | Location | Role |
|-------|----------|------|
| `PauseAdsRepositoryImpl` | `classes4.dex` | Fetches ad data and video data from server |
| `PauseAdsPrefetchPresenterImpl` | `classes4.dex` | Prefetches ads before pause event; decides whether to show |
| `PauseAdsPresenterImpl` | `classes4.dex` | Presents the pause ad overlay UI |
| `PauseAdsInactivityTimerImpl` | `classes4.dex` | Timer that triggers ad display after inactivity |
| `PauseAdsScreen` | `classes4.dex` | Screen model combining player data + ad result + video data |
| `PauseAdsPlayerData` | `classes4.dex` | Player context: position, playback context ID, video ID |
| `PauseAdsAdData` | `classes4.dex` | Ad creative data: creativeId + 4 other string fields (likely imageUrl, clickUrl, trackingUrl, adToken) |
| `PauseAdsAdResult` | `classes4.dex` | Result sealed class with subclasses: `Ad`, `Error(a)`, `Error(b)`, `NoAd(c)`, `Disabled(d)` |
| `PauseAdsVideoData` | `classes4.dex` | Video metadata for ad targeting: title + 6 fields including Boolean (likely isAdEligible) |
| `PauseAdsExternalEventFlowImpl` | `classes4.dex` | Event flow for pause events from player |
| `PauseAdsAnimationUtilsKt` | `classes4.dex` | Animation utilities for ad reveal/dismiss |
| `pauseAdsFeatureFlagHelper` | `classes4.dex` | Feature flag controlling pause ads |

#### GraphQL Queries
- `PauseAdsPlaybackAdQuery(videoId=...)` — Fetches ad creative for a specific video
- `PauseAdsVideoDataQuery(videoId=...)` — Fetches video metadata for ad targeting

#### Pause Ad Flow
```
1. User pauses video → PauseAdsExternalEventFlowImpl emits event
2. PauseAdsInactivityTimerImpl checks inactivity threshold
3. PauseAdsPrefetchPresenterImpl.prefetchAd() fetches from PauseAdsRepositoryImpl
4. Repository queries PauseAdsPlaybackAdQuery + PauseAdsVideoDataQuery
5. If PauseAdsAdResult is .Ad → PauseAdsPresenterImpl renders PauseAdsScreen
6. Display ad tracking: AdStartDisplayPauseEvent → AdProgressDisplayPauseEvent → AdCompleteDisplayPauseEvent
7. On error: AdErrorDisplayPauseEvent with DisplayPauseAdErrorType (ad_content, ad_image, ad_token, title_metadata, other)
```

### Layer 3: Interstitials (CLCS System)

Netflix has a third ad-adjacent system called **CLCS (Client-Level Content Services) Interstitials**. These are server-driven UI overlays for various purposes:

- Playback interstitials (before/after content)
- Lolomo (home feed) interstitials
- Profile gate interstitials
- Playback error interstitials
- Demographic survey interstitials

Key class: `InterstitialCoordinator` + `InterstitialsImpl` (classes3-4.dex)

These appear to be more promotional/UX-driven than traditional advertising, but `AdInterstitialBefore` and `AdInterstitialAfter` types exist, suggesting some are genuine ad placements.

### Layer 4: Ad Event Tracking

| Event Class | Purpose |
|-------------|---------|
| `AdEvent` | Base class with `adEventToken` |
| `AdDisplayPauseEvent` | Base for all pause ad events (mediaOffset, playbackContextId, viewableId, xid) |
| `AdStartDisplayPauseEvent` | Pause ad started displaying |
| `AdProgressDisplayPauseEvent` | Pause ad viewability progress (with `AdDisplayClientLog`) |
| `AdCompleteDisplayPauseEvent` | Pause ad completed display (with `AdDisplayClientLog`) |
| `AdErrorDisplayPauseEvent` | Pause ad failed to display |
| `AdOpportunityDisplayPauseEvent` | Pause ad opportunity was available |
| `AdDisplayViewability` | Viewability tracking: adElementWidth/Height, screenWidth/Height, inViewPercentage, epochMillis |

---

## Plan Tier Detection

The APK contains explicit plan tier references:

- `"basic_with_ads"` — Plan identifier string
- `"standard_with_ads"` — Plan identifier string
- `"AD_SUPPORTED"` — Plan type enum/constant
- `"ITEM_ID_WHATS_DIFFERENT_WITH_ADS"` — UI element for explaining ad tier
- `"whatsDifferentWithAdsViewModel"` — ViewModel for ads explanation screen
- `"whats_different_with_ads"` — Navigation/screen identifier

The `pauseAdsFeatureFlagHelper` string suggests a feature flag system controls whether pause ads are enabled, likely gated on the user's subscription tier.

---

## Feature Flag Deep Dive — `pauseAdsFeatureFlagHelper`

This section documents the result of fully tracing the feature flag system (investigation point #1 from the original analysis).

### Class Hierarchy

```
Lo/fUW;                          ← abstract interface (5 boolean methods: a–e)
  └── Lo/fVb;                    ← concrete implementation (7 internal boolean fields: a–f, j)
```

`Lo/fUW;` is injected into `PlayerFragmentV2` as field `pauseAdsFeatureFlagHelper`, and also into:
- `Lo/fVv;` (PauseAdsPrefetchPresenterImpl) — field `e: Lo/fUW;`
- `Lo/fVt;` (PauseAdsPresenterImpl) — constructor arg
- `Lo/fVu;` — another pause-ad component

### `Lo/fVb;` Construction — Hendrix Config Flags

`Lo/fVb;` is built by `Lo/ceZ$r;->fa()` (the Hilt singleton component), using 7 booleans read from **Netflix's Hendrix A/B config system** (`HendrixSingletonConfigModule`):

| `fVb` Field | Source Method | Hendrix Call | Meaning |
|-------------|---------------|--------------|---------|
| `d` | `eR()` | `HendrixSingletonConfigModule.c([...], 1515150910, -1515150668, ...)` | A/B test flag (TestHarnessModule involved) |
| `c` | `eO()` | `HendrixSingletonConfigModule.c(dox)` | Core pause ads enabled flag |
| `f` | `eS()` | `HendrixSingletonConfigModule.a(dox)` | Sub-flag A |
| `j` | `eT()` | `HendrixSingletonConfigModule.h(dox)` | Sub-flag B |
| `b` | `eW()` | `HendrixSingletonConfigModule.c([...], -402465964, 402465995, ...)` | A/B test flag variant |
| `e` | `eU()` | `HendrixSingletonConfigModule.b(dox)` | Logging/tracking enabled |
| `a` | lazy `Z` field | `hlK.get()` (another Hendrix lazy) | External eligibility flag |

All flags share the **same config key object** (`gV: Lo/dox;`), meaning they all read from the same Hendrix config entry — likely a compound config object for the pause ads feature.

### Feature Flag Method Logic (Decompiled)

```java
// Lo/fVb; methods — controls all pause ad gating

boolean a() {
    return e;          // eU() → HendrixConfig.b(dox) — tracking flag
}

boolean b() {
    // c=eO(), d=eR(), j=eT()
    if (!c) return false;
    if (d) return false;   // NOT eR() — not in test harness mode
    return j;              // eT() → HendrixConfig.h(dox)
}

boolean c() {
    // c=eO(), d=eR()
    return c && d;     // eO() AND eR() — test harness variant
}

boolean d() {
    // a=lazyZ, b=eW()
    return a && b;     // external eligibility AND eW() A/B flag
}

boolean e() {
    // c=eO(), d=eR(), f=eS(), j=eT()
    if (!c) return false;         // NOT enabled at all → false
    if (d) return true;           // in test harness → force true
    return f || j;                // eS() OR eT() → either sub-flag active
}
```

### Call Sites — Which Method Matters Most

| Caller | Method Called | Meaning |
|--------|---------------|---------|
| `PauseAdsPrefetchPresenterImpl.present$2$1$a.b()` | `e()` | **MAIN GATE** — "should show pause ad now?" |
| `PauseAdsPrefetchPresenterImpl.present$2$1$a.b()` | `c()` | Secondary check (test harness variant) |
| `PlayerFragmentV2.C()` | `e()` | Player-level pause ad enable check |
| `PlayerFragmentV2.f()` | `c()` | Player-level test harness check |
| `Lo/fVu;.invoke()` | `b()` | Another component's gate check (×3 call sites) |
| `Lo/fVc;.d()` | `a()`, `d()` | Ad event logging gate |

**`e()` is the primary gate**. It is called in `PauseAdsPrefetchPresenterImpl`'s present flow as the direct "should show ad?" decision point.

### The Exact Patch Target

The critical decision in `PauseAdsPrefetchPresenterImpl$present$2$1$a.b()`:
```
invoke-static v1, Lo/fVv;->d(Lo/fVv;)Lo/fUW;   ← get feature flag helper
invoke-interface v1, Lo/fUW;->e()Z               ← call e() — THE GATE
```

If `e()` returns false, the presenter takes the "no ad" path.

---

## Patchability Assessment

### Pause Ads — HIGH patchability (Client-Driven)

**This is the primary patch target.** The entire pause ad pipeline is client-driven, and the exact gate method has been identified.

#### Identified Patch Targets (in order of cleanliness)

| # | Target | DEX | What to patch | Smali change |
|---|--------|-----|--------------|--------------|
| **1** | `Lo/fVb;->e()Z` | `classes4.dex` | The main feature gate: returns false → no ads | Replace body with `const/4 v0, 0` + `return v0` |
| **2** | `Lo/fVb;->b()Z` | `classes4.dex` | Secondary gate used by `Lo/fVu;` | Same: always return `0` |
| **3** | `Lo/fVb;->d()Z` | `classes4.dex` | Event tracking gate (suppresses viewability logs) | Same: always return `0` |
| **4** | `Lo/fVb;->a()Z` | `classes4.dex` | Logging gate | Same: always return `0` |

Patching `e()` alone should suppress pause ads. Patching `b()` handles the secondary path in `fVu`. Patching `a()` and `d()` suppresses event tracking.

#### Smali Patch for `Lo/fVb;->e()Z`

Current bytecode:
```smali
.method public final e()Z
    iget-boolean v0, v1, Lo/fVb;->c Z
    if-eqz v0, +006h
    iget-boolean v0, v1, Lo/fVb;->d Z
    if-nez v0, +00ch
    iget-boolean v0, v1, Lo/fVb;->f Z
    if-nez v0, +008h
    iget-boolean v0, v1, Lo/fVb;->j Z
    if-nez v0, +004h
    const/4 v0, 0
    goto +2h
    const/4 v0, 1
    return v0
.end method
```

Patched bytecode:
```smali
.method public final e()Z
    const/4 v0, 0
    return v0
.end method
```

**Same pattern applies to `b()`, `c()`, `d()`, `a()`** — replace with `const/4 v0, 0` + `return v0`.

#### Risk Assessment

- **No network impact** — purely client-side UI suppression
- **No playback impact** — pause ad is overlay, not inline
- **Event tracking still fires** (unless `a()` and `d()` are also patched) — server may log "opportunity not shown"
- **Root NOT required** — Netflix is a regular user-space APK, patchable with apktool + zipalign + resign

### Video Ad Breaks — LOW patchability (SSAI)

The video ad break system is much harder to patch because:

1. **SCTE-35 markers are in the stream** — The server embeds ad break signals in the media manifest. You can't remove them without re-encoding.
2. **Ad hydration is server-driven** — The `/playapi/android/adbreakhydration` endpoint provides the actual ad content URLs. Even if you block hydration, the player might stall at the break point.
3. **State machine resilience** — Unlike Amazon where the FSM silently ignores missing transitions, Netflix's `AdvertsManager` has explicit error handling (`AdBreakHydrationException`, `AD_BREAK_UNAVAILABLE`, `ADBREAK_CANCEL` states).

Possible but risky approaches:
| Strategy | Notes |
|----------|-------|
| Patch AdvertsManager.requestHydration() to always fail | Risk: player may show error or buffer indefinitely at break point |
| Patch AdvertsManager.c() (the method that initiates breaks) to return false | Risk: SCTE markers still in stream, unclear if player handles gracefully |
| Intercept /playapi/android/adbreakhydration response | Would need to understand response format; risk of playback failure |

### Interstitial Ads — MEDIUM patchability

The `InterstitialsImpl.fetchPlaybackInterstitial()` and `InterstitialCoordinator` could be patched to suppress ad-type interstitials while preserving non-ad ones. The `AdInterstitialType` enum has only 2 values (a, b) — likely `BEFORE` and `AFTER`.

---

## Points for Deeper Investigation

### ✅ Resolved

1. ~~**`pauseAdsFeatureFlagHelper` implementation**~~ — **DONE.** Fully traced: `Lo/fVb;` implements `Lo/fUW;`, gate method is `e()Z`, Hendrix config keys identified. Smali patch documented above.

2. ~~**`PauseAdsAdResult` sealed class hierarchy**~~ — **DONE.** Confirmed from `PauseAdsPrefetchPresenterImpl` flow: `$c` = NoAd (singleton, `PauseAdsAdResult$c.d`), `$d` = Disabled (singleton, `PauseAdsVideoDataResult$d.d`). The presenter's state machine checks for these and short-circuits.

### ✅ Resolved (continued)

3. ~~**`AdvertsManager.c(J J Lo/efj;)Z`**~~ — **DONE. Not a gate.** The method always returns `1` (true) unconditionally. It merely launches the `requestHydration$2` coroutine and returns immediately — no conditions, no decisions. Blocking it would stall playback at an SSAI break, not skip the ad. **No patch value.**

4. ~~**`PlayerAdsListenerImpl.onAdsInterstitial`**~~ — **DONE. Wrong pipeline.** This handles **video interstitials** (pre/post-content SSAI system), not pause ads. The coroutine: (1) waits a configurable delay, (2) emits `PlayerExitedAdBreakBoundary` to the player screen (`Lo/gcg;`). It reacts *after* an ad break, it does not gate whether ads show. `Lo/fXl;` (the ad interstitial coordinator) has a method `e(AdInterstitialType, J)V` confirming it handles BEFORE/AFTER content ad types. **Completely separate from pause ad pipeline, no patch value for pause ads.**

### Should Investigate (for robustness)

5. **Server-side enforcement of pause ad viewability** — `AdProgressDisplayPauseEvent` and `AdCompleteDisplayPauseEvent` send viewability data (`AdDisplayClientLog` with `inViewPercentage`). Netflix may require these events server-side before serving the next episode or continuing certain features. The gate in `Lo/fVc;.d()` uses `fUW.d()` — if we also patch `d()Z` to return `false`, event logging is suppressed entirely, which may or may not be safer than logging "opportunity shown but 0% viewable".

6. **Certificate pinning** — Check for OkHttp `CertificatePinner` or custom `TrustManager`. Not relevant for a smali patch approach but relevant if network interception is attempted.

7. **APK integrity / Play Integrity attestation** — Check if Netflix uses `com.google.android.play.core.integrity` (`Integrity` class found in APK contents). A resigned APK may fail Play Integrity checks, which Netflix could use to block patched clients.

8. **`eR()` — TestHarnessModule involvement** — `eR()` uses `TestHarnessModule` and `System.identityHashCode()` in its Hendrix call, suggesting this is a conditional A/B test enrollment flag. When `eR()=true`, `e()` immediately returns `true` (force-show), and `c()=true` (test harness path). Understanding this toggle could be an alternative non-smali approach.

### Nice to Investigate

9. **`Scte35Data.segmentationTypeId` values** — Understanding which SCTE-35 segmentation type IDs correspond to ad breaks (vs. chapter/program boundaries) would clarify whether blocking specific SCTE signals is feasible.

10. **`PinotPausedPlaybackAd` / `PinotPausedPlaybackAdPage`** — These GraphQL types suggest the home feed (Lolomo/Pinot) also serves pause ad slots. May be a separate pipeline from `PauseAdsRepositoryImpl`.

---

## Fire OS / Cross-Platform Compatibility

### Netflix Uses a Unified APK — No Separate Fire OS Build

Unlike Disney+ (which ships separate APKs for Play Store and Fire OS), Netflix ships a **single APK** for all platforms. The same `com.netflix.mediaclient` APK is distributed through Google Play, Amazon Appstore, and Samsung Galaxy Store.

Platform-specific behavior is controlled at runtime via the `DistributionChannel` enum:

| Enum Value | Installer Package | Display Name | Field |
|-----------|-------------------|-------------|-------|
| `"google"` | `com.android.vending` | `"Google"` | `i` |
| `"amazon"` | `com.amazon.venezia` | `"Amazon"` | `d` |
| `"samsung"` | `com.sec.android.app.samsungapps` | `"Samsung"` | `g` |
| `""` | (none) | `"None"` | `h` |

### Amazon/Fire OS Components Already in the APK

The Play Store APK already contains all Amazon-specific code:

| Component | String/Class | Purpose |
|-----------|-------------|---------|
| Amazon ADM | `shouldDisableAmazonADM`, `AmazonPushNotificationOptions` | Push notifications via Amazon Device Messaging |
| Fire TV detection | `com.amazon.hardware.tv_screen` | TV hardware feature detection for UI adaptation |
| Amazon launcher | `amazon.intent.extra.*` (7 intents: DATA_EXTRA_NAME, DISPLAY_NAME, PARTNER_ID, PLAY/SIGNIN_INTENT_*) | Partner activation and deep link integration |
| Amazon browsing | `com.amazon.cloud9`, `com.amazon.cloud9.browsing.BrowserActivity` | Silk browser integration |
| Amazon release flag | `isAmazonRelease` | Build/runtime Amazon release detection |
| Amazon catalog | `amazonCatalogSearch` | Content catalog search integration |
| Soft keys | `com.amazon.permission.SET_FLAG_NOSOFTKEYS` | Fire TV soft key suppression |

### Ad System Is Platform-Agnostic

The pause ad pipeline has **zero platform checks**. No `DistributionChannel` references appear in any pause ad class:
- `PauseAdsFeatureFlagHelperImpl` reads only Hendrix config flags
- `PauseAdsPrefetchPresenterImpl` uses platform-independent GraphQL queries
- `PauseAdsPresenterImpl` renders a standard Android overlay
- `PlayerFragmentV2.C()` gate logic has no platform branching

**Result: One ReVanced patch set works for all platforms.** The `compatibleWith("com.netflix.mediaclient")` constraint matches the single APK regardless of which store installed it.

### ReVanced Patches Created

See `patches/netflix-patches/` for the complete ReVanced patch implementation:
- `patches/netflix-patches/ANALYSIS.md` — Detailed patch architecture and fingerprint strategy
- `patches/netflix-patches/patches/src/main/kotlin/app/revanced/patches/netflix/ads/DisableAdsPatch.kt` — Patch implementation
- `patches/netflix-patches/patches/src/main/kotlin/app/revanced/patches/netflix/ads/Fingerprints.kt` — Fingerprint definitions

---

## Comparison with Amazon Fire TV Approach

| Aspect | Amazon (Firebat) | Netflix |
|--------|-----------------|---------|
| **Ad insertion** | SSAI with client-side `AdBreakSelector` | SSAI with server-driven hydration |
| **Client chokepoint** | Single `AdBreakSelector` class | `AdvertsManager` + feature flags |
| **Pause ads** | Separate `RegolithServiceAccessor` | Fully client-driven `PauseAds*` classes |
| **State machine** | Custom hierarchical FSM, ignores missing transitions | State-based but with error handling |
| **Patch strategy** | Null `AdBreakSelector` methods | Feature flag override + presenter patching |
| **Root required?** | Yes (system app) | No (user-installable APK) |
| **Patch difficulty** | Medium (single chokepoint) | Easy (pause ads) / Hard (video ads) |
| **DNS blocking viable?** | No (same CDN) | No (same CDN + SSAI) |

---

## Tools Used

- **androguard 4.1.3** — DEX parsing, class/method/field enumeration, string extraction
- **unzip** — APK extraction
- **Python 3** — Analysis scripting

## Files Analyzed

- `com-netflix-mediaclient-62189-69798012-1d61bb888ff34ba9f5a1332988501234.apk`
- 8 DEX files totaling ~38MB
- Focused on `classes.dex` (player UI), `classes3.dex` (GraphQL/API), `classes4.dex` (service layer, pause ads)
