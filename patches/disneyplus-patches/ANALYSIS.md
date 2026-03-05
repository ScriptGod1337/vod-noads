# Disney+ Ad System — Reverse Engineering Analysis

Analysis of Disney+ v26.1.2 APK ad delivery architecture and patch rationale.

## Ad System Architecture

Disney+ uses a multi-layered client-side ad system spanning two SDK packages:

```
┌─────────────────────────────────────────────────────┐
│                  Disney+ App UI                      │
│               (playback surface)                     │
├─────────────────────────────────────────────────────┤
│         SgaiInterstitialController                   │
│   scheduleInterstitial() / playInterstitial()        │
│   onResolvingPreRoll()                               │
├──────────────────────┬──────────────────────────────┤
│   DSS SDK Layer      │   Bamtech/Dominguez Layer     │
│   SessionFeatures    │   SessionState.ActiveSession   │
│   .noAds (boolean)   │   .SessionFeatures             │
│   .getNoAds()        │   .c (noAds), .d (adSuppress)  │
├──────────────────────┴──────────────────────────────┤
│              Ad Beacon / Telemetry                    │
│         (beaconUrl impression tracking)              │
└─────────────────────────────────────────────────────┘
```

### Layer 1: Session Feature Flags

The ad-free entitlement is determined by a `noAds` boolean in `SessionFeatures`. This flag originates from the server-side session response and propagates through **two independent class hierarchies**:

| Class | Package | Role |
|-------|---------|------|
| `SessionFeatures` | `com.dss.sdk.orchestration.common` | DSS SDK — primary feature flag container |
| `SessionState$ActiveSession$SessionFeatures` | `com.bamtechmedia.dominguez.session` | Bamtech — internal session state representation |

Both classes have `<init>(ZZZ)V` constructors accepting three booleans. The `noAds` flag is the parameter that controls whether the ad pipeline activates.

**Why both must be patched:** The app reads the flag from both layers at different points in the playback lifecycle. The DSS layer is checked during session initialization, while the Bamtech layer is checked during playback state transitions. Patching only one leaves the other path open.

**Why the getter must also be patched:** Even after forcing `true` in constructors, other code paths call `getNoAds()` directly on the DSS `SessionFeatures` object. If the field value was somehow reset (e.g., via deserialization or copy constructor), the getter override ensures it always returns `true`.

### Layer 2: Interstitial Ad Controller

`SgaiInterstitialController` is the central orchestrator for mid-roll and pre-roll ad insertion. It contains three key methods identified by their log strings:

| Method | Log String | Purpose |
|--------|-----------|---------|
| `scheduleInterstitial()` | `"SgaiInterstitialController scheduleInterstitial()"` | Queues an ad break at a specific timestamp |
| `playInterstitial()` | `"SgaiInterstitialController playInterstitial()"` | Triggers playback of a queued ad break |
| `onResolvingPreRoll()` | `"onResolvingPreRoll() setting state to loadingAdPod"` | Initiates pre-roll ad loading before content |

**Why all three are needed:** `scheduleInterstitial` and `playInterstitial` handle mid-roll ads (the most common type). `onResolvingPreRoll` handles the separate pre-roll path that fires before content playback begins. Without patching all three, some ad types would still display.

**Why this is a safety net and not the primary patch:** The `noAds` flag (Patch 1) prevents the ad pipeline from activating at all. But if the server-side response overrides the flag or a future update adds a new code path, these no-ops ensure ads still can't play. Defense in depth.

### Layer 3: Ad Telemetry / Beacons

The app fires beacon URLs to track ad impressions, completions, quartiles, and errors. These are used for:
- Ad billing (proving ads were shown to advertisers)
- Analytics (tracking ad completion rates)
- Potentially detecting ad-free patches (missing beacons for served ads)

**Why this is optional:** Suppressing beacons prevents Disney from detecting that ads were blocked (no impression data for ads the server thinks it served). However, it also suppresses legitimate analytics, and aggressive beacon suppression could itself be a detection signal if Disney monitors for missing telemetry. Users should enable this based on their risk tolerance.

## Fingerprint Strategy

All fingerprints prioritize **string-based matching** for resilience across APK versions:

| Fingerprint | Primary Match | Fallback |
|-------------|--------------|----------|
| DSS SessionFeatures ctor | `"noAds"` string + `(ZZZ)V` params | — |
| Bamtech SessionFeatures ctor | `(ZZZ)V` params + `XOR_INT_LIT8` opcode + class name contains `"SessionFeatures"` and `"bamtechmedia"` | — |
| getNoAds getter | `"noAds"` string + method name `getNoAds` | — |
| scheduleInterstitial | `"SgaiInterstitialController scheduleInterstitial()"` | — |
| playInterstitial | `"SgaiInterstitialController playInterstitial()"` | — |
| onResolvingPreRoll | `"onResolvingPreRoll() setting state to loadingAdPod"` | — |
| Ad beacon | `"beaconUrl"` string | — |

**Why strings over opcodes:** ProGuard/R8 obfuscation renames classes, methods, and fields, but string literals used in logging are preserved. The log strings in `SgaiInterstitialController` are stable identifiers that survive obfuscation across versions. The `"noAds"` string is a serialization key that must remain stable for server compatibility.

**Why the Bamtech fingerprint uses opcodes:** The Bamtech `SessionFeatures` class doesn't reference the `"noAds"` string directly (it uses obfuscated single-letter field names like `c` and `d`). The `XOR_INT_LIT8` opcode in its constructor is a distinctive pattern (used for boolean inversion logic) combined with the class name heuristic.

## Patch Grouping Rationale

### forceNoAdsPatch (a + b + c grouped)

The three sub-patches (DSS constructor, Bamtech constructor, getNoAds getter) are grouped into a single `forceNoAdsPatch` because:

1. **Single logical purpose** — They all enforce `noAds = true`. A user either wants the ad-free flag forced or they don't.
2. **Mutual dependency** — Patching only one layer is unreliable. The DSS and Bamtech layers are both read during different phases of session/playback initialization. The getter is a third read path.
3. **Atomic success/failure** — If any one of the three fingerprints fails to match (e.g., due to a refactor), the entire patch should be considered broken. Splitting them would allow partial application that appears to work but misses ads in some scenarios.

### disableInterstitialsPatch (schedule + play + preroll grouped)

Similarly grouped because:
1. All three methods are entry points into the same interstitial system
2. Missing any one would leave a specific ad type (mid-roll or pre-roll) unblocked
3. They form the complete set of `SgaiInterstitialController` ad insertion paths

### disableAdTrackingPatch (separate, opt-in)

Kept separate because:
1. It serves a different purpose (telemetry suppression vs ad removal)
2. It has different risk characteristics (could be a detection signal)
3. Users should make an informed choice about enabling it

## Fire OS Compatibility Analysis

The Fire OS build (`com.disney.disneyplus-fireos.apk`, 48 MB) was analyzed and compared against the Play Store build.

### Key Finding: Patches Are Fully Compatible

Both builds use **the same package name** (`com.disney.disneyplus`) and **the same version** (26.1.2+rc2). The ad system is identical — the DSS SDK, Bamtech session layer, and SGAI interstitial controller are the same codebase.

### Verified Patch Targets (Fire OS)

| Target | Play Store | Fire OS |
|--------|-----------|---------|
| `com.dss.sdk.orchestration.common.SessionFeatures` | `<init>(ZZZ)V`, fields: `coPlay`, `download`, `noAds`, method: `getNoAds()Z` | **Identical** |
| `com.bamtechmedia.dominguez.session.SessionState$ActiveSession$SessionFeatures` | `<init>(ZZZ)V`, fields: `a`, `b`, `c`, `d` | **Identical** |
| `"SgaiInterstitialController scheduleInterstitial()"` | Present | **Present** |
| `"SgaiInterstitialController playInterstitial()"` | Present | **Present** |
| `"onResolvingPreRoll() setting state to loadingAdPod"` | Present | **Present** |
| `"beaconUrl"` | Present | **Present** |

### Fire OS-Specific Additions (421 Amazon classes)

These are **not related to ad delivery** and do not affect our patches:

| Component | Package | Purpose |
|-----------|---------|---------|
| Amazon IAP SDK | `com.amazon.device.iap` | Billing via Amazon Appstore (replaces Google Play Billing) |
| Amazon DRM | `com.amazon.device.drm` | Amazon licensing verification |
| Alexa VSK | `com.amazon.alexa.vsk_app_agent_api` | Alexa voice control ("play X on Disney+") |
| Amazon ADM | `com.bamtechmedia.dominguez.platform.AmazonDeviceMessagingReceiver` | Push notifications via Amazon (replaces FCM) |
| Amazon Ad ID | `com.dss.sdk.internal.media.adengine.AmazonAdvertisingIdProvider` | Device advertising ID (targeting, not delivery) |
| Amazon IAP wrapper | `com.disneystreaming.iap.amazon.AmazonIAPPurchase` | Disney's Amazon billing integration |
| Subscription provider | `com.dss.sdk.subscription.SubscriptionProvider$AMAZON` | Amazon subscription type |

### Fire TV Platform Detection

The Fire OS build includes `isFireTv` checks and the `"amazon.hardware.fire_tv"` feature flag for UI adaptation (10-foot lean-back interface). These affect layout/navigation only, not the ad pipeline.

### Structural Differences

| Aspect | Play Store | Fire OS |
|--------|-----------|---------|
| DEX files | 4 | 8 (more code from Amazon SDKs) |
| APK size | 39 MB (XAPK split) | 48 MB (single APK, armeabi-v7a only) |
| Crash reporting | Bugsnag | Datadog |
| Push notifications | Firebase Cloud Messaging | Amazon Device Messaging |
| Billing | Google Play Billing | Amazon IAP SDK v2.10.2.0 |
| Ad ID provider | Google Advertising ID | Amazon Advertising ID |
| Google Play Billing | Present | **Absent** |

### Why the Same Package Name

Disney+ uses `com.disney.disneyplus` on both stores. Amazon Appstore does not require different package names. The `compatibleWith("com.disney.disneyplus")` constraint in our patches matches both builds without modification.

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Server-side ad enforcement | Medium | Patches 1+2 together handle both flag-based and scheduling-based ad delivery |
| Fingerprint breakage on update | Low | String-based fingerprints survive obfuscation; log strings rarely change |
| Detection via missing beacons | Low-Medium | Patch 3 (opt-in) suppresses beacons; without it, beacons fire for non-displayed ads (low signal) |
| Field name changes in Bamtech layer | Medium | Bamtech fingerprint uses opcode pattern + class name, not field names |
| New ad insertion code path | Low | The `noAds` flag is checked at the pipeline entry point; new paths would likely check it too |
