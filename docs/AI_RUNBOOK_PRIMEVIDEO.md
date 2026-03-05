# AI Runbook: Prime Video Skip-Ads (ReVanced CLI)

This runbook explains what was done in this workspace to patch Amazon Prime Video APKs using a locally-built ReVanced `.rvp`, and what to do when a new APK version stops matching.

## Target Behavior
Patch `com.amazon.avod.thirdpartyclient` so server-inserted ad breaks are skipped.

Upstream intent (ReVanced):
- Hook `com.amazon.avod.media.ads.internal.state.ServerInsertedAdBreakState.enter(Lcom/amazon/avod/fsm/Trigger;)V`.
- Right after the app obtains the primary `VideoPlayer` (via `getPrimaryPlayer()`), call the ReVanced Prime Video extension:
  - `Lapp/revanced/extension/primevideo/ads/SkipAdsPatch;->enterServerInsertedAdBreakState(state, trigger, player)`
- Return immediately so the original ad-break playback logic is bypassed.

## What Broke (Why The Prebuilt Patch Didn’t Apply)
For `prime-3.0.438.2347.apk`, the *method still contains* a `getPrimaryPlayer()` + `move-result-object vX` sequence, but the *instruction sequence at the start* of `enter(...)` changed.

The prebuilt patch used an opcode fingerprint that assumed an older method shape. In `3.0.438.2347`, the fingerprint no longer matched, so ReVanced CLI reported a fingerprint match failure and injected nothing.

## APK Analysis Approach (How To Verify The Hook Point)
1. Decompile both a known-good APK and the new APK (apktool is enough):
   - Find `ServerInsertedAdBreakState.smali`.
   - Locate `enter(Lcom/amazon/avod/fsm/Trigger;)V`.
2. Confirm the method still obtains the primary player:
   - `invoke-virtual {v?}, ...->getPrimaryPlayer()Lcom/amazon/avod/media/playback/VideoPlayer;`
   - `move-result-object v?`
3. This is the stable anchor for injection.

## ReVanced Patch Changes (To Support New Method Shapes)
We modified the local ReVanced patch implementation (not upstream) to:

1. Relax the fingerprint for `ServerInsertedAdBreakState.enter(...)`:
   - Instead of matching a fixed opcode prefix, match only:
     - method name: `enter`
     - class: `ServerInsertedAdBreakState`
     - signature: `(Lcom/amazon/avod/fsm/Trigger;)V`

2. Make the injection point dynamic:
   - Scan the method implementation instructions.
   - Find the `INVOKE_VIRTUAL` whose reference is a `MethodReference` with:
     - `name == "getPrimaryPlayer"`
     - `returnType == "Lcom/amazon/avod/media/playback/VideoPlayer;"`
   - Validate the next instruction is `MOVE_RESULT_OBJECT` and read its register.
   - Inject the call + `return-void` immediately after.

These changes are captured as a patch file:
- `patches/revanced-primevideo-skipads.patch`

## Local Build Was Not Straightforward (Key Blockers + Fixes)
### 1) Java version
Gradle Kotlin DSL evaluation failed on the workspace default JDK (Java 25).
Fix: use a JDK 21 for building ReVanced patches.

This workspace downloads/extracts JDK 21 to:
- `/tmp/temurin21`

### 2) GitHub Packages authentication
The ReVanced build depends on artifacts from GitHub Packages (`maven.pkg.github.com/revanced/registry`).
Fix: provide credentials in:
- `/tmp/gradle-home-revanced-patches/gradle.properties`

Keys:
- `githubPackagesUsername=<github username>`
- `githubPackagesPassword=<token>`

### 3) Dependency repositories
`settings.gradle.kts` originally configured GitHub Packages only for *plugin management*.
Gradle dependency resolution for `app.revanced:revanced-patcher` also needs that repo.
Fix: add `dependencyResolutionManagement { repositories { ... githubPackages ... } }`.

### 4) Android SDK
ReVanced patch build compiles Android extensions and needs an Android SDK.
Fix: install a minimal SDK into:
- `/tmp/android-sdk`

and create:
- `analysis/revanced-patches/local.properties` with `sdk.dir=/tmp/android-sdk`

### 5) Picking the correct `.rvp`
The Gradle build produces multiple `.rvp` files (e.g. `*-sources.rvp`, `*-javadoc.rvp`).
ReVanced CLI may “load” these but you won’t actually get executable patches.
Fix: choose only the main artifact:
- `analysis/revanced-patches/patches/build/libs/patches-*.rvp`

### 6) Proving the patch actually injected
Do not trust “Saved to …apk” alone.
Verify by decompiling the patched APK and searching for:
- `Lapp/revanced/extension/primevideo/ads/SkipAdsPatch;->enterServerInsertedAdBreakState`

## How To Patch A New APK Version
When `prime-<new>.apk` appears:

1. Run the script (builds a custom `.rvp`, then patches):
   - `analysis/scripts/patch-primevideo-skipads.sh <input.apk> <output.apk>`

2. If patching fails or doesn’t inject:
   - Decompile the new APK and confirm the anchor still exists:
     - `getPrimaryPlayer()` call + `move-result-object`
   - If the player getter changed name/signature, update the instruction scan in:
     - `analysis/revanced-patches/patches/.../SkipAdsPatch.kt`
   - If the target method signature changed, update:
     - `analysis/revanced-patches/patches/.../Fingerprints.kt`

3. Rebuild `.rvp` and re-run ReVanced CLI.

4. Re-verify injection in the patched APK.

## Files To Look At
- Script:
  - `analysis/scripts/patch-primevideo-skipads.sh`
- Patch bundle diff applied to ReVanced patches:
  - `patches/revanced-primevideo-skipads.patch`
- Modified ReVanced patch sources (inside submodule working tree after patch apply):
  - `analysis/revanced-patches/patches/src/main/kotlin/app/revanced/patches/primevideo/ads/Fingerprints.kt`
  - `analysis/revanced-patches/patches/src/main/kotlin/app/revanced/patches/primevideo/ads/SkipAdsPatch.kt`

