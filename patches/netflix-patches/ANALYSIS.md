# Netflix Ad System — Reverse Engineering Analysis

Analysis of Netflix v9.0.0 build 4 62189 APK ad delivery architecture and patch rationale.

## Unified APK Architecture

### Key Finding: Netflix Ships ONE APK for All Platforms

Unlike Disney+ which ships separate APKs for Play Store and Fire OS, Netflix uses a **single unified APK** (`com.netflix.mediaclient`) across Google Play, Amazon Appstore, and Samsung Galaxy Store. Platform-specific behavior is controlled at runtime through a `DistributionChannel` enum.

```
┌─────────────────────────────────────────────────────────────┐
│               com.netflix.mediaclient v9.0.0                │
│                    (single APK)                             │
├─────────────────────────────────────────────────────────────┤
│  DistributionChannel enum (runtime detection)              │
│    ├── "google"  / "com.android.vending"    → field i      │
│    ├── "amazon"  / "com.amazon.venezia"     → field d      │
│    ├── "samsung" / "com.sec.android.app.samsungapps" → g   │
│    └── ""        / "None"                   → field h      │
├─────────────────────────────────────────────────────────────┤
│  Platform-specific code (all compiled in):                  │
│    ├── AmazonPushNotificationOptions (ADM)                 │
│    ├── amazon.intent.extra.* (launcher integration)        │
│    ├── com.amazon.hardware.tv_screen (Fire TV detection)   │
│    ├── com.amazon.permission.SET_FLAG_NOSOFTKEYS           │
│    ├── Firebase Cloud Messaging (Google)                   │
│    └── Samsung Galaxy Store hooks                          │
└─────────────────────────────────────────────────────────────┘
```

### Verified: Same Ad System Across All Platforms

The pause ad pipeline is **completely platform-agnostic**. There is no `DistributionChannel` check anywhere in the ad code path:

| Component | Platform-Specific? | Evidence |
|-----------|-------------------|----------|
| `PauseAdsFeatureFlagHelperImpl` (`Lo/fVb;`) | No | Reads only from Hendrix config, no platform checks |
| `PauseAdsPrefetchPresenterImpl` (`Lo/fVv;`) | No | Same prefetch flow for all platforms |
| `PauseAdsPresenterImpl` (`Lo/fVt;`) | No | Same UI overlay code |
| `PauseAdsRepositoryImpl` | No | Same GraphQL queries |
| `PlayerFragmentV2.C()` | No | Same gate logic |
| Hendrix A/B config system | No | Server-side, platform-independent |

**Implication: A single ReVanced patch works for Google Play, Amazon Appstore, Samsung Galaxy Store, and sideloaded installs.**

### Amazon/Fire OS-Specific Components

The following Amazon-specific components exist in the APK but are **unrelated to ad delivery**:

| Component | Purpose |
|-----------|---------|
| `AmazonPushNotificationOptions` | Push notifications via Amazon Device Messaging (ADM) |
| `shouldDisableAmazonADM` config | Hendrix flag to disable ADM on non-Amazon devices |
| `amazon.intent.extra.*` intents | Amazon launcher integration (partner activation, deep links) |
| `com.amazon.hardware.tv_screen` | Fire TV hardware detection for UI adaptation |
| `com.amazon.cloud9` / browsing | Amazon Silk browser integration |
| `SET_FLAG_NOSOFTKEYS` permission | Fire TV soft key suppression |
| `amazonCatalogSearch` | Amazon content catalog search integration |
| `isAmazonRelease` config flag | Build-time or runtime Amazon release detection |

### Structural Comparison (vs Disney+ approach)

| Aspect | Disney+ | Netflix |
|--------|---------|---------|
| APK strategy | Separate Play Store + Fire OS APKs | **Single unified APK** |
| Package name | `com.disney.disneyplus` (both) | `com.netflix.mediaclient` (all) |
| Platform detection | Build-time (separate builds) | Runtime (`DistributionChannel` enum) |
| Ad system shared? | Yes (same codebase in both APKs) | Yes (single codebase, single APK) |
| Patches needed | 1 patch set, works on both APKs | **1 patch set, 1 APK** |
| Fire TV UI | `isFireTv` + `amazon.hardware.fire_tv` | `com.amazon.hardware.tv_screen` |
| Push notifications | FCM (Play) / ADM (Fire OS) | Both compiled in, selected at runtime |
| Billing | Play Billing (Play) / Amazon IAP (Fire OS) | Both compiled in, selected at runtime |

## Ad System Architecture

Netflix has two distinct ad systems. Only pause ads are patchable client-side.

### Pause Ads (Client-Driven) — PATCHABLE

```
┌─────────────────────────────────────────────────────────┐
│              PlayerFragmentV2.C()                        │
│  calls fUW.e()Z → THE PRIMARY GATE                      │
│  also checks adsPlan.c()Z (secondary)                   │
├─────────────────────────────────────────────────────────┤
│     PauseAdsFeatureFlagHelperImpl (Lo/fVb;)              │
│     7 Hendrix config booleans → 5 gate methods (a-e)    │
│     e()Z = main gate: c && (d || f || j)                │
├─────────────────────────────────────────────────────────┤
│     PauseAdsPrefetchPresenterImpl (Lo/fVv;)              │
│     prefetchAd() → PauseAdsRepositoryImpl                │
│     GraphQL: PauseAdsPlaybackAdQuery(videoId=...)        │
├─────────────────────────────────────────────────────────┤
│     PauseAdsPresenterImpl (Lo/fVt;)                      │
│     renders PauseAdsScreen overlay on pause              │
├─────────────────────────────────────────────────────────┤
│     Ad Event Tracking                                    │
│     AdStartDisplayPauseEvent → AdProgressDisplayPause    │
│     → AdCompleteDisplayPauseEvent (viewability data)     │
└─────────────────────────────────────────────────────────┘
```

### Video Ad Breaks (SSAI) — NOT PATCHABLE

Server-Side Ad Insertion with SCTE-35 markers. The server embeds ad break signals in the media manifest and provides ad creative URLs via `/playapi/android/adbreakhydration`. Client-side patching risks playback stalling at embedded break points.

## Patch Targets

### Primary: Feature Flag Gate (`Lo/fVb;->e()Z`)

The main decision point. When `e()` returns `false`, the entire pause ad pipeline is skipped.

**Current bytecode:**
```smali
.method public final e()Z
    iget-boolean v0, v1, Lo/fVb;->c Z     # core enabled flag
    if-eqz v0, :false
    iget-boolean v0, v1, Lo/fVb;->d Z     # test harness override
    if-nez v0, :true
    iget-boolean v0, v1, Lo/fVb;->f Z     # sub-flag A
    if-nez v0, :true
    iget-boolean v0, v1, Lo/fVb;->j Z     # sub-flag B
    if-nez v0, :true
    :false
    const/4 v0, 0
    goto :return
    :true
    const/4 v0, 1
    :return
    return v0
.end method
```

**Patched bytecode:**
```smali
.method public final e()Z
    const/4 v0, 0
    return v0
.end method
```

### Secondary gates (same `const/4 v0, 0` + `return v0` pattern):

| Method | Purpose | Patch effect |
|--------|---------|-------------|
| `Lo/fVb;->b()Z` | Secondary gate used by `Lo/fVu;` | Blocks secondary pause ad path |
| `Lo/fVb;->c()Z` | Test harness variant | Blocks test harness ads |
| `Lo/fVb;->d()Z` | Event tracking gate | Suppresses viewability logging |
| `Lo/fVb;->a()Z` | Logging flag | Suppresses ad event logging |

## Fingerprint Strategy

### Why String-Based Fingerprints

ProGuard/R8 renames classes, methods, and fields, but string literals used in logging are preserved. Netflix's "Pause Ads:" prefixed log messages are ideal anchors:

| Fingerprint | Primary Match String | Location |
|-------------|---------------------|----------|
| pauseAdsPlayerGate | `"Pause Ads: Video view is null. Cannot show pause ad."` | PlayerFragmentV2.C() |
| pauseAdsPrefetch | `"Pause Ads: prefetching adUrl "` | PauseAdsPrefetchPresenterImpl |
| pauseAdsPrefetchError | `"Pause Ads: fetching ad data failed."` | PauseAdsPrefetchPresenterImpl error handler |
| pauseAdsUiState | `"PauseAdsUiState(adUrl="` | PauseAdsUiState.toString() |

### Why We Fingerprint the Caller, Not the Target

The feature flag helper (`Lo/fVb;`) has no log strings — its methods are pure boolean logic on obfuscated fields. We can't create a reliable string fingerprint for it directly. Instead:

1. Fingerprint `PlayerFragmentV2.C()` via its unique "Pause Ads:" log strings
2. Find the `invoke-interface` call to the feature flag helper's `e()Z` in the matched method
3. Patch the call site (force result to `false`) or navigate to the implementation class

This is more resilient than matching on obfuscated class/field names (`Lo/fVb;->c Z`) which will change across versions.

### Alternative: Direct Opcode Fingerprint for `Lo/fVb;->e()Z`

If needed, the method has a distinctive pattern:
- Returns `Z`
- 4 consecutive `iget-boolean` instructions
- Interleaved with `if-eqz` and `if-nez` branches
- Exactly 12 instructions

```kotlin
fingerprint {
    returns("Z")
    opcodes(
        Opcode.IGET_BOOLEAN,   // field c
        Opcode.IF_EQZ,
        Opcode.IGET_BOOLEAN,   // field d
        Opcode.IF_NEZ,
        Opcode.IGET_BOOLEAN,   // field f
        Opcode.IF_NEZ,
        Opcode.IGET_BOOLEAN,   // field j
        Opcode.IF_NEZ,
    )
}
```

This is less stable across versions (fields may be reordered) but works as a fallback.

## Patch Grouping Rationale

### disablePauseAdsPatch (primary, enabled by default)

Groups two sub-patches:
1. **Call-site override in PlayerFragmentV2.C()** — Forces the `fUW.e()Z` result to `false` at the player level
2. **No-op PauseAdsPrefetchPresenterImpl** — Prevents ad data from being fetched even if the gate is bypassed

**Why both:** Defense in depth. The call-site patch prevents the UI from showing pause ads. The prefetch no-op prevents unnecessary network requests and ensures no ad data is cached. If one fails (e.g., Netflix adds a new call site for `e()Z`), the other still blocks ads.

### disablePauseAdTrackingPatch (optional, disabled by default)

Separate because:
1. Different purpose (telemetry suppression vs ad removal)
2. Missing ad events could be a detection signal
3. Users should choose based on their risk tolerance

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Server-side pause ad enforcement | Low | Pause ads are fully client-driven; server only provides ad data when requested |
| Fingerprint breakage on update | Low | "Pause Ads:" log strings are functional, not debug — unlikely to be removed |
| Detection via missing ad events | Low-Medium | Without tracking patch, ad opportunity events may still fire for unfetched ads |
| Play Integrity attestation failure | Medium | Resigned APK fails Play Integrity; Netflix may block patched clients |
| SSAI video ads unaffected | N/A | These patches only target pause ads; video ad breaks remain server-controlled |
| Hendrix config override | Low | Even if server pushes `noAds=true`, the gate patch forces `false` at the call site |

## Comparison: Netflix vs Disney+ Patch Approach

| Aspect | Disney+ | Netflix |
|--------|---------|---------|
| **Primary patch** | Force `noAds = true` in SessionFeatures | Force feature flag gate `e()Z` to return `false` |
| **Patch mechanism** | Override constructor params + getter | Override call site + no-op prefetch |
| **Safety net** | No-op SgaiInterstitialController methods | No-op PauseAdsPrefetchPresenterImpl |
| **Fingerprint type** | String (`"noAds"`) + opcode (XOR_INT_LIT8) | String (`"Pause Ads: ..."`) |
| **Platforms** | 2 APKs (Play + Fire OS), same package | 1 APK, all platforms |
| **Ad types blocked** | All (noAds flag controls entire pipeline) | Pause ads only (SSAI video ads unaffected) |
| **Tracking patch** | Optional beacon suppression | Optional event suppression |
| **Package** | `com.disney.disneyplus` | `com.netflix.mediaclient` |
