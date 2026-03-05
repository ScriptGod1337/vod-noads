# HBO Max (Fire OS) APK Ad System Analysis

## APK Metadata

| Field | Value |
|-------|-------|
| Package | `com.hbo.hbonow` |
| Version | 6.16.2.2 (code 1706162002) |
| Target SDK | 35 (Android 15) |
| Min SDK | 22 (Android 5.1) |
| DEX files | 6 (classes.dex through classes6.dex, ~32MB total) |
| Application class | `com.wbd.beam.BeamApplication` |
| TV engine | You.i Engine (`tv.youi.youiengine`) |
| Build variant | Fire OS (`CHANNEL=MaxFireTV`) |
| Deep link hosts | `play.hbomax.com`, `play.max.com` |

---

## Executive Summary

**YES — HBO Max (with ads) has significant client-side ad orchestration logic.** The app uses **Server-Side Ad Insertion (SSAI)** via **AdSparx** as its primary ad delivery mechanism, with **FreeWheel** as the ad decisioning server and **Uplynk** as the CDN-level SSAI provider. The ad system has several client-side chokepoints, though the architecture is more server-driven than Netflix or Disney+.

The ad decision chain is:

```
Bolt PIR Request → Server returns PlaybackInfoResponse with:
  ├─ adStrategies[] → BoltAdStrategyMapper resolves: "ad_free" | "ad_light" | "ad_full"
  ├─ capabilities[] → each has {name, enabled} (PAUSE_ADS, BRIGHTLINE, etc.)
  ├─ ssaiInfo → AdSparx SSAI timeline + vendor attributes
  └─ entitledUntilDate → entitlement expiry

Client-side:
  ├─ AdTechSdk initializes modules based on capabilities
  ├─ AdSparx parses in-band HLS timed metadata for ad break positions
  ├─ SsaiClientSideBeaconingModule fires impression/quartile beacons
  ├─ AdSkipModule enforces ad watching (snapback on seek)
  └─ PauseAdsInteractor shows static/dynamic pause ads on player pause
```

**Three distinct ad systems exist:**

1. **Video Ad Breaks (SSAI)** — Server-stitched into the media manifest via AdSparx; client handles beaconing and UI overlay
2. **Pause Ads** — Client-driven display ads (static from stream metadata or dynamic via fetch) shown when playback is paused
3. **Ticket Stub Ads** — Non-linear overlay ads shown during content (branded content)

---

## Ad System Architecture

### Layer 1: Bolt Playback Info Resolution (PIR) — Server-Side Gate

The **Bolt PIR** system is the master gate for all ad decisions. The client sends a `BoltPlaybackInfoRequest` to the server, which returns a `PlaybackInfoResponse` containing:

| Field | Type | Purpose |
|-------|------|---------|
| `capabilities[]` | List of `{name, enabled}` | Per-feature toggles (PAUSE_ADS, BRIGHTLINE, GOOGLE_PAL, IAB_OM, COMSCORE, KANTAR, NIELSEN_DCR, GEMIUS, PERMUTIVE) |
| `ssaiInfo` | String (JSON) | AdSparx SSAI configuration with `forecastTimeline` and `vendorAttributes` |
| `entitledUntilDate` | String | Subscription entitlement expiry |
| `manifest` | Object | Stream manifest URL (with ads already stitched in for SSAI) |
| `videos[]` | List | Video stream variants |

#### Key Classes

| Class | Package | Role |
|-------|---------|------|
| `BoltPlaybackInfoResolver` | `com.wbd.player.bolt.pir.core` | Sends PIR request, receives response |
| `PlaybackInfoResponse` | `com.wbd.player.bolt.pir.model.response` | Server response model |
| `PlaybackInfoResponseMapper` | `com.wbd.player.bolt.pir.mapper` | Maps response → `StreamInfo` (48 instructions) |
| `BoltPlaybackRequestAdParametersProviderImpl` | `com.wbd.player.bolt.pir` | Builds ad parameters for PIR request |
| `BoltPlaybackRequestAdConfig` | `com.wbd.player.bolt.pir` | Device type, PRISM UKID, debug config |

#### PIR Ad Parameters Sent to Server

`BoltPlaybackRequestAdParameters` includes:
- `adBlockerDetection` (Boolean)
- `device.adId`, `device.adAttributes`
- `server.deviceId`, `server.iabUSPrivacy`, `server.iabTCFString`, `server.isLimitedAdTracking`
- `server.adJourneyId`, `server.adCampaignId`, `server.mvpdId`
- `server.prismTests`, `server.prismUkid`
- `enrichment.segments`, `enrichment.spec`, `enrichment.tearsheet`, `enrichment.csid`
- `enrichment.activeABTestIds`, `enrichment.pageAdSessionId`, `enrichment.pageType`
- `ssaiProvider.version`
- `googlePALNonce`, `cohorts`

### Layer 2: Ad Strategy Resolution — `BoltAdStrategyMapper`

**`com.discovery.player.utils.adstrategy.BoltAdStrategyMapper`** — The most critical client-side decision point.

Three ad strategy tiers:

| Strategy | Constant | Meaning |
|----------|----------|---------|
| `ad_free` | `ADSTRATEGY_AD_FREE` | No ads at all — premium tier |
| `ad_light` | `ADSTRATEGY_AD_LIGHT` | Limited ads — "With Ads" tier |
| `ad_full` | `ADSTRATEGY_AD_FULL` | Full ad load |

#### `map()` Method — THE PRIMARY GATE

```smali
.method public final map([Ljava/lang/String;)Ljava/lang/String;
    .registers 4

    const-string v0, "adStrategies"
    invoke-static v3, v0, Lkotlin/jvm/internal/Intrinsics;->checkNotNullParameter(Ljava/lang/Object; Ljava/lang/String;)V

    const-string v0, "ad_free"
    invoke-static v0, v3, Lmb/r;->o(Ljava/lang/Object; [Ljava/lang/Object;)Z
    move-result v1
    if-eqz v1, +003h        ; if "ad_free" NOT in array, skip
    goto +ch                  ; → return "ad_free"

    const-string v0, "ad_light"
    invoke-static v0, v3, Lmb/r;->o(Ljava/lang/Object; [Ljava/lang/Object;)Z
    move-result v3
    if-eqz v3, +003h        ; if "ad_light" NOT in array, skip
    goto +3h                  ; → return "ad_light"

    const-string v0, "ad_full"  ; fallback: "ad_full"
    return-object v0
.end method
```

**Priority**: `ad_free` > `ad_light` > `ad_full`. If the server includes `ad_free` in the strategies array, the client uses it unconditionally.

### Layer 3: Capability Gating

`com.discovery.adtech.sdk.playerservices.GetDisabledCapabilitiesKt` provides capability checks:

| Method | Signature | Purpose |
|--------|-----------|---------|
| `getDisabledCapabilities(Playable)` | → `Set<Capability>` | Gets disabled capabilities from stream info |
| `getDisabledCapabilities(StreamInfo)` | → `Set<Capability>` | Extracts disabled set from `PlaybackSessionConfig` |
| `getIsCapabilityDisabled(StreamInfo, Capability)` | → `boolean` | Checks if specific capability is disabled |

Capabilities that can be disabled:

| Capability | Purpose |
|------------|---------|
| `PAUSE_ADS` | Pause ad display |
| `BRIGHTLINE` | Brightline interactive ads |
| `GOOGLE_PAL` | Google Programmatic Access Library |
| `IAB_OM` | IAB Open Measurement |
| `COMSCORE` | Comscore analytics |
| `KANTAR` | Kantar measurement |
| `NIELSEN_DCR` | Nielsen Digital Content Ratings |
| `GEMIUS` | Gemius analytics |
| `PERMUTIVE` | Permutive audience data |

### Layer 4: AdTech SDK — Module System

The Discovery AdTech SDK (`com.discovery.adtech.sdk`) is the central ad runtime:

#### SDK Builder

`AdTechSdkBuilderImpl` initializes with all flags set to `true`:
- `enableTelemetry`
- `enablePromoBeaconing`
- `enableConsentManagement`
- `enableGMSSForLiveStreams`
- `enableClientSideBeaconingForVod`
- `enableClientSideBeaconingForLive`
- `enableVideoView`

The `build()` method creates the `DefaultAdTechSdk` singleton with lazy delegates for all ad modules.

`disableAdUi()` method exists to suppress the ad overlay UI.

#### SDK Modules

| Module | Package | Role |
|--------|---------|------|
| `SsaiClientSideBeaconingModule` | `com.discovery.adtech.ssaibeaconing` | Fires SSAI beacons (impression, quartile, complete) |
| `AdSparxModule` | `com.discovery.adtech.adsparx` | Parses in-band HLS timed metadata for ad breaks |
| `VideoViewModule` | `com.discovery.adtech.freewheel.videoview` | FreeWheel video view beaconing |
| `AdSkipModule` | `com.discovery.adtech.adskip` | Enforces ad watching, snapback on seek |
| `PauseAdsInteractor` | `com.discovery.adtech.pauseads` | Orchestrates pause ad display |
| `BrandedContentPlugin` | `com.discovery.adtech.sdk.brandedcontent` | Branded content beaconing |
| `PromoEventBeaconingPlugin` | `com.discovery.adtech.sdk` | Promo event beaconing |

### Layer 5: SSAI (Server-Side Ad Insertion) via AdSparx

HBO Max uses **Server-Side Ad Insertion** — ads are stitched into the media manifest server-side. The client's role is:

1. **Receive the ad-stitched manifest** from the Bolt PIR response
2. **Parse in-band timed metadata** from the HLS stream (`AdSparxTimedMetadataAdapter`)
3. **Track ad break positions** and enforce viewing (`AdSkipModule`)
4. **Fire client-side beacons** for impression/quartile tracking (`SsaiClientSideBeaconingModule`)
5. **Show ad overlay UI** with countdown timer, ad badge, ad count (`ServerSideAdOverlay`)

#### SSAI Provider Enum

`com.discovery.adtech.core.models.SsaiProvider`:
- `WISTERIA` (ordinal 0)
- `GPS` (ordinal 1)
- `BOLT` (ordinal 2)

#### AdSparx In-Band Data

`DeserializedTimedMetadataMsgData` contains:
- `breakId`, `breakDuration`, `breakEvent` — ad break identification
- `timeOffset` — position in stream
- `adEvents` — individual ad events within the break
- `correlationId`, `dataUrl` — for out-of-band metadata fetch
- `playbackId`, `tenantId`, `videoId`

#### SSAI Beaconing

`SsaiClientSideBeaconingModule.shouldDispatch(StreamType)` bytecode:

```smali
.method public final shouldDispatch(Lcom/discovery/adtech/core/models/StreamType;)Z
    .registers 5

    sget-object v0, Lcom/discovery/adtech/core/models/StreamType;->VOD ...
    const/4 v1, 0
    const/4 v2, 1
    if-ne v4, v0, +008h          ; if not VOD, check Live
    iget-boolean v4, v3, ...ssbEnabledForVod Z
    if-nez v4, +009h              ; if enabled for VOD → return 0 (don't dispatch)
    const/4 v1, 1                 ; disabled → return 1 (dispatch/skip)
    goto +6h
    iget-boolean v4, v3, ...ssbEnabledForLive Z
    if-nez v4, +003h
    goto -6h
    return v1
.end method
```

**Note**: The naming is inverted — `shouldDispatch` returns `true` when beaconing is *disabled*, meaning "should dispatch the skip-beaconing signal."

#### SSAI Beacon Types

| Beacon Type | Class | When Fired |
|-------------|-------|-----------|
| Linear ad beacon | `LinearAdBeacon` | Ad impression, quartile, complete |
| Linear ad break beacon | `LinearAdBreakBeacon` | Ad break start/end |
| Video view beacon | `VideoViewBeacon` | Content engagement (FreeWheel) at 0s, 5s, 10s, 15s, 30s, 60s, 120s, 180s, 300s |

### Layer 6: Ad Skip / Snapback Module

`com.discovery.adtech.adskip.AdSkipModule` — Enforces that users watch ads by intercepting seek operations.

#### Seek Reasons

| Reason | Meaning |
|--------|---------|
| `ALLOW` | Seek permitted |
| `FORCE_WATCH` | Must watch this ad break |
| `RETURN` | Return to where seek started |
| `SKIP` | Skip already-watched ad break |
| `WATCH_DIFFERENT` | Watch a different unwatched break |

#### Key Methods

| Method | Behavior |
|--------|----------|
| `interveneIfSeekingForwardsOverUnwatchedAdBreak(SeekRequest)` | Iterates all ad breaks, finds unwatched ones between current position and seek target |
| `handleUnwatchedVodAdBreak(AdBreak)` | Redirects to ad break start position with `SeekReason.ALLOW` |
| `redirectToNewAdBreak(AdBreak, Position, Position)` | Forces seek to ad break with `SeekReason.FORCE_WATCH` |

#### State Tracking

- `watchedAdBreakIds` — Set of already-watched ad break IDs
- `watchedSlots` — Slots that have been viewed
- `slotBeingWatched` — Currently playing ad slot
- `showFirstUnwatchedInPlayback` — Flag on Factory to show first unwatched ad on playback start

### Layer 7: Pause Ads (Client-Driven)

The pause ad system is **fully client-driven** and the most promising patch target. Two modes exist:

#### Static Pause Ads

Pre-loaded from stream metadata. `ShowPauseAdUseCase` loads the creative via `PauseAdsImageRepository` (Glide-based).

#### Dynamic Pause Ads

Fetched on-demand via `DynamicPauseAdsRepository` → `DynamicAdFetcher` (GMSS service).

#### Pause Ad Model

`PauseAd` fields:
- `adId`, `adType`, `adSourceMetadata`
- `creative`, `creativeId`, `creativeType`, `apiFramework`
- `events` (impression + completion beacons)
- `imageSource` (HTTP URL)
- `title`
- `shoppableOverlayData` (product title, price, image, QR code)

#### Pause Ad Flow

```
1. User pauses → PauseAdsInteractor.listen(PlayerEvents) detects pause
2. Waits pauseAdIdleDelay (default 3000ms) with debounceDelay (500ms)
3. Static mode: ShowPauseAdUseCase loads pre-fetched PauseAd creative
   Dynamic mode: ShowDynamicPauseAdUseCase fetches via DynamicAdFetcher
4. PlayerUIAdapter.showPauseAd(Bitmap, ShoppableOverlayData) renders overlay
5. Beaconing: DispatchPauseAdBeaconUseCase fires impression/completion beacons
6. User interacts → hidePauseAdAfterUserInteraction() → PlayerUIAdapter.hidePauseAd()
```

#### Pause Ad UI

| Component | Purpose |
|-----------|---------|
| `PauseAdsPlayerOverlay` | Player overlay container |
| `PauseAdsView` | Layout with `pauseAdImage`, shoppable overlay |
| `PauseAdsOverlayViewModel` | Exposes `pauseAdBitmap`, `shoppableOverlayData` as StateFlows |
| `ShoppablePauseAdOverlayData` | Product title, price, image bitmap, QR code bitmap |

#### Pause Ad Configuration

`tv.youi.videolib.adtech.PauseAds` (bridge-layer config):

| Field | Type | Default |
|-------|------|---------|
| `enabled` | boolean | `false` |
| `delay` | long | 3000ms |
| `debounceDelay` | long | 500ms |
| `mode` | String | `"static"` |
| `shoppableOverlay` | Object | null |

`DefaultAdTechSdkConfig$Features$PauseAds` (SDK-layer):

| Field | Type | Default |
|-------|------|---------|
| `mode` | `PauseAds$Mode` | `STATIC` |
| `enableShoppableOverlay` | boolean | — |
| `pauseAdIdleDelay` | long | 3000ms |
| `debounceDelay` | long | 500ms |

### Layer 8: Ticket Stub Ads

A parallel non-linear ad system for overlay ads during content:

| Class | Role |
|-------|------|
| `TicketStubAd` | Model: scalable image, click-through URL, width/height, overlayDuration |
| `TicketStubInteractor` | Orchestrates display |
| `TicketStubBeaconEmitterImpl` | Fires HTTP beacons |
| `ShowTicketStubUseCase` | Display logic |
| `HideTicketStubUseCase` | Dismiss logic |

### Layer 9: Ad Event Tracking & Telemetry

#### Beacon Pipeline

All beacon dispatch follows a three-part pattern:
1. **BeaconEmitter** (HTTP fire via Retrofit)
2. **EventStreamsAdapter** (analytics event emission)
3. **TelemetryLogger** (observability/instrumentation)

#### Telemetry Schemas (`com.wbd.beam.libs`)

224+ telemetry data model classes including:
- `AdBeaconError`, `AdPlaybackError` (V1/V2)
- `AdHeartbeat`, `AdStateChange`
- `AdStarted`, `AdCompleted`, `AdSkipped`
- `LinearAdStartedEvent`, `LinearAdCompletedEvent`
- `AdPodRequested`, `AdPodFetched`

#### Third-Party Measurement

| Partner | Integration | Purpose |
|---------|-------------|---------|
| **FreeWheel** | `VideoViewModule`, `FreewheelConfig` | Video view beaconing, ad decisioning |
| **Comscore** | `ComscorePlugin`, `ComscoreConfig` | Content/ad measurement |
| **Nielsen DCR** | `NielsenSession`, `NielsenSessionStorage` | Digital content ratings |
| **Kantar** | `KantarConfig` | Audience measurement |
| **Gemius** | `GemiusConfig` | Analytics |
| **Brightline** | `BrightlinePlugin`, `events.brightline.tv` | Interactive ad overlays |
| **Innovid** | `InnovidConfig` | Interactive ad overlays |
| **IAB Open Measurement** | `OpenMeasurementPlugin` | Viewability measurement |
| **Google PAL** | `GooglePalPlugin` | Programmatic access |
| **Permutive** | `api.permutive.app` | Audience data platform |
| **MediaMelon** | `MMSmartStreamingNowtilusSSAIPlugin` | QoE monitoring for SSAI |
| **Mux** | `api.mux.com` | Video analytics |
| **Uplynk** | `UpLynkEventType`, ping modules | CDN-level SSAI |

### Layer 10: You.i Engine Bridge

The app uses **You.i Engine** as its TV rendering framework. The bridge layer (`tv.youi.videolib.adtech`) translates between the native/React layer and the Android AdTech SDK:

| Class | Role |
|-------|------|
| `AdTechConfig` | Top-level config container |
| `AdTechConfigManager` | Translates bridge config → SDK domain objects |
| `AdTechSDKManager` | Lifecycle management (setup/destroy) |
| `Features` | Feature flags: `enableBrightLine`, `enableGooglePal`, `enableOpenMeasurement`, `enableGoogleWhyThisAd` + JSON configs |
| `AdtechSSAIProviderInfo` | SSAI provider toggle: `enabled` (boolean), `ssaiProviderVersion` |
| `PauseAds` | Pause ad config: `enabled`, `delay`, `debounceDelay`, `mode` |

### Layer 11: Server-Side Ad Overlay UI

`com.wbd.adtech.ad.ui.ServerSideAdOverlay` — The UI overlay shown during SSAI ad breaks:

| Feature | Config Field | Purpose |
|---------|-------------|---------|
| Countdown timer | `isCountdownTimerEnabled` | Shows time remaining in ad break |
| Ad badge label | `isAdBadgeLabelEnabled` | "Ad" label |
| Ad count | `isAdCountEnabled` | "Ad 1 of 3" counter |
| Google WTA | `isGoogleWTAEnabled` | "Why This Ad?" button |
| Learn More | `isLearnMoreEnabled` | Click-through button |
| Label click-through | `isLabelClickThroughEnabled` | Clickable ad label |

---

## Patchability Assessment

### Pause Ads — HIGH Patchability (Client-Driven)

**This is the primary patch target.** The entire pause ad pipeline is client-driven.

#### Patch Target 1: `PauseAds.getEnabled()` — Force Disabled

**Target**: `tv.youi.videolib.adtech.PauseAds.getEnabled()Z`

Current bytecode:
```smali
.method public final getEnabled()Z
    iget-boolean v0, v1, Ltv/youi/videolib/adtech/PauseAds;->enabled Z
    return v0
.end method
```

Patched bytecode:
```smali
.method public final getEnabled()Z
    const/4 v0, 0
    return v0
.end method
```

**Risk**: LOW — Pause ads simply never activate. No network impact.

#### Patch Target 2: `PauseAdsInteractor.listen()` — No-Op

**Target**: `com.discovery.adtech.pauseads.domain.interactor.PauseAdsInteractor.listen()`

Replace the method body with an immediate return to prevent the interactor from subscribing to player pause events.

**Risk**: LOW — Safety net for Patch Target 1.

### Ad Strategy — HIGH Patchability (Client Decision Point)

#### Patch Target 3: `BoltAdStrategyMapper.map()` — Force `ad_free`

**Target**: `com.discovery.player.utils.adstrategy.BoltAdStrategyMapper.map([Ljava/lang/String;)Ljava/lang/String;`

Current bytecode (14 instructions):
```smali
.method public final map([Ljava/lang/String;)Ljava/lang/String;
    .registers 4
    const-string v0, "adStrategies"
    invoke-static v3, v0, Lkotlin/jvm/internal/Intrinsics;->checkNotNullParameter(...)V
    const-string v0, "ad_free"
    invoke-static v0, v3, Lmb/r;->o(...)Z
    move-result v1
    if-eqz v1, +003h
    goto +ch
    const-string v0, "ad_light"
    invoke-static v0, v3, Lmb/r;->o(...)Z
    move-result v3
    if-eqz v3, +003h
    goto +3h
    const-string v0, "ad_full"
    return-object v0
.end method
```

Patched bytecode:
```smali
.method public final map([Ljava/lang/String;)Ljava/lang/String;
    .registers 4
    const-string v0, "ad_free"
    return-object v0
.end method
```

**Risk**: MEDIUM — This tells the client the session is ad-free, which affects:
- SSAI beaconing (won't fire — benign)
- Ad skip module (won't activate — benign)
- Pause ad scheduling (won't trigger — benign)
- Ad overlay UI (won't render — benign)

**However**, the SSAI ads are **server-stitched into the manifest**. If the server still stitches ads based on the actual subscription, the video ad breaks will still play — they'll just lack client-side beaconing, countdown UI, and skip enforcement. The ads would appear as regular video content with no overlay UI.

### Ad Skip / Snapback — HIGH Patchability

#### Patch Target 4: `AdSkipModule.interveneIfSeekingForwardsOverUnwatchedAdBreak()` — No-Op

**Target**: `com.discovery.adtech.adskip.AdSkipModule.interveneIfSeekingForwardsOverUnwatchedAdBreak()`

Replace with no-op to allow seeking past ad breaks.

**Risk**: LOW — User can freely seek past unwatched ad breaks. Combined with Patch Target 3, the seek UI won't show ad break markers either.

#### Patch Target 5: `AdSkipModule.redirectToNewAdBreak()` — No-Op

**Target**: `com.discovery.adtech.adskip.AdSkipModule.redirectToNewAdBreak()`

Replace with no-op to prevent forced redirect to ad breaks.

**Risk**: LOW — Prevents snapback behavior.

### SSAI Beaconing — MEDIUM Patchability (Tracking Suppression)

#### Patch Target 6: `SsaiClientSideBeaconingModule` — Disable Beaconing

**Target**: Modify `shouldDispatch()` to always return `true` (inverted logic — `true` means "skip beaconing").

Or no-op the `SsaiClientSideBeaconRepository.sendBeacon()` method.

**Risk**: MEDIUM — Suppresses ad impression reporting. Large-scale suppression could trigger server-side fraud detection. Server may log missing impressions.

### Video Ad Breaks (SSAI) — LOW Patchability

The video ad break system is **very hard to patch** because:

1. **Ads are server-stitched** — The Bolt PIR returns a manifest URL with ads already inserted. The client receives a single continuous stream.
2. **No client-side ad selection** — Unlike Amazon's `AdBreakSelector` or Disney+'s SGAI pod fetching, HBO Max's SSAI means the ad content is indistinguishable from regular video at the media level.
3. **In-band timed metadata** — Ad break positions are signaled via HLS timed metadata embedded in the stream. Blocking metadata parsing would only remove the overlay UI, not the ad content.

**What IS possible:**
- Removing the ad overlay UI (countdown, badge, ad count) via `ServerSideAdOverlay` config
- Disabling seek enforcement (Patch Targets 4+5) to allow skipping past ad breaks
- Suppressing beaconing (Patch Target 6)

**What is NOT possible client-side:**
- Removing the actual ad video content from the stream (it's server-stitched)

### Ad Overlay UI — HIGH Patchability

#### Patch Target 7: `AdTechSdkBuilder.disableAdUi()`

Force-call `disableAdUi()` during SDK initialization, or patch `ServerSideAdOverlayConfig` to disable all UI elements (countdown, badge, count, WTA, learn more).

**Risk**: LOW — Ad content still plays but without overlay UI indicating it's an ad.

---

## Recommended Patch Strategy

### Approach A: Maximum Client-Side Impact (Recommended)

Combine multiple chokepoints for comprehensive ad mitigation:

| # | Target | Effect |
|---|--------|--------|
| 1 | `BoltAdStrategyMapper.map()` → always return `"ad_free"` | Client treats session as ad-free; disables ad modules |
| 2 | `PauseAds.getEnabled()` → return `false` | No pause ads |
| 3 | `AdSkipModule.interveneIfSeekingForwardsOverUnwatchedAdBreak()` → no-op | Free seeking past ad breaks |
| 4 | `AdSkipModule.redirectToNewAdBreak()` → no-op | No snapback to ad breaks |
| 5 | `ServerSideAdOverlayConfig` → disable all UI elements | No ad overlay UI |

**Limitation**: SSAI video ad content will still be in the stream. Users can seek past it (thanks to patches 3+4), but the ad video segments will remain if played through linearly.

### Approach B: Minimal (Pause Ads Only)

| # | Target | Effect |
|---|--------|--------|
| 1 | `PauseAds.getEnabled()` → return `false` | No pause ads |
| 2 | `PauseAdsInteractor.listen()` → no-op | Safety net |

Addresses only pause ads. SSAI video ad breaks are unaffected.

### Approach C: Server-Side (Requires MITM)

Intercept the Bolt PIR response and modify:
1. Set `ssaiInfo` to null/empty (no SSAI ad breaks)
2. Set `capabilities` to disable all ad features
3. Ensure `adStrategies` contains `"ad_free"`

**Effectiveness**: HIGH — Would eliminate all ads including SSAI.
**Practicality**: LOW — Requires always-on MITM proxy, custom CA cert, may break with certificate pinning updates.

---

## Fire OS Specific Components

### Amazon Integration

| Component | Purpose |
|-----------|---------|
| `AmazonSubscriptionEntitlementReceiver` | Amazon IAP subscription entitlement |
| `AmazonContentEntitlementReceiver` | Content-level entitlement |
| `com.amazon.device.iap.ResponseReceiver` | Amazon In-App Purchasing |
| `MaxDataIntegrationService` | Amazon content integration |
| `UpdateLauncherChannelsJobService` | Fire TV launcher channel updates |
| `BootReceiver` | Boot-complete handler |
| `LauncherProgramIntentListener` | TV program/watch-next management |
| `DynamicCapabilityReporter` | Alexa capability reporting |
| `AlexaDirectiveReceiver` | Alexa VSK voice control |
| `CapabilityRequestReceiver` | Amazon capability requests |

### Amazon Meta-data

| Key | Value |
|-----|-------|
| `CHANNEL` | `MaxFireTV` |
| `amazon.launcher.id` | `hbo_max_global` |
| `amazon.partner.id` | `HBO40_H` |
| `com.amazon.voice.supports_background_media_session` | `true` |
| Migration packages | `BluTV`, `HBOGo`, `BoltDPlus` |

### Fire OS Features

- `amazon.lwa.quicksignup.supported` — Login With Amazon quick signup
- `com.amazon.tv.developer.sdk.content` — optional library for content integration
- EPG integration (`READ_EPG_DATA`, `WRITE_EPG_DATA`)
- Alexa VSK (Video Skill Kit) for voice-controlled playback

---

## Network Analysis

### Domain Classification

#### Safely Blockable — Ad Serving & Tracking

| Domain | Purpose | Block Impact |
|--------|---------|-------------|
| `googleads.g.doubleclick.net` | Google Ad Manager | Ad beacon failures |
| `ad.doubleclick.net` | DoubleClick ad serving | Ad tracking failures |
| `pagead2.googlesyndication.com` | Google ad network | Ad pixel tracking fails |
| `www.googleadservices.com` | Google ad services | Attribution breaks |
| `imasdk.googleapis.com` | Google IMA SDK | Ad SDK initialization |
| `admob-gmats.uc.r.appspot.com` | Google AdMob | Ad telemetry |
| `events.brightline.tv` | Brightline interactive ads | Interactive ad tracking stops |
| `cdn-media.brightline.tv` | Brightline config CDN | Interactive ad config |
| `services.brightline.tv` | Brightline service | Interactive ad service |
| `api.permutive.app` | Permutive data platform | Audience targeting stops |
| `cdn.permutive.app` | Permutive CDN | Audience data |

#### Safely Blockable — Analytics & Measurement

| Domain | Purpose | Block Impact |
|--------|---------|-------------|
| `sb.scorecardresearch.com` | Comscore analytics | Content measurement stops |
| `segment-data.zqtk.net` | Comscore segment data | Audience segmentation stops |
| `sdk.iad-01.braze.com` | Braze push/messaging | Marketing push stops |
| `sondheim.braze.com` | Braze endpoint | Same |
| `api.mux.com` | Mux video analytics | QoE analytics stops |
| `inferred.litix.io` | Mux Litix analytics | Same |
| `register.mediamelon.com` | MediaMelon QoE | SSAI QoE monitoring stops |
| `prod-dtc-android-open-measurement.mercury.dnitv.com` | IAB Open Measurement | Viewability measurement stops |
| `dev-dtc-android-open-measurement.mercury.dnitv.com` | Open Measurement (dev) | Same |

#### Safely Blockable — Bot Detection & Error Tracking

| Domain | Purpose | Block Impact |
|--------|---------|-------------|
| `wbd-api.arkoselabs.com` | Arkose bot detection | Bot challenge may fail |
| `client-api.arkoselabs.com` | Arkose client API | Same |

**Note**: Blocking Arkose may cause login issues if bot detection is triggered.

#### DO NOT Block — HBO/WBD Infrastructure

| Domain | Purpose | Why Critical |
|--------|---------|-------------|
| `api.discomax.com` | Primary WBD API | **App login & all API calls** |
| `play.max.com` / `play.hbomax.com` | Deep link hosts | Content navigation |
| `firebaseremoteconfig.googleapis.com` | Feature flags | App configuration |
| `accounts.google.com` | OAuth | Authentication |

### Certificate Pinning Assessment

| Check | Result |
|-------|--------|
| SHA-256 pin hashes | Only bare `sha256/` prefix found — no actual pins |
| Custom `CertificatePinner` | No evidence of custom pinning |
| `network_security_config.xml` | Not analyzed (binary XML) |

**MITM proxy analysis is likely viable** on this version, though newer versions may add pinning.

### Play Integrity / SafetyNet

Found strings:
- `INTEGRITY_TOKEN_PROVIDER_INVALID`
- `The StandardIntegrityTokenProvider is invalid.`
- `gads:attestation_token:enabled`

These appear to be **Google Ads SDK attestation** (for ad fraud prevention), not app-level Play Integrity checks. A resigned APK should still function, though Google ad-related features may flag the modified signature.

---

## Comparison with Netflix and Disney+ Approaches

| Aspect | Netflix | Disney+ | HBO Max (Fire OS) |
|--------|---------|---------|-------------------|
| **Package** | `com.netflix.mediaclient` | `com.disney.disneyplus` | `com.hbo.hbonow` |
| **Ad insertion** | SSAI (SCTE-35 markers) | SGAI (client-fetched pods) | SSAI (AdSparx in-band metadata) |
| **Pause ads** | Client-driven (feature flag gate) | N/A (interstitials only) | Client-driven (static + dynamic modes) |
| **Client-side ad gate** | `PauseAdsFeatureFlagHelper.e()Z` | `SessionFeatures.noAds` | `BoltAdStrategyMapper.map()` |
| **Subscription check** | Hendrix A/B config flags | GraphQL `SessionFeatures` | Server PIR `adStrategies[]` |
| **Ad skip enforcement** | N/A (SSAI) | Seek enforcement in `zx/n` | `AdSkipModule` snapback |
| **Obfuscation** | Heavy (single-letter classes) | Mixed (v26: named SGAI) | **Minimal** (named packages) |
| **Fire OS variant** | Same APK (unified) | Separate APK | **Separate APK** |
| **Root required** | No | No | No |
| **Video ad patchability** | Low (SSAI) | **High** (SGAI pod fetch) | Low (SSAI) |
| **Pause ad patchability** | **High** (feature flag) | N/A | **High** (enabled flag) |
| **Seek past ads** | N/A | Yes (suppress scheduling) | **Yes** (no-op AdSkipModule) |
| **Ad server** | Netflix Hendrix | DMP SGAI + DoubleClick | **FreeWheel + AdSparx** |
| **SSAI CDN** | Netflix CDN | N/A (SGAI uses separate URLs) | **Uplynk/Verizon** |
| **Patch difficulty** | Easy (pause ads) / Hard (SSAI) | **Easy** (boolean flag) | Easy (pause ads, seek) / Hard (SSAI) |

### Key Difference: SSAI vs SGAI

HBO Max shares Netflix's fundamental challenge: **SSAI ads are server-stitched into the video stream**, making them impossible to remove client-side. Disney+'s SGAI approach fetches ad pods separately, making them trivially blockable.

However, HBO Max offers one advantage over Netflix: the **AdSkipModule can be disabled**, allowing users to **seek past** SSAI ad breaks. Netflix's SSAI system doesn't have an equivalent client-side seek enforcement module — the SCTE-35 markers handle state management differently.

---

## Points for Deeper Investigation

### Should Investigate

1. **Bolt PIR response structure** — MITM the PIR request to `api.discomax.com` to see exact `adStrategies`, `capabilities`, and `ssaiInfo` payload structure. This would reveal whether setting `adStrategies=["ad_free"]` client-side actually prevents the server from stitching ads.

2. **Uplynk ping module** — `pingUplynkLive` and `pingUplynkVod` methods exist. Understanding the Uplynk SSAI architecture could reveal whether ad segments use different CDN paths that could be blocked at the network level.

3. **`DynamicAdFetcher` endpoint** — The dynamic pause ad fetcher (`com.wbd.gmss.DynamicAdFetcher`) makes a network call. Identifying and blocking this endpoint would disable dynamic pause ads at the network level.

4. **FreeWheel config and beacon URL template** — `BuildParameterizedUrlTemplateKt` uses `VIDEO_VIEW_TEMPLATE` with `BeaconUrlParameters`. The FreeWheel beacon URL pattern could be blocked at the network level.

5. **Server-side enforcement of `ad_free` strategy** — Does setting `ad_free` client-side cause the server to stop stitching SSAI ads in subsequent PIR responses? Or does the server independently determine the ad strategy?

### Nice to Investigate

6. **Arkose bot detection interaction** — Does a resigned APK trigger Arkose challenges more frequently?

7. **Google PAL nonce** — The `googlePALNonce` sent in PIR requests may be tied to device attestation. A modified APK may produce invalid nonces.

8. **Content delivery difference between ad tiers** — Do ad-free and ad-supported tiers receive different CDN manifests (different `manifest` URLs in PIR response)?

---

## Tools & Methodology

- **androguard 4.1.3** — DEX parsing, class/method/field enumeration, bytecode disassembly, string extraction
- **Python 3** — Analysis scripting
- **unzip** — APK extraction

## Files Analyzed

- `com.hbo.hbonow-fireos.apk` (45MB, Fire OS variant)
- 6 DEX files totaling ~32MB
- 2,063 ad-related classes identified across packages:
  - `com.discovery.adtech.*` — Core AdTech SDK
  - `com.wbd.adtech.*` — WBD ad UI and instrumentation
  - `com.wbd.beam.*` — Beam app framework and telemetry
  - `com.discovery.player.*` — Player ad integration
  - `tv.youi.videolib.adtech.*` — You.i Engine bridge layer
  - `com.wbd.player.*` — Player overlay components
  - `com.wbd.gmss.*` — GMSS ad models
