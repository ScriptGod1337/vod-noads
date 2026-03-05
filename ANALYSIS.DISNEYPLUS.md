# Disney+ Android APK Ad System Analysis

## APK Metadata

| Field | v2.16.2-rc2 (2023) | v26.1.2+rc2 (2026-02-23) |
|-------|---------------------|--------------------------|
| Package | `com.disney.disneyplus` | `com.disney.disneyplus` |
| Version code | 2301311 | 1771868340 |
| Target SDK | 33 (Android 13) | **36 (Android 16)** |
| Min SDK | 21 (Android 5.0) | **23 (Android 6.0)** |
| DEX files | 5 (42,225 classes) | **4 (30,970 classes)** |
| Format | Single APK (32MB) | **XAPK split bundle (38MB)** |
| SDK | DSS SDK (Disney Streaming Services) | DSS SDK + DMP SGAI module |

---

## Executive Summary

**YES — Disney+ Basic (with ads) has significant client-side ad orchestration logic.** The app uses **Server-Guided Ad Insertion (SGAI)** as its primary ad delivery mechanism, with SSAI as a secondary strategy. The ad system has **multiple client-side chokepoints** that could theoretically be patched.

The ad decision chain is:

```
GraphQL Session → SessionFeatures.noAds (boolean) → config["playback"]["adsTierRestricted"]
  → gm/h.t() returns areAdsEnabled = !adsTierRestricted
  → If true: schedule interstitials (ad breaks), fetch ad pods, play ads
  → If false: pristine playback, no ad infrastructure activated
```

**Three viable patch strategies exist**, ranging from trivial (force `noAds=true`) to surgical (suppress interstitial scheduling).

---

## Ad System Architecture

### Layer 1: Subscription Tier Gate (Session Features)

The server sends a GraphQL session response containing `SessionFeatures`:

```kotlin
// com.dss.sdk.orchestration.common.SessionFeatures
data class SessionFeatures(
    val coPlay: Boolean,    // GroupWatch feature
    val download: Boolean,  // Offline download feature
    val noAds: Boolean      // Ad-free tier flag
)
```

This is parsed from the GraphQL `sessionGraphFragment`:
```graphql
fragment sessionGraphFragment on Session {
  sessionId
  device { id }
  entitlements
  features {
    coPlay
    download
    noAds        # ← THIS IS THE KEY FIELD
  }
}
```

The `noAds` field is stored in `SessionState.ActiveSession.SessionFeatures.c` (field `c`, boolean).

The constructor also computes `field d = !noAds` (XOR with 1) — an inverted "adsEnabled" convenience field.

### Layer 2: Configuration-Based Ad Decision

The `gm/h` class (implements `gm/g` interface) is the central configuration provider:

| Method | Logic | Purpose |
|--------|-------|---------|
| `N()` | Reads `config["playback"]["adsTierRestricted"]` → boolean (default: `true`) | Returns true if user is on ad tier (restricted = has ads) |
| `t()` | `return !N()` — XOR with 1 | **`areAdsEnabled`** — true if ads should play |
| `f()` | If `R()` → `SSAI`, else → `NONE` | Global insertion strategy |
| `e(playable)` | Per-item lookup from a map → `AssetInsertionStrategy.valueOf()` | Per-content insertion strategy |
| `R()` | Reads `config["playback"]["enableSSAIForOfflineContent"]` | SSAI toggle for offline |

**Key insight**: `adsTierRestricted` defaults to `true` if the config key is missing, meaning the app **assumes the user has ads** unless explicitly told otherwise. The `noAds` flag from the session is what overrides this.

### Layer 3: Ad Insertion Strategies

`AssetInsertionStrategy` enum (4 values):

| Strategy | Description |
|----------|-------------|
| `NONE` | No ads — pristine stream |
| `SSAI` | Server-Side Ad Insertion — ads stitched into stream |
| `SGAI` | **Server-Guided Ad Insertion** — server provides ad pod URLs, client fetches and plays separately |
| `ADPARTNER` | Third-party ad partner integration |

`AdInsertionType` (QoE reporting):

| Type | Description |
|------|-------------|
| `ssai` | Server-side inserted |
| `sgai` | Server-guided (client-fetched) |
| `none` | No ads |

### Layer 4: MEL (Media Experience Layer) Ad Pod System

The SGAI system uses a pod-based architecture:

```
Server sends insertion points → Client resolves pods → Fetches ad content → Plays as interstitials
```

Key classes in `com.dss.mel.ads`:

| Class | Role |
|-------|------|
| `PodRequest` | Request to ad server: `interstitialType` (string), `midrollIndex` (int), `contentPositionMs` (long) |
| `PodResponse` | Response containing list of `RawPod` objects |
| `RawPod` | Ad pod: `plannedLength` (long), list of `Ad` objects, list of `MelOpenMeasurement` |
| `Ad` | Individual ad: `sequence` (int), `Creative`, `adId` (string) |
| `Creative` | Ad creative: `id` (string), `Video`, tracking list |
| `Video` | Video asset: `mimeType`, `mediaUrl`, `duration` (long), tracking, measurement |
| `Tracking` | Beacon tracking: `event` (string), `urls` list |

### Layer 5: Interstitial System (Ad Break Playback)

Ad breaks are implemented as "interstitials" — overlay playback sessions within the content player:

| Class | Role |
|-------|------|
| `zx/p` | **Main interstitial orchestrator** — schedules, resolves, and manages interstitial lifecycle |
| `zx/m` | Pre-roll / bumper handler (`handleBumperOrPreRoll`) |
| `zx/n` | Seek handling — enforces interstitials on seek (forward/backward) |
| `zx/f` | Interstitial state tracking |
| `y2/f0` | Pre-roll resolver (`onResolvingPreRoll() setting state to loadingAdPod`) |
| `y2/r0` | Ad group skip handler (`skipAdGroup() adGroupIndex:`) |
| `p4/d` | Interstitial playback (`playInterstitial()`) |
| `p4/f` | Interstitial skip (`skipInterstitial() prepareForBeaconing:`) |

The flow:
```
1. Content starts → zx/m checks for pre-roll (handleBumperOrPreRoll)
2. SGAI insertion points define mid-roll positions
3. zx/p schedules interstitials at insertion points
4. When position is reached → zx/p resolves interstitial → fetches ad pod
5. p4/d plays interstitial (separate ExoPlayer instance via exo_ad_overlay)
6. Seek enforcement: zx/n prevents seeking past unskippable interstitials
7. Beaconing: tracking URLs fired on start, quartile, complete
```

### Layer 6: SGAI VOD Insertion Points

Server provides structured insertion points via `SgaiVodInsertionPoint`:

```kotlin
data class SgaiVodInsertionPoint(
    val id: String,           // unique ID
    val offset: Int,          // position in content (ms)
    val placement: InsertionPointPlacement,  // PREROLL, MIDROLL, POSTROLL
    val content: List<SgaiVodInsertionPointContent>  // what to insert
)

// Content types:
data class SgaiVodAdServiceInsertionPointContent(
    val midrollIndex: Int?,
    val type: InsertionPointContentType,     // AD, BUMPER, etc.
    val subType: InsertionPointContentSubtype
)

data class SgaiVodAuxiliaryInsertionPointContent(
    val type: InsertionPointContentType,
    val subType: InsertionPointContentSubtype,
    val path: String,        // URL for auxiliary content (bumpers)
    val duration: Int?
)
```

### Layer 7: Ad UI Components

| Component | Class | Purpose |
|-----------|-------|---------|
| Ad Overlay | ExoPlayer `exo_ad_overlay` | Dedicated overlay for ad video playback |
| Ad Badge | `MessagingView.getAdBadge()` → `TextView` | "Ad" label during ad playback |
| Messaging View | `com.bamtechmedia.dominguez.player.ui.ads.MessagingView` | Ad-break messaging UI (countdown, info) |
| Interstitial Fragment | `PlaybackInterstitialFragment` | Full-screen interstitial container |
| Countdown Timer | `PlaybackInterstitialViewModel.countdownTimer()` | Countdown before ad can be dismissed |
| Skip Button | Cast SDK `cast_expanded_controller_skip_ad_label` | Skip ad on Chromecast |

### Layer 8: QoE (Quality of Experience) Telemetry

Comprehensive ad telemetry via `com.disneystreaming.androidmediaplugin.qoe.ads`:

| Event | Class | Data |
|-------|-------|------|
| Ad Pod Requested | `AdPodRequestedEvent` | placement, timing |
| Ad Pod Fetched | `AdPodFetchedEvent` | placement, data, server request |
| Ad Playback Started | `AdPlaybackStartedEvent` | placement, pod data, slot data, playhead position |
| Ad Playback Ended | `AdPlaybackEndedEvent` | placement, pod data, slot data, ad data, subtitle data |

Supporting data models: `AdMetadata`, `AdSlotData`, `AdAudioData`, `AdVideoData`, `AdSubtitleData`, `AdErrorData`, `AdServerRequest`, `AdNetworkError`, `AdStartupData`.

---

## Patch Analysis: Chokepoints

### Chokepoint 1: `SessionFeatures.noAds` (HIGHEST IMPACT, SIMPLEST)

**Target**: `SessionState$ActiveSession$SessionFeatures.<init>(Z Z Z)V`

**Current behavior**:
```smali
iput-boolean v3, v0, ...->c Z    # c = noAds (from server)
xor-int/lit8 v1, v3, 1
iput-boolean v1, v0, ...->d Z    # d = !noAds = adsEnabled
```

**Patch**: Force `c = true` (noAds) and `d = false` (adsDisabled):
```smali
const/4 v3, 1                     # force noAds = true
iput-boolean v3, v0, ...->c Z
const/4 v1, 0                     # force adsEnabled = false
iput-boolean v1, v0, ...->d Z
```

**Risk**: LOW — This mimics a premium subscription. Server may still accept media requests from "noAds" sessions. The `noAds` flag affects UI decisions (download availability, ad tier messaging) and the ad pipeline activation.

**Side effects**: User will see premium-tier UI elements (download buttons, no "ads" labels). Server-side enforcement is the main risk — if the server checks subscription status before serving content, this alone won't work.

### Chokepoint 2: `gm/h.t()` — `areAdsEnabled` (MOST DIRECT)

**Target**: `gm/h.t()Z`

**Current behavior**:
```smali
invoke-virtual v1, Lgm/h;->N()Z   # N() = adsTierRestricted (from config)
move-result v0
xor-int/lit8 v0, v0, 1             # !adsTierRestricted
return v0
```

**Patch**: Always return false (ads not enabled):
```smali
const/4 v0, 0
return v0
```

**Risk**: LOW — This is checked by `MelPcsLifecycleObserver` which initializes the entire ad playback system. If `t()` returns false, the MEL player configuration skips ad initialization entirely.

### Chokepoint 3: `gm/h.f()` / `gm/h.e()` — Force `AssetInsertionStrategy.NONE`

**Target**: `gm/h.f()` and `gm/h.e()`

**Current behavior** (f):
```smali
invoke-virtual v1, Lgm/h;->R()Z
move-result v0
if-eqz v0, +005h
sget-object v0, ...->SSAI          # if R() true: SSAI
goto +3h
sget-object v0, ...->NONE          # if R() false: NONE
return-object v0
```

**Patch**: Always return NONE:
```smali
sget-object v0, Lcom/dss/sdk/media/AssetInsertionStrategy;->NONE
return-object v0
```

**Risk**: MEDIUM — Affects playback scenario construction. Server expects SSAI/SGAI scenario string for ad-tier users; sending NONE may cause playback failures if the server enforces it.

### Chokepoint 4: Interstitial Scheduling Suppression

**Target**: `zx/p.c0()` (scheduleInterstitial) — make it a no-op

**Patch**: Return immediately without scheduling any interstitials.

**Risk**: LOW — Content plays through without interruptions. SGAI ad pods are never fetched. Tracking beacons never fire (Disney won't know ads were skipped).

### Chokepoint 5: Pre-roll Suppression

**Target**: `zx/m.p()` (handleBumperOrPreRoll) — skip all pre-roll logic

**Risk**: LOW — No pre-roll ads play. Content starts immediately.

---

## Recommended Patch Strategy

### Approach A: Belt-and-Suspenders (Recommended)

Combine Chokepoints 1 + 2 + 4:

1. **Force `SessionFeatures.noAds = true`** — Tells the entire app "this is a premium session"
2. **Force `gm/h.t()` to return false** — Disables ad initialization at MEL player level
3. **No-op `zx/p.c0()`** — Safety net: even if interstitials somehow get scheduled, they won't execute

This three-layer approach ensures no single server-side check can re-enable ads.

### Approach B: Minimal (Higher Risk)

Just Chokepoint 2:

1. **Force `gm/h.t()` to return false** — Single point of control

Simpler but vulnerable to code paths that don't check `areAdsEnabled`.

---

## Key Differences from Amazon Fire TV Analysis

| Aspect | Amazon Fire TV | Disney+ (v2.16.2) |
|--------|---------------|-------------------|
| Ad delivery | SSAI only | SGAI primary + SSAI secondary |
| Ad format | Stream-stitched periods | Separate ad pod playback via interstitials |
| Chokepoint type | FSM state machine (`AdBreakSelector`) | Configuration flag + interstitial scheduling |
| Subscription gate | N/A (system app) | `SessionFeatures.noAds` from GraphQL |
| Ad content source | Same CDN as content (inseparable) | Separate ad pod URLs (separable!) |
| Root required | Yes (system app) | **No** (user app, can sideload) |
| Network blocking | Impossible (shared CDN) | **Partially viable** (ad pods from different URLs) |
| Patch complexity | Medium (FSM surgery) | **Low** (boolean flag flip) |

**Critical advantage**: Disney+ uses SGAI where ad pods are fetched from separate URLs, unlike Amazon's SSAI where ads are stitched into the content CDN. This means:
1. Network-level ad blocking is potentially viable (block ad pod URLs)
2. Client-side patches are simpler (prevent pod fetch rather than surgically modify stream processing)

---

## Network-Level Ad Blocking Analysis

### Domain Classification

All 72+ domains extracted from the APK, classified by blockability:

#### Safely Blockable — Ad Serving (3 domains)

| Domain | Purpose | Block Impact |
|--------|---------|-------------|
| `pubads.g.doubleclick.net` | Google DFP/DoubleClick VAST/VMAP ad server | Ad pods fail to load; no ads play |
| `pagead2.googlesyndication.com` | Google Ad Network pixel tracking | Ad impression tracking fails |
| `www.googleadservices.com` | Deep link conversion tracking | Ad attribution breaks |

These are the **only hardcoded ad server domains** in the APK. However, the actual ad pod URLs used in production are **dynamically provided by the server** via `getPodUrl` in the `MelAdsConfiguration` — they are NOT hardcoded. This means the production ad pod server domain may differ from these test URLs.

#### Safely Blockable — Analytics & Tracking (9 domains)

| Domain | Purpose | Block Impact |
|--------|---------|-------------|
| `cws.conviva.com` | Conviva video QoE analytics | Ad/content telemetry stops |
| `pings.conviva.com` | Conviva heartbeat pings | Session monitoring stops |
| `cws-ipv4.conviva.com` | Conviva IPv4 fallback | Same as above |
| `cws-ipv6.conviva.com` | Conviva IPv6 fallback | Same as above |
| `pings-ipv4.conviva.com` | Conviva IPv4 pings | Same as above |
| `pings-ipv6.conviva.com` | Conviva IPv6 pings | Same as above |
| `hal.testandtarget.omniture.com` | Adobe Omniture personalization | A/B testing stops |
| `app-measurement.com` | Firebase/Google Analytics | App analytics stops |
| `sdk.iad-01.braze.com` | Braze push notification SDK | Marketing push stops |

Blocking these has **no effect on playback or app functionality**. It prevents Disney from collecting QoE metrics and ad impression data.

#### Safely Blockable — Error Tracking (1 domain)

| Domain | Purpose | Block Impact |
|--------|---------|-------------|
| `disney.my.sentry.io` | Sentry crash reporting | Crash reports not sent |

#### DO NOT Block — Disney Infrastructure (Critical)

| Domain | Purpose | Why Critical |
|--------|---------|-------------|
| `global.edge.bamgrid.com` | Primary API gateway | **App login & all API calls** |
| `pcs.bamgrid.com` | Playback Configuration Service | **Content playback URLs** (also delivers ad config) |
| `lw.bamgrid.com` | Lightweight API | Session management |
| `bam-sdk-configs.bamgrid.com` | SDK configuration | App initialization |
| `prod-ripcut-delivery.disney-plus.net` | Content CDN (images, thumbnails) | Visual content delivery |
| `d2zihajmogu5jn.cloudfront.net` | CloudFront CDN | Content assets |
| `registerdisney.go.com` | Registration service | Account management |
| `disneyplus.com` / `www.disneyplus.com` | Main web portal | Deep links, OAuth |
| `appconfigs.disney-plus.net` | App configuration | Feature flags |

**Blocking any of these will break the app.**

### Pod Fetch Architecture — The Key Finding

The SGAI ad system uses a two-phase architecture:

```
Phase 1: PCS Config Fetch (pcs.bamgrid.com)
  └─ Returns MelAdsConfiguration containing:
       ├─ getPodUrl: "https://???.bamgrid.com/..."  ← DYNAMIC pod endpoint
       ├─ beaconUrl: "https://???.bamgrid.com/..."  ← DYNAMIC beacon endpoint
       ├─ podResolveConnectionTimeout: int
       ├─ podResolveResponseTimeout: int
       ├─ podResolveLeadTime: int
       ├─ beaconConnectionTimeout: int
       ├─ beaconResponseTimeout: int
       └─ enabled: boolean

Phase 2: Pod Resolve (getPodUrl endpoint)
  └─ Client sends PodRequest {interstitialType, midrollIndex, contentPositionMs}
  └─ Server returns PodResponse {list of RawPod → list of Ad → Creative → Video}
  └─ Video.mediaUrl → actual ad video stream URL (likely CDN-hosted)

Phase 3: Beacon Reporting (beaconUrl endpoint)
  └─ Client fires tracking events: impression, quartiles, complete
```

**Critical insight**: The `getPodUrl` and `beaconUrl` are **not hardcoded** — they come from the PCS response. This means:

1. We cannot pre-determine which domain serves ad pods without MITM analysis
2. The pod server domain might be the **same** as the content CDN (e.g., `*.bamgrid.com`), making domain-level blocking impossible
3. The pod server domain might also change between app versions or A/B test cohorts

### Certificate Pinning Assessment

**Finding: Minimal certificate pinning detected.**

| Check | Result |
|-------|--------|
| `network_security_config.xml` | **Not present** in APK manifest |
| SHA-256 pin hashes in strings | Only empty `sha256/` found (no actual pins) |
| OkHttp `CertificatePinner` usage | No evidence of custom pinning configuration |
| TrustManager overrides | Standard Android default trust |

This means **MITM proxy analysis IS viable** on this version:
- Tools like mitmproxy, Charles Proxy, or Burp Suite can intercept HTTPS traffic
- Install a custom CA certificate on the Android device
- Intercept the PCS response to discover the actual `getPodUrl` and `beaconUrl` domains
- Potentially modify the PCS response to set `enabled: false` or blank out `getPodUrl`

**Note**: Newer versions (post-2023) likely added certificate pinning or Play Integrity checks.

### Network Blocking Strategies

#### Strategy 1: DNS/Firewall Blocking (Partial — LOW Effort)

Block known ad-adjacent domains at the network level (Pi-hole, AdGuard, firewall rules):

```
# Definitely safe to block (tracking only):
pubads.g.doubleclick.net
pagead2.googlesyndication.com
www.googleadservices.com
cws.conviva.com
pings.conviva.com
cws-ipv4.conviva.com
cws-ipv6.conviva.com
pings-ipv4.conviva.com
pings-ipv6.conviva.com
app-measurement.com
sdk.iad-01.braze.com
sondheim.braze.com
hal.testandtarget.omniture.com
disney.my.sentry.io
```

**Effectiveness**: PARTIAL — Blocks tracking beacons and test ad URLs, but **will NOT block production SGAI ad pods** because the pod server URL is dynamically assigned and likely uses a `*.bamgrid.com` subdomain shared with content infrastructure.

**Risk**: NONE — These domains are not required for content playback.

#### Strategy 2: MITM Proxy — Modify PCS Response (HIGH Effort, HIGH Impact)

Use a MITM proxy to intercept the PCS configuration response from `pcs.bamgrid.com` and modify the ad configuration:

```json
// Original MelAdsConfiguration:
{
  "vodConfig": {
    "enabled": true,
    "getPodUrl": "https://ads.bamgrid.com/v1/pods",
    "beaconUrl": "https://ads.bamgrid.com/v1/beacons",
    "podResolveLeadTime": 5000,
    ...
  }
}

// Modified (ad-free):
{
  "vodConfig": {
    "enabled": false,
    "getPodUrl": "",
    "beaconUrl": "",
    ...
  }
}
```

**Effectiveness**: HIGH — The app's `MelAdsConfiguration` controls the entire SGAI pipeline. Setting `enabled: false` or blanking `getPodUrl` prevents pod fetches entirely.

**Risk**: MEDIUM — Requires custom CA cert on device. May trigger server-side validation in newer versions. Not practical for everyday use without always-on proxy.

#### Strategy 3: MITM Proxy — Block Pod Fetch Requests (MEDIUM Effort)

After using MITM to discover the actual pod endpoint URL pattern, block or return empty responses for those specific requests:

```
# Intercept rule (mitmproxy example):
if flow.request.url.contains("/v1/pods") or flow.request.url.contains("/ad/"):
    flow.response = http.Response.make(200, b'{"pods":[]}', {"Content-Type": "application/json"})
```

**Effectiveness**: HIGH — Ad pods never load; the interstitial system receives empty responses and skips ad breaks.

**Risk**: LOW — Content requests are unaffected. The app handles pod fetch failures gracefully (logs `an error occurred while loading ad-pod` and continues).

#### Strategy 4: Local DNS + Proxy Combination (MEDIUM Effort, Best Practical)

Combine DNS blocking with a lightweight local proxy:

1. **DNS block** all tracking domains (Strategy 1 list)
2. **MITM proxy** only `pcs.bamgrid.com` to discover pod URL pattern
3. **Add pod URL domain** to DNS blocklist once discovered
4. If pod domain = content domain, use **URL-pattern proxy** (Strategy 3) instead

**Effectiveness**: HIGH — Comprehensive ad suppression with minimal ongoing maintenance.

### Beacon Suppression Analysis

The beacon system (`cy/b` class) fires HTTP requests to report ad events:

| Event | When Fired | Effect of Blocking |
|-------|-----------|-------------------|
| `impression` | Ad starts playing | Disney doesn't know ad played |
| `firstQuartile` | 25% of ad watched | Quartile tracking lost |
| `midpoint` | 50% of ad watched | Same |
| `thirdQuartile` | 75% of ad watched | Same |
| `complete` | Ad finished | Completion tracking lost |
| `error` | Ad playback error | Error reporting lost |

**Key observation**: Beacon failures are handled silently — the app does not enforce beacon success as a condition for content playback. Blocking beacons has **no user-visible effect**.

However, large-scale beacon suppression could eventually trigger server-side fraud detection, flagging the account for not reporting expected ad impressions.

### Comparison: Network Blocking vs. Client-Side Patching

| Factor | Network Blocking | Client-Side Patching |
|--------|-----------------|---------------------|
| **Effort** | Low (DNS) to Medium (MITM) | Low (smali edit) |
| **Effectiveness** | Partial (DNS) to High (MITM) | **Complete** |
| **Persistence** | Survives app updates | **Breaks on app update** |
| **Detectability** | Low (DNS), Medium (MITM) | Low (no network anomalies) |
| **Root required** | No | No (sideload patched APK) |
| **Device scope** | Can protect all devices on network | Per-device patched APK |
| **Best for** | Quick blocking without APK modification | Complete, reliable ad removal |

### Recommended Combined Approach

For maximum effectiveness with minimum risk:

1. **Primary**: Client-side patch (Chokepoints 1+2+4 from Patch Analysis above)
2. **Secondary**: DNS blocklist for tracking domains (prevents telemetry)
3. **Discovery**: One-time MITM session to identify production pod URLs for the blocklist

This layered approach ensures:
- Client patch prevents ads from being requested at all
- DNS blocking prevents tracking beacons from reporting ad skip behavior
- No single point of failure

---

## v26.1.2 (2026) Delta Analysis

The latest Disney+ APK (v26.1.2+rc2, February 2026) was analyzed as an XAPK split bundle. Key changes from v2.16.2:

### Architecture Changes

| Aspect | v2.16.2 (2023) | v26.1.2 (2026) |
|--------|---------------|----------------|
| SGAI package | `com.dss.mel.ads` (obfuscated) | **`com.disney.dmp.sgai`** (named!) |
| Interstitial controller | `zx/p`, `zx/m`, `zx/n` (obfuscated) | **`SgaiInterstitialController`** (named methods) |
| Class count | 42,225 | 30,970 (significant refactoring) |
| DEX files | 5 | 4 |
| DoubleClick test URLs | 5 hardcoded VAST/VMAP URLs | **Removed** (cleaned for production) |
| Consent management | None | **OneTrust SDK** (GDPR/CCPA) |
| Live ads | Basic SGAI | **LivePodRequest, ProgramRolloverRequest** |
| Interactive ads | Not present | **`interactiveAdsEnabled`** flag |
| Ad partner support | Basic `ADPARTNER` enum | **`preferredAdPartner`** field |

### Key Findings — What Survived

The core ad decision chain is **structurally identical**:

1. **`SessionFeatures.noAds`** — Still present (`getNoAds`, `, noAds=`)
2. **`AdsSubscriptionType`** — Still `ADS_REQUIRED` / `NO_ADS_REQUIRED`
3. **`AssetInsertionStrategy`** — Still `NONE`, `SSAI`, `SGAI`, `ADPARTNER`
4. **`MelAdsConfiguration`** — Still delivered via PCS with `VodConfig`, `LiveConfig`
5. **`getPodUrl`**, **`beaconUrl`** — Still dynamically configured
6. **`podResolveConnectionTimeout/LeadTime/ResponseTimeout`** — Same config fields
7. **`enableSGAI`** — Feature flag still present

### Key Findings — What Changed

1. **`adsTierRestricted` config key NOT found** — The `gm/h.t()` config-based ad gate may have been refactored. The decision chain likely now goes:
   ```
   SessionFeatures.noAds → AdsSubscriptionType → AssetInsertionStrategy
   ```
   This is actually simpler — fewer indirections.

2. **Named SGAI classes** — De-obfuscation makes patching easier:
   - `SgaiInterstitialController.scheduleInterstitial()` — direct target
   - `SgaiInterstitialController.playInterstitial()` — direct target
   - `SgaiInterstitialController.scheduleBreak()` — direct target
   - `SgaiInterstitialController.onResolvingPreRoll()` — pre-roll handler

3. **No CertificatePinner detected** — Still no explicit certificate pinning. `sha256/` is empty. MITM remains viable.

4. **OneTrust consent SDK added** — New domains: `mobile-data.onetrust.io`, `consent-api.onetrust.com`, `geolocation.1trust.app`. These are blockable without affecting playback.

5. **New internal GitHub schema references** — `github.bamtech.co/schema-registry/` URLs reveal internal API schema evolution (QoE, client signals, SDK events). Not user-facing but confirms active development of the telemetry system.

6. **`client-sdk-configs.bamgrid.com`** replaces `bam-sdk-configs.bamgrid.com` — SDK config domain renamed.

### Updated Patch Targets for v26

Since class names are now readable, patches are more maintainable:

| Chokepoint | v2.16.2 Target | v26.1.2 Target |
|------------|---------------|----------------|
| Session flag | `SessionState$ActiveSession$SessionFeatures` field `c` | `SessionFeatures.noAds` (same, named) |
| Ad gate | `gm/h.t()` (areAdsEnabled) | **Needs bytecode tracing** — `adsTierRestricted` removed |
| Insertion strategy | `gm/h.f()` / `gm/h.e()` | `AssetInsertionStrategy` decision (named) |
| Interstitial scheduling | `zx/p.c0()` | **`SgaiInterstitialController.scheduleInterstitial()`** |
| Pre-roll | `zx/m.p()` | **`SgaiInterstitialController.onResolvingPreRoll()`** |
| Pod fetch | `cy/i` → `cy/a` | `com.disney.dmp.sgai.service.PodRequest` pipeline |

### Updated Network Blocking — Additional Domains to Block

New blockable domains in v26 (safe to block):

```
# OneTrust consent/tracking:
mobile-data.onetrust.io
consent-api.onetrust.com
geolocation.1trust.app

# Same as before (still present):
cws.conviva.com / pings.conviva.com (+ IPv4/IPv6 variants)
app-measurement.com
sdk.iad-01.braze.com / sondheim.braze.com
disney.my.sentry.io
pagead2.googlesyndication.com
www.googleadservices.com
```

**Note**: `pubads.g.doubleclick.net` VAST/VMAP test URLs were **removed** from v26 — DoubleClick may still be used in production but is no longer hardcoded.

### Conclusion for v26

The ad system architecture is **remarkably stable** between 2023 and 2026. The same fundamental approach applies:

1. **Primary patch**: Force `SessionFeatures.noAds = true` (still the simplest, most effective)
2. **Secondary**: No-op `SgaiInterstitialController.scheduleInterstitial()` (now named — easier to find and patch)
3. **Network**: Block tracking domains + discover pod URL via MITM

The de-obfuscation of SGAI classes in v26 actually makes patching **easier** than v2.16.2. The main uncertainty is the `adsTierRestricted` removal — the ad-enable decision may have moved entirely to the server-side `AdsSubscriptionType` sent in the session, making the `noAds` flag patch even more critical as the primary chokepoint.

---

## Areas Requiring Deeper Investigation

### 1. Server-Side Enforcement
- Does the server validate subscription status before honoring `noAds` requests?
- Can a patched client with `noAds=true` still get content URLs?
- Does the server reject playback scenarios without `~sgai`/`~ssai` suffix for ad-tier accounts?

### 2. Certificate Pinning — RESOLVED
- **No explicit certificate pinning found** in v2.16.2-rc2
- No `network_security_config.xml`, no SHA-256 pin hashes, no custom `CertificatePinner`
- MITM proxy analysis IS viable on this version
- Newer versions likely added pinning — verify before attempting on newer APKs

### 3. Ad Pod Server URLs — PARTIALLY RESOLVED
- Pod URLs are **dynamically provided** via `getPodUrl` field in `MelAdsConfiguration` from PCS
- The pod server domain is NOT hardcoded in the APK — requires MITM intercept to discover
- Likely `*.bamgrid.com` subdomain — may share CDN with content (blocking uncertain)
- The app has 5 hardcoded DoubleClick test/sample VAST URLs (non-production)
- One-time MITM session recommended to discover production pod URLs

### 4. Newer Versions — RESOLVED (v26.1.2 analyzed)
- v26.1.2 (Feb 2026) analyzed — ad architecture is structurally identical
- **No Play Integrity / SafetyNet attestation found** (only generic "Integrity check failed" for Room DB)
- **No additional certificate pinning** added
- SGAI classes are now **de-obfuscated** (easier to patch!)
- `adsTierRestricted` config key removed — decision chain simplified
- New: OneTrust consent, interactive ads, live pod requests, program rollover
- Remaining concern: server-side enforcement may be stricter in 2026

### 5. VAST/VMAP Integration
- The APK contains Google DoubleClick VAST/VMAP test URLs
- The Cast SDK uses `vastAdsRequest`/`vmapAdsRequest` for Chromecast ads
- This suggests a separate ad pipeline for Cast that may need separate patching

---

## Tools & Methodology

- **APKM decryption**: Custom Python decryptor (ChaCha20-Poly1305 SecretStream, Argon2id)
- **Static analysis**: Androguard 4.1.3 (Python)
- **DEX analysis**: Bytecode inspection across 5 DEX files (42,225 classes)
- **String analysis**: Keyword search yielding 405 ad-related strings
- **Call graph tracing**: Manual cross-reference from session features → config → ad scheduling
