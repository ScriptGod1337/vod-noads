# Streaming Ad System Research

Reverse-engineering research and ReVanced patch development for ad systems in Netflix, Disney+, HBO Max, and Prime Video Android APKs, including Fire OS / Fire TV variants.

## Repository Structure

```
.
├── ANALYSIS.NETFLIX.md          # Netflix APK: ad system architecture, feature flag
│                                #   deep dive, smali patch targets, Fire OS findings
├── ANALYSIS.DISNEYPLUS.md       # Disney+ APK: SGAI architecture, SessionFeatures,
│                                #   patch targets, Fire OS compatibility analysis
├── ANALYSIS.HBOMAX.md           # HBO Max APK: SSAI/AdSparx architecture, FreeWheel,
│                                #   BoltAdStrategyMapper, pause ads, Fire OS analysis
├── ANALYSIS.FIRETV.md           # Prime Video (firebat): FSM ad architecture,
│                                #   AdBreakSelector chokepoint, Fire TV casting analysis
│
├── apks/                        # Source APKs used for analysis
│   ├── com-netflix-mediaclient-62189-*.apk          # Netflix v9.0.0 b4 (Google Play)
│   ├── Disney+_26.1.2+rc2-2026.02.23_APKPure.xapk  # Disney+ v26.1.2 (XAPK)
│   ├── com.disney.disneyplus-fireos.apk             # Disney+ v26.1.2 (Fire OS)
│   ├── com.hbo.hbonow-fireos.apk                    # HBO Max v6.16.2.2 (Fire OS)
│   └── ...                                          # Older Disney+ versions
│
├── analysis/                    # Raw analysis artifacts
│   ├── netflix/
│   │   └── apk_contents/        # Extracted Netflix APK (DEX, manifest, assets)
│   ├── disney/
│   │   ├── COMPLETE_ANALYSIS_SUMMARY.md  # Domain/URL enumeration (v2.16.2)
│   │   ├── apks_contents/        # Extracted old Disney+ v2.16.2 APK
│   │   ├── xapk_v26/             # Extracted Disney+ v26.1.2 APK
│   │   ├── disney_analysis.txt   # Raw androguard output
│   │   └── disney_domains_categorized.csv
│   ├── disney-fireos/
│   │   └── AndroidManifest.xml   # Disney+ Fire OS manifest (diff vs Play Store)
│   ├── hbo/
│   │   ├── AndroidManifest.xml   # HBO Max Fire OS decoded manifest
│   │   └── apk_contents/         # Extracted HBO Max APK (DEX, manifest, assets)
│   └── primevideo/
│       ├── primevideo_skipads_ai_prompt.md   # AI agent prompt for skip-ads analysis
│       ├── primevideo_cast_ads_ai_prompt.md  # Cast playback ad analysis prompt
│       └── scripts/               # Direct APK patching scripts (no ReVanced CLI)
│           ├── patch-primevideo-skipads.sh       # Full ReVanced CLI flow
│           ├── patch-primevideo-skipads-dex.sh   # Dex-only patch (recommended)
│           └── patch-primevideo-skipads-smali.sh # Apktool smali injection
│
├── docs/
│   └── AI_RUNBOOK_PRIMEVIDEO.md            # Prime Video: how to adapt patches for new APK versions
│
├── vendor/
│   └── revanced-patches/        # Upstream ReVanced patches (git submodule)
│
└── patches/                     # ReVanced patch projects
    ├── revanced-primevideo-skipads.patch  # Diff applied to upstream ReVanced patches
    ├── netflix-patches/          # Netflix patch implementation
    │   ├── README.md             # Build + usage guide
    │   ├── ANALYSIS.md           # Patch design rationale and fingerprint strategy
    │   └── patches/src/main/kotlin/app/revanced/patches/netflix/ads/
    │       ├── DisableAdsPatch.kt
    │       └── Fingerprints.kt
    ├── disneyplus-patches/       # Disney+ patch implementation
    │   ├── README.md             # Build + usage guide
    │   ├── ANALYSIS.md           # Patch design rationale and fingerprint strategy
    │   └── patches/src/main/kotlin/app/revanced/patches/disney/ads/
    │       ├── DisableAdsPatch.kt
    │       └── Fingerprints.kt
    ├── hbomax-patches/           # HBO Max patch implementation
    │   ├── README.md             # Build + usage guide
    │   ├── ANALYSIS.md           # Patch design rationale and fingerprint strategy
    │   └── patches/src/main/kotlin/app/revanced/patches/hbomax/ads/
    │       ├── DisableAdsPatch.kt
    │       └── Fingerprints.kt
    └── primevideo-patches/       # Prime Video patch implementation
        ├── README.md             # Build + usage guide (incl. alternative scripts)
        └── patches/src/main/kotlin/app/revanced/patches/primevideo/ads/
            ├── SkipAdsPatch.kt
            └── Fingerprints.kt
```

## Findings Summary

### Netflix (`com.netflix.mediaclient`)

**Tested version:** v9.0.0 build 4 62189

Netflix ships a **single unified APK** for all platforms (Google Play, Amazon Appstore / Fire TV, Samsung Galaxy Store). Platform selection happens at runtime via a `DistributionChannel` enum — there is no separate Fire OS build.

| Ad System | Mechanism | Patchable? |
|-----------|-----------|-----------|
| **Pause ads** | Fully client-driven; gated by `PauseAdsFeatureFlagHelperImpl.e()Z` reading Hendrix A/B config | **Yes** |
| **Video ad breaks** | SSAI with SCTE-35 markers embedded server-side in the media stream | No (server-controlled) |

The pause ad feature flag chain: `PlayerFragmentV2` → `pauseAdsFeatureFlagHelper.e()Z` (`Lo/fVb;`) → 7 Hendrix config booleans. Forcing `e()` to return `false` and no-opping the prefetch presenter disables pause ads completely.

See [ANALYSIS.NETFLIX.md](./ANALYSIS.NETFLIX.md) for the full analysis.

### Disney+ (`com.disney.disneyplus`)

**Tested version:** v26.1.2+rc2

Disney+ ships **separate APKs** for Google Play and Amazon Appstore / Fire OS, but both share the same ad system codebase — the same patches work on both.

| Ad System | Mechanism | Patchable? |
|-----------|-----------|-----------|
| **All video ads** | Client-side `noAds` boolean in `SessionFeatures` (DSS SDK + Bamtech layers) | **Yes** |
| **Interstitial ads** | `SgaiInterstitialController` schedules/plays ad pods | **Yes** |
| **Ad telemetry** | Beacon URLs for impression/completion tracking | Yes (opt-in) |

Forcing `SessionFeatures.noAds = true` in both SDK layers prevents the entire ad pipeline from activating. The interstitial controller no-ops provide a safety net.

See [ANALYSIS.DISNEYPLUS.md](./ANALYSIS.DISNEYPLUS.md) for the full analysis.

### HBO Max (`com.hbo.hbonow`)

**Tested version:** v6.16.2.2 (Fire OS variant)

HBO Max ships a **separate Fire OS APK** (`CHANNEL=MaxFireTV`) built on the **You.i Engine** TV framework, with WBD's **Discovery AdTech SDK** handling all ad logic. The ad system uses **Server-Side Ad Insertion (SSAI)** via **AdSparx** with **FreeWheel** as the ad decisioning server and **Uplynk** as the CDN-level SSAI provider.

| Ad System | Mechanism | Patchable? |
|-----------|-----------|-----------|
| **Pause ads** | Client-driven (static from metadata or dynamic fetch); gated by `PauseAds.enabled` | **Yes** |
| **Video ad breaks** | SSAI — ads server-stitched into manifest via AdSparx | No (server-controlled) |
| **Ad skip / snapback** | `AdSkipModule` intercepts seek to force watching ads | **Yes** (no-op module) |
| **Ad overlay UI** | `ServerSideAdOverlay` with countdown, badge, count | **Yes** (disable UI) |
| **Ad strategy gate** | `BoltAdStrategyMapper.map()` resolves `ad_free`/`ad_light`/`ad_full` | **Yes** (force `ad_free`) |

The `BoltAdStrategyMapper.map()` method is the primary client-side gate — forcing it to return `"ad_free"` disables ad modules. Combined with `AdSkipModule` no-ops, users can seek past SSAI ad breaks. However, the SSAI video content itself cannot be removed client-side.

See [ANALYSIS.HBOMAX.md](./ANALYSIS.HBOMAX.md) for the full analysis.

### Prime Video (`com.amazon.avod.thirdpartyclient` / `com.amazon.firebat`)

**Tested versions:** v3.0.412.2947, v3.0.438.2347

Prime Video uses two distinct playback engines: **thirdpartyclient** (the Play Store / sideloaded APK) and **firebat** (the system-level Fire TV engine). Both share the same ad state machine architecture based on `ServerInsertedAdBreakState` within an FSM framework.

| Ad System | Mechanism | Patchable? |
|-----------|-----------|-----------|
| **Video ad breaks** | SSAI via FSM state machine (`ServerInsertedAdBreakState.enter()`) | **Yes** (skip via seek + FSM transition) |
| **Ad break selection** | `AdBreakSelector` — single chokepoint for all ad break types | **Yes** (return null from all 4 methods) |
| **Cast playback ads** | Receiver-controlled (Google Cast / Fire TV TCOMM) | No (receiver-authoritative) |

The skip-ads patch hooks `ServerInsertedAdBreakState.enter()` right after `getPrimaryPlayer()`, injects a seek to the break end position, and fires `NO_MORE_ADS_SKIP_TRANSITION` to reset the FSM. The fingerprint uses class/method name matching to survive instruction rearrangements across versions.

See [ANALYSIS.FIRETV.md](./ANALYSIS.FIRETV.md) for the full analysis.

## Patches

All patch projects are standard Gradle/Kotlin projects targeting the [ReVanced patcher](https://github.com/ReVanced/revanced-patcher). The upstream ReVanced patches source is available as a git submodule under `vendor/revanced-patches/`.

### Build Requirements

- Java 17+
- GitHub PAT with `read:packages` scope (for ReVanced Maven repository)

```bash
export GITHUB_ACTOR=your-github-username
export GITHUB_TOKEN=your-github-pat
```

### Netflix Patches

```bash
cd patches/netflix-patches
./gradlew :patches:build
# Output: patches/build/libs/patches-1.0.0.jar
```

| Patch | Default | Effect |
|-------|---------|--------|
| Disable pause ads | On | Forces feature flag gate to false; no-ops prefetch presenter |
| Disable pause ad tracking | Off | Suppresses impression/viewability event reporting |

### Disney+ Patches

```bash
cd patches/disneyplus-patches
./gradlew :patches:build
# Output: patches/build/libs/patches-1.0.0.jar
```

| Patch | Default | Effect |
|-------|---------|--------|
| Force no-ads flag | On | Forces `SessionFeatures.noAds = true` in DSS + Bamtech layers |
| Disable interstitial ads | On | No-ops `scheduleInterstitial()`, `playInterstitial()`, `onResolvingPreRoll()` |
| Disable ad tracking | Off | Suppresses beacon telemetry |

### HBO Max Patches

```bash
cd patches/hbomax-patches
./gradlew :patches:build
# Output: patches/build/libs/patches-1.0.0.jar
```

| Patch | Default | Effect |
|-------|---------|--------|
| Force ad-free strategy | On | Forces `BoltAdStrategyMapper.map()` to return `"ad_free"` |
| Disable pause ads | On | No-ops `PauseAdsInteractor.listen()`, `ShowDynamicPauseAdUseCase`, `ShowPauseAdUseCase` |
| Auto-skip ad breaks | On | Auto-skips SSAI ad breaks via "already watched" logic + allows manual seeking |
| Disable ad tracking | Off | Suppresses SSAI beacon and pause ad tracking requests |

### Prime Video Patches

```bash
cd patches/primevideo-patches
./gradlew :patches:build
# Output: patches/build/libs/patches-*.rvp
```

| Patch | Effect |
|-------|--------|
| Skip ads | Hooks `ServerInsertedAdBreakState.enter()` to seek past ad breaks and reset the FSM |

Alternative: use the direct patching scripts (no ReVanced CLI needed):
```bash
analysis/primevideo/scripts/patch-primevideo-skipads-dex.sh <input.apk> [output.apk]
```

## Tooling

Analysis was performed using:
- **androguard 4.1.3** — DEX parsing, class/method/field enumeration, string extraction
- **Python 3** — Analysis scripting
- **unzip** — APK extraction
