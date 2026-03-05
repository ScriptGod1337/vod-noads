# HBO Max ReVanced Patches

ReVanced Patches module for disabling ads in HBO Max (com.hbo.hbonow) on Fire OS.

## Patches

| Patch | Description | Default |
|-------|-------------|---------|
| **Force ad-free strategy** | Forces BoltAdStrategyMapper to return "ad_free", disabling ad modules | Enabled |
| **Disable pause ads** | No-ops PauseAdsInteractor and both static/dynamic pause ad use cases | Enabled |
| **Auto-skip ad breaks** | Automatically skips SSAI ad breaks + allows manual seeking past them | Enabled |
| **Disable ad tracking** | Suppresses SSAI beacon and pause ad tracking requests | Disabled (opt-in) |

## Scope

These patches address three ad-related systems:

1. **Ad strategy gate** — Forces the client to treat the session as ad-free, disabling ad overlay UI, pause ads, and skip enforcement
2. **Pause ads** — Blocks both static (pre-loaded) and dynamic (on-demand fetched) pause ad display
3. **SSAI ad breaks** — Auto-skips video ad breaks by exploiting HBO's built-in "already watched" skip logic

**Key feature:** HBO Max uses Server-Side Ad Insertion (SSAI) — ads are stitched into the video stream server-side and cannot be removed. However, the auto-skip patch makes the player **automatically jump past ad breaks** to content, so you never see the ads play. This works by forcing the `AdSkipModule` to treat every ad break as "already watched", which triggers HBO's own skip-to-content logic.

## Target

- **Package:** `com.hbo.hbonow`
- **Tested version:** 6.16.2.2 (Fire OS variant)
- **Platform:** Amazon Fire TV / Fire OS

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
4. Select HBO Max APK (v6.16.2.2 Fire OS) and apply patches

## Architecture Analysis

See [ANALYSIS.md](./ANALYSIS.md) for the full reverse-engineering analysis of the HBO Max ad system.

### Summary

HBO Max v6.16.2.2 uses WBD's Discovery AdTech SDK with three ad delivery mechanisms:

1. **SSAI video ad breaks** — Server-stitched via AdSparx + FreeWheel + Uplynk CDN. Auto-skipped by forcing the "already watched" code path.
2. **Pause ads** — Client-driven (static from metadata or dynamic fetch). Fully blocked via interactor/use case no-ops.
3. **Ad skip enforcement** — Client-side `AdSkipModule` snapback. No-opped for manual seek, auto-skip for linear playback.

The `BoltAdStrategyMapper.map()` method is the primary client-side gate — it resolves `"ad_free"` / `"ad_light"` / `"ad_full"` from a server-provided array, and all downstream modules key off this value.

### Non-Obfuscated Ad Classes

Unlike Netflix's heavily obfuscated codebase, HBO Max's ad classes retain their full package and class names (`com.discovery.adtech.*`), making fingerprinting and patching significantly more reliable.

## How It Works

### Force ad-free strategy (primary)
Replaces `BoltAdStrategyMapper.map()` body to always return `"ad_free"`, bypassing the server-provided ad strategy array. All downstream ad modules see an ad-free session.

### Disable pause ads
No-ops three entry points:
- `PauseAdsInteractor.listen()` — stops subscribing to player pause events
- `ShowDynamicPauseAdUseCase` — stops fetching on-demand pause ads
- `ShowPauseAdUseCase` — stops showing pre-loaded pause ads

### Auto-skip ad breaks
Two-part approach:

**a) Auto-skip during normal playback:**
Patches `AdSkipModule.onAdBreakWillStart()` — the method called when playback reaches an ad break. It checks `state.watchedSlots.contains(adBreakIndex)`:
- If **true** (already watched) → auto-skips to `nextChapterStart()` (content after the ad)
- If **false** (unwatched) → forces user to watch

We force the `Set.contains()` result to `true`, so every break is treated as "already watched". The player automatically jumps to content after the ad break — no manual interaction needed.

**b) Allow manual seeking:**
No-ops the seek interception and redirect methods so manual scrubbing past ad breaks also works without snapback.

### Disable ad tracking (optional)
No-ops SSAI beacon repository and pause ad beacon emitter to suppress all ad impression/quartile/completion HTTP tracking requests.
