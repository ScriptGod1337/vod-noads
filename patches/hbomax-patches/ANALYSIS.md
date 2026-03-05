# HBO Max Ad System — Reverse Engineering Analysis

Analysis of HBO Max v6.16.2.2 Fire OS APK ad delivery architecture and patch rationale.

## Fire OS APK Architecture

### Key Finding: HBO Max Ships Separate Fire OS APK

Unlike Netflix (which ships a single unified APK), HBO Max ships a **separate Fire OS build** with the channel identifier `MaxFireTV`. The package name is `com.hbo.hbonow` (legacy from HBO Now, retained for Fire OS).

```
┌─────────────────────────────────────────────────────────────┐
│               com.hbo.hbonow v6.16.2.2                      │
│               Fire OS variant (MaxFireTV)                    │
├─────────────────────────────────────────────────────────────┤
│  Application: com.wbd.beam.BeamApplication                  │
│  TV Engine: You.i Engine (tv.youi.youiengine)               │
│  Ad SDK: Discovery AdTech SDK (com.discovery.adtech.sdk)    │
├─────────────────────────────────────────────────────────────┤
│  Amazon-specific components:                                │
│    ├── AmazonSubscriptionEntitlementReceiver (IAP)          │
│    ├── AmazonContentEntitlementReceiver                     │
│    ├── MaxDataIntegrationService (content integration)      │
│    ├── DynamicCapabilityReporter (Alexa)                    │
│    ├── AlexaDirectiveReceiver (VSK voice control)           │
│    ├── CapabilityRequestReceiver                            │
│    └── UpdateLauncherChannelsJobService                     │
├─────────────────────────────────────────────────────────────┤
│  Deep links: play.max.com, play.hbomax.com                 │
│  Partner ID: HBO40_H                                        │
│  Launcher ID: hbo_max_global                                │
└─────────────────────────────────────────────────────────────┘
```

### Obfuscation Status

**Almost all ad-related classes are non-obfuscated.** This is a major advantage for patching:

| Package | Obfuscated? | Example |
|---------|-------------|---------|
| `com.discovery.adtech.sdk` | No | `AdTechSdk`, `AdTechSdkBuilderImpl` |
| `com.discovery.adtech.core` | No | `AdBreak`, `AdState`, `SsaiProvider` |
| `com.discovery.adtech.adskip` | No | `AdSkipModule`, `AdSkipState` |
| `com.discovery.adtech.pauseads` | No | `PauseAdsInteractor`, `ShowPauseAdUseCase` |
| `com.discovery.adtech.ssaibeaconing` | No | `SsaiClientSideBeaconingModule` |
| `com.discovery.adtech.freewheel` | No | `VideoViewModule` |
| `com.discovery.adtech.adsparx` | No | `AdSparxModule` |
| `com.discovery.player.utils` | No | `BoltAdStrategyMapper` |
| `tv.youi.videolib.adtech` | No | `AdTechConfig`, `Features`, `PauseAds` |
| `com.wbd.adtech.ad.ui` | No | `ServerSideAdOverlay` |

## Ad System Architecture

HBO Max uses a three-layer ad delivery system:

### 1. SSAI Video Ad Breaks — NOT PATCHABLE (Server-Stitched)

Ads are stitched into the media manifest server-side via **AdSparx** SSAI. The client receives a single continuous stream with ads already embedded.

```
Server (Bolt PIR) → returns manifest URL with ads stitched in
  ├── In-band HLS timed metadata → AdSparxTimedMetadataAdapter
  ├── Ad break positions → AdSkipModule tracks/enforces
  ├── Client-side beaconing → SsaiClientSideBeaconingModule
  └── Ad overlay UI → ServerSideAdOverlay (countdown, badge, count)
```

**Not patchable** because the ad video content is indistinguishable from regular content in the stream.

### 2. Pause Ads — PATCHABLE (Client-Driven)

```
Player pauses → PauseAdsInteractor.listen() detects pause
  ├── Static mode: ShowPauseAdUseCase loads from stream metadata
  ├── Dynamic mode: ShowDynamicPauseAdUseCase fetches via DynamicAdFetcher
  ├── Wait pauseAdIdleDelay (3000ms default)
  ├── Load creative via PauseAdCreativeRepositoryImpl (Glide)
  ├── PlayerUIAdapter.showPauseAd(bitmap, shoppableData)
  └── Beaconing: DispatchPauseAdBeaconUseCase fires impression/completion
```

### 3. Ad Skip Enforcement — PATCHABLE (Client-Side Seek Interception)

```
User seeks forward → AdSkipModule.interveneIfSeekingForwardsOverUnwatchedAdBreak()
  ├── Checks all ad breaks between current and target position
  ├── If unwatched ad break found → redirectToNewAdBreak(FORCE_WATCH)
  ├── User is forced to watch the ad break before continuing
  └── After watching → seek allowed to original target
```

## Patch Targets

### Primary: BoltAdStrategyMapper.map() — Force `ad_free`

The `BoltAdStrategyMapper` is a singleton that resolves the ad strategy tier from a server-provided array:

```
Priority: "ad_free" > "ad_light" > "ad_full"
```

**Current bytecode (14 instructions):**
```smali
.method public final map([Ljava/lang/String;)Ljava/lang/String;
    .registers 4
    const-string v0, "adStrategies"
    invoke-static v3, v0, Lkotlin/jvm/internal/Intrinsics;->checkNotNullParameter(...)V
    const-string v0, "ad_free"
    invoke-static v0, v3, Lmb/r;->o(...)Z    # arrayContains("ad_free", strategies)
    move-result v1
    if-eqz v1, +003h                          # if not ad_free, check ad_light
    goto +ch                                    # → return "ad_free"
    const-string v0, "ad_light"
    invoke-static v0, v3, Lmb/r;->o(...)Z
    move-result v3
    if-eqz v3, +003h
    goto +3h                                    # → return "ad_light"
    const-string v0, "ad_full"                 # fallback
    return-object v0
.end method
```

**Patched bytecode:**
```smali
.method public final map([Ljava/lang/String;)Ljava/lang/String;
    const-string v0, "ad_free"
    return-object v0
.end method
```

**Effect:** All downstream ad modules see "ad_free" and disable themselves. This affects:
- Ad overlay UI configuration
- Pause ad scheduling
- Ad skip enforcement activation
- Ad beaconing
- MuxAppConfig analytics tagging

**Risk:** MEDIUM — The SSAI video content is already stitched server-side and will still play. However, the client won't show ad overlay UI, won't enforce ad watching, and won't fire beacons.

### Pause Ads: PauseAdsInteractor + Use Cases

Three methods are no-opped:

| Target | Log String (Fingerprint) | Effect |
|--------|-------------------------|--------|
| `PauseAdsInteractor.listen()` | `"Detected player is paused. PauseAd will be shown after a delay."` | No subscription to pause events |
| `ShowDynamicPauseAdUseCase` | `"Canceling old pause ad request if active"` | No dynamic pause ad fetching |
| `ShowPauseAdUseCase` | `"Attempting to show pause ad after player paused and idle..."` | No static pause ad display |

**Risk:** LOW — Pause ads are purely client-side overlays. No network or playback impact.

### Ad Skip: AdSkipModule

Two methods are no-opped:

| Target | Log String (Fingerprint) | Effect |
|--------|-------------------------|--------|
| Ad break interception | `"AdSkipModule Skipping an adbreak "` | No seek interception |
| Ad break redirect | `"AdSkipModule Skipping to "` | No forced redirect to ad breaks |

**Risk:** LOW — Users can freely seek past SSAI ad break segments. The ad video content is still in the stream but can be skipped.

### Optional: Beacon Suppression

Three beacon methods are no-opped:

| Target | Log String (Fingerprint) | Effect |
|--------|-------------------------|--------|
| SSAI beacon repository | `"SsaiClientSideBeaconRepositoryImpl"` | No SSAI impression/quartile beacons |
| Pause ad beacon emitter | `" for PauseAd beacon "` | No pause ad impression beacons |
| Pause ad beacon dispatch | `"DispatchPauseAdBeaconUseCase.kt"` | No pause ad beacon orchestration |

**Risk:** MEDIUM — Suppresses all ad tracking. Server may detect missing impressions over time.

## Fingerprint Strategy

### Why Non-Obfuscated String Fingerprints Work Here

Unlike Netflix (where classes are aggressively obfuscated to single-letter names), HBO Max's Discovery AdTech SDK retains meaningful class and method names. The log strings used for fingerprinting are:

1. **Functional log messages** — Written by developers for debugging, unlikely to be removed
2. **Kotlin file name strings** — Automatically included by the Kotlin compiler in stack traces
3. **Unique per-method** — Each log string appears in exactly one method

This makes fingerprinting HBO Max significantly more reliable than Netflix, where we had to navigate from caller log strings to obfuscated target methods.

### Fingerprint Stability Across Versions

| Fingerprint | Relies On | Stability |
|-------------|-----------|-----------|
| `boltAdStrategyMapper` | `"ad_free"`, `"ad_light"`, `"ad_full"` string constants | Very High — these are server API contract values |
| `pauseAdsInteractorListen` | `"Detected player is paused..."` log string | High — functional log message |
| `showDynamicPauseAd` | `"Canceling old pause ad request..."` log string | High — functional log message |
| `showStaticPauseAd` | `"Attempting to show pause ad..."` log string | High — functional log message |
| `adSkipModuleSkip` | `"AdSkipModule Skipping an adbreak "` log string | High — module-prefixed log |
| `adSkipModuleRedirect` | `"AdSkipModule Skipping to "` log string | High — module-prefixed log |
| `ssaiBeaconRepository` | `"SsaiClientSideBeaconRepositoryImpl"` class name string | Medium — Kotlin compiler artifact |
| `pauseAdBeaconEmitter` | `" for PauseAd beacon "` log string | High — functional log message |
| `dispatchPauseAdBeacon` | `"DispatchPauseAdBeaconUseCase.kt"` file name string | Medium — Kotlin compiler artifact |

## Patch Grouping Rationale

### forceAdFreeStrategyPatch (primary, enabled by default)

Forces the ad strategy to "ad_free" at the client decision point. This is the broadest patch — it affects all downstream ad behavior. However, SSAI video content is still in the stream.

### disablePauseAdsPatch (enabled by default)

Specifically targets pause ads through three no-ops. Defense in depth — even if the strategy patch fails, pause ads are still blocked.

### disableAdSkipEnforcementPatch (enabled by default)

Disables the snapback/force-watch behavior. Combined with the strategy patch, this means:
- No ad overlay UI (strategy says ad_free)
- No seek enforcement (skip module no-opped)
- User can freely scrub past SSAI ad segments

### disableAdTrackingPatch (optional, disabled by default)

Separate because:
1. Beacon suppression is detectable server-side
2. Users should choose based on risk tolerance
3. Without this patch, beacons may still fire for SSAI segments that play through

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| SSAI video ads still in stream | Certain | Users can seek past them (skip enforcement disabled) |
| Server detects missing beacons | Low-Medium | Only with tracking patch; without it, beacons still fire |
| Fingerprint breakage on update | Low | Non-obfuscated names + functional log strings are stable |
| Play Integrity / attestation | Low | Only Google Ads SDK attestation found, not app-level |
| Server changes ad_free semantics | Low | API contract value, unlikely to change |
| Pause ad pipeline refactored | Low | Three independent no-ops provide redundancy |

## Comparison: HBO Max vs Netflix vs Disney+ Patch Approach

| Aspect | Netflix | Disney+ | HBO Max |
|--------|---------|---------|---------|
| **Primary patch** | Force feature flag `e()Z` → false | Force `noAds = true` | Force strategy → `"ad_free"` |
| **Pause ads** | Feature flag + prefetch no-op | N/A (no pause ads) | Interactor + use case no-ops |
| **Seek enforcement** | N/A | Interstitial scheduling no-op | AdSkipModule no-ops |
| **Fingerprint type** | Log strings (obfuscated caller) | Field name + opcode | Log strings (non-obfuscated) |
| **Obfuscation level** | Heavy | Mixed | **Minimal** |
| **SSAI blockable?** | No | N/A (uses SGAI) | No |
| **Package** | `com.netflix.mediaclient` | `com.disney.disneyplus` | `com.hbo.hbonow` |
