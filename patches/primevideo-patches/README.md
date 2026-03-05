# Prime Video ReVanced Patches

ReVanced patches for Amazon Prime Video (`com.amazon.avod.thirdpartyclient`) to skip server-inserted ad breaks.

Ported from [amazon-vod-noads](https://github.com/ScriptGod1337/amazon-vod-noads) (now archived).

## Patches

| Patch | Effect |
|-------|--------|
| Skip ads | Hooks `ServerInsertedAdBreakState.enter()` to seek past the entire ad break and transition the FSM to `NO_MORE_ADS_SKIP_TRANSITION` |

## How It Works

The patch dynamically locates the `getPrimaryPlayer()` call inside `ServerInsertedAdBreakState.enter()` and injects a static call to the ReVanced extension that:
1. Reads `AdBreakTrigger.getSeekTarget()` to find the ad break end position
2. Calls `VideoPlayer.seekTo()` to jump past the break
3. Fires `StateBase.doTrigger(NO_MORE_ADS_SKIP_TRANSITION)` to reset the state machine
4. Returns void to skip the original ad-break playback logic

The fingerprint uses class/method name matching (no opcode sequence) so it survives across APK versions that rearrange instructions at the start of `enter()`.

## Compatible Versions

- `3.0.412.2947`
- `3.0.438.2347`
- `3.0.444.557`

## Build

```bash
export GITHUB_ACTOR=your-github-username
export GITHUB_TOKEN=your-github-pat  # read:packages scope
cd patches/primevideo-patches
./gradlew :patches:build
# Output: patches/build/libs/patches-*.rvp
```

## Alternative Patch Scripts (No ReVanced CLI)

For direct APK patching without building a ReVanced patch bundle:

```bash
# Recommended: dex-only patch (updates single DEX, resigns)
analysis/primevideo/scripts/patch-primevideo-skipads-dex.sh <input.apk> [output.apk]

# Full ReVanced CLI flow
analysis/primevideo/scripts/patch-primevideo-skipads.sh <input.apk> [output.apk]

# Apktool smali injection (more fragile)
analysis/primevideo/scripts/patch-primevideo-skipads-smali.sh <input.apk> [output.apk]
```

## Adapting to New Versions

See [docs/AI_RUNBOOK_PRIMEVIDEO.md](../../docs/AI_RUNBOOK_PRIMEVIDEO.md) for detailed instructions on updating patches when a new APK version breaks matching.
