# Netflix ReVanced Patches

ReVanced Patches module for disabling pause ads in Netflix (com.netflix.mediaclient).

## Patches

| Patch | Description | Default |
|-------|-------------|---------|
| **Disable pause ads** | Forces the pause ads feature flag to false and no-ops the prefetch presenter | Enabled |
| **Disable pause ad tracking** | Suppresses pause ad impression/viewability event reporting | Disabled (opt-in) |

## Scope

These patches target **pause ads only** (the static/display ads shown when you pause playback). Netflix's video ad breaks (mid-roll/pre-roll) use Server-Side Ad Insertion (SSAI) with SCTE-35 markers embedded in the media stream and cannot be reliably patched client-side.

## Target

- **Package:** `com.netflix.mediaclient`
- **Tested version:** 9.0.0 build 4 62189
- **Platforms:** Google Play, Amazon Appstore, Samsung Galaxy Store, and Fire TV (Netflix ships a single unified APK for all platforms)

## Building

Requires Java 17+ and a GitHub PAT with `read:packages` scope for the ReVanced Maven repository.

```bash
export GITHUB_ACTOR=your-github-username
export GITHUB_TOKEN=your-github-pat

./gradlew :patches:build
```

The output JAR will be at `patches/build/libs/patches-1.0.0.jar`.

## Usage

1. Build the patches JAR (see above)
2. Open ReVanced Manager → Settings → Patch sources → Add custom source
3. Select the built JAR file
4. Select Netflix APK (v9.0.0) and apply patches

## Architecture Analysis

See [ANALYSIS.md](./ANALYSIS.md) for the full reverse-engineering analysis of the Netflix ad system.

### Summary

Netflix v9.0.0 has a client-driven pause ad system with a clear feature flag chokepoint:

1. **Feature flag gate** — `PauseAdsFeatureFlagHelperImpl.e()Z` reads 7 Hendrix A/B config booleans and returns a single boolean controlling whether pause ads activate.
2. **Prefetch presenter** — `PauseAdsPrefetchPresenterImpl` fetches ad data from the server via GraphQL queries before displaying the overlay.
3. **Ad event tracking** — `AdDisplayPauseEvent` subclasses report impression/viewability data.

The patches target the feature flag gate and the prefetch presenter for defense in depth.

### Unified APK — No Separate Fire OS Build

Netflix ships a single APK with a runtime `DistributionChannel` enum (`google`/`amazon`/`samsung`/`None`). The ad system is completely platform-agnostic — the same patch works on all platforms without modification.

## How It Works

### Disable pause ads (primary)
1. Finds `PlayerFragmentV2.C()` via its unique "Pause Ads: Video view is null..." log strings
2. Locates the `invoke-interface` call to the feature flag helper's `e()Z` gate method
3. Forces the gate result to `false` (0), skipping the entire pause ad setup
4. Additionally no-ops `PauseAdsPrefetchPresenterImpl` to prevent ad data from being fetched

### Disable pause ad tracking (optional)
No-ops the pause ad error/event handler to suppress impression tracking. This reduces the chance of server-side detection but may affect analytics.
