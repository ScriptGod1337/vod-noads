# Disney+ ReVanced Patches

ReVanced Patches module for removing ads from Disney+ (com.disney.disneyplus).

## Patches

| Patch | Description | Default |
|-------|-------------|---------|
| **Force no-ads flag** | Forces `SessionFeatures.noAds` to `true`, enabling the ad-free experience | Enabled |
| **Disable interstitial ads** | Prevents SGAI interstitial ads from being scheduled or played | Enabled |
| **Disable ad tracking** | Suppresses ad beacon/telemetry requests | Disabled (opt-in) |

## Target

- **Package:** `com.disney.disneyplus`
- **Tested version:** 26.1.2
- **Platforms:** Google Play (Android) and **Amazon Fire OS / Fire TV** (verified — same ad system codebase)

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
4. Select Disney+ APK (v26.1.2) and apply patches

## Architecture Analysis

See [ANALYSIS.md](./ANALYSIS.md) for the full reverse-engineering analysis of the Disney+ ad system.

### Summary

Disney+ v26.1.2 has a layered ad system with clear client-side chokepoints:

1. **Session feature flags** — The `noAds` boolean propagates through two SDK layers (DSS and Bamtech) and controls whether the ad pipeline activates at all.
2. **Interstitial scheduling** — `SgaiInterstitialController` orchestrates mid-roll and pre-roll ad insertion via `scheduleInterstitial()`, `playInterstitial()`, and `onResolvingPreRoll()`.
3. **Ad telemetry** — Beacon URLs track ad impressions and completions for billing/analytics.

The patches target all three layers for defense in depth.

## How It Works

### Force no-ads flag (primary)
Patches the `SessionFeatures` constructors and getter in both the DSS SDK and Bamtech layers to always report `noAds = true`. This is the same flag that Disney+ checks for ad-free tier subscribers.

### Disable interstitial ads (safety net)
Inserts `return-void` at the top of `SgaiInterstitialController.scheduleInterstitial()`, `playInterstitial()`, and `onResolvingPreRoll()` so that even if an ad is requested server-side, the client will never schedule or display it.

### Disable ad tracking (optional)
No-ops the beacon firing method to prevent ad impression/completion tracking. This reduces the chance of server-side detection but may affect analytics.
