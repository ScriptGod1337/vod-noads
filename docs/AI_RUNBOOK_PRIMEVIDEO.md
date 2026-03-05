# AI Runbook: Prime Video Skip-Ads (ReVanced CLI)

This runbook explains what was done in this workspace to patch Amazon Prime Video APKs using a locally-built ReVanced `.rvp`, and what to do when a new APK version stops matching.

## Target Behavior
Patch `com.amazon.avod.thirdpartyclient` so server-inserted ad breaks are skipped.

Upstream intent (ReVanced):
- Hook `com.amazon.avod.media.ads.internal.state.ServerInsertedAdBreakState.enter(Lcom/amazon/avod/fsm/Trigger;)V`.
- Right after the app obtains the primary `VideoPlayer` (via `getPrimaryPlayer()`), call the ReVanced Prime Video extension:
  - `Lapp/revanced/extension/primevideo/ads/SkipAdsPatch;->enterServerInsertedAdBreakState(state, trigger, player)`
- Return immediately so the original ad-break playback logic is bypassed.

## What Broke Per Version

### 3.0.438.2347
The *method still contains* a `getPrimaryPlayer()` + `move-result-object vX` sequence, but the *instruction sequence at the start* of `enter(...)` changed.

The prebuilt patch used an opcode fingerprint that assumed an older method shape. In `3.0.438.2347`, the fingerprint no longer matched, so ReVanced CLI reported a fingerprint match failure and injected nothing.

Fix: removed the opcode sequence from `enterServerInsertedAdBreakStateFingerprint` and made the injection point dynamic (scan for `getPrimaryPlayer()` call at runtime).

### 3.0.444.557
The `doTrigger()` method in `StateBase` changed visibility from `protected` to `public`.

The `doTriggerFingerprint` used `accessFlags(AccessFlags.PROTECTED)` which no longer matched.

Fix: changed to `accessFlags(AccessFlags.PUBLIC)` in `Fingerprints.kt`.

## APK Analysis Approach (How To Verify The Hook Point)
1. Decompile the new APK with apktool:
   ```bash
   java -jar analysis/tools/revanced/apktool.jar d -f -r <input.apk> -o /tmp/apk-smali
   ```
2. Find `ServerInsertedAdBreakState.smali` and check `enter(Lcom/amazon/avod/fsm/Trigger;)V`:
   - Confirm `invoke-virtual {v?}, ...->getPrimaryPlayer()Lcom/amazon/avod/media/playback/VideoPlayer;`
   - Confirm `move-result-object v?` follows it
3. Find `StateBase.smali` and check `doTrigger(...)`:
   - Note the access modifier (`.method public` vs `.method protected`)
   - Confirm opcodes still: `iget-object`, `invoke-interface`, `return-void`
4. These are the two stable anchors. If either changes, update `Fingerprints.kt`.

## ReVanced Patch Changes (Applied via patch file)
The patch at `patches/revanced-primevideo-skipads.patch` modifies the upstream `vendor/revanced-patches` submodule to:

1. **`Fingerprints.kt`** — Relax `enterServerInsertedAdBreakStateFingerprint`:
   - No opcode sequence; match only by class + method name + signature
   - Change `doTriggerFingerprint` to `accessFlags(AccessFlags.PUBLIC)`

2. **`SkipAdsPatch.kt`** — Make injection point dynamic:
   - Scan method instructions for `INVOKE_VIRTUAL` referencing `getPrimaryPlayer()`
   - Validate next instruction is `MOVE_RESULT_OBJECT` and read its register
   - Inject the extension call + `return-void` immediately after

3. **`settings.gradle.kts`** — Add `dependencyResolutionManagement` block with GitHub Packages repo so Gradle can resolve `app.revanced:revanced-patcher`.

## Local Build Blockers + Fixes

### 1) Java version
Gradle Kotlin DSL evaluation fails on JDK > 21.
Fix: script auto-downloads JDK 21 (Temurin) to `/tmp/temurin21`.

### 2) GitHub Packages authentication
The ReVanced build requires a GitHub PAT with `read:packages` scope.
Fix: provide credentials in `/tmp/gradle-home-revanced-patches/gradle.properties`:
```
githubPackagesUsername=<github username>
githubPackagesPassword=<token>
```
Or pass via `--gh-user` / `--gh-token` flags to the patch script.

### 3) Android SDK
Compiling Android extensions requires the Android SDK.
Fix: script auto-installs a minimal SDK to `/tmp/android-sdk` (platform-tools, platforms;android-34, build-tools;34.0.0) and writes `local.properties`.

### 4) ripgrep (`rg`) not available in container
The patch script originally required `rg`. The container runs with `no new privileges` so `apt-get` cannot be used.
Fix: script was updated to use `grep` and `find` instead.

### 5) Script ROOT_DIR path
The script lives at `analysis/primevideo/scripts/` (3 levels deep), so `ROOT_DIR` must be `../../../` not `../../`.
Fix: corrected in the script.

### 6) `analysis/revanced-patches` symlink
The script expects the patches repo at `analysis/revanced-patches/` but the submodule is at `vendor/revanced-patches`.
Fix: create a symlink:
```bash
ln -s /home/vscode/vod-noads/vendor/revanced-patches /home/vscode/vod-noads/analysis/revanced-patches
```

### 7) Gradle build cache serves stale artifacts after `clean`
`./gradlew :patches:clean :patches:build` can still serve the old compiled Kotlin from the build cache.
Fix: always use `--no-build-cache` when rebuilding after source changes:
```bash
./gradlew :patches:clean :patches:build --no-build-cache
```
The patch script calls Gradle via `bash ./gradlew` (not `./gradlew` directly) because the container may lack `uname`/`xargs` in the default PATH used by the shebang.

### 8) Proving the patch actually injected
Do not trust "Saved to …apk" alone — ReVanced CLI saves the APK even when a patch fails.
Verify by decompiling the patched APK and checking:
```bash
java -jar analysis/tools/revanced/apktool.jar d -f -r <patched.apk> -o /tmp/verify
grep -r 'Lapp/revanced/extension/primevideo/ads/SkipAdsPatch;->enterServerInsertedAdBreakState' /tmp/verify
```

## How To Patch A New APK Version
When `prime-<new>.apk` appears:

1. Set up prerequisites (one-time per session):
   ```bash
   mkdir -p /tmp/gradle-home-revanced-patches
   cat > /tmp/gradle-home-revanced-patches/gradle.properties <<EOF
   githubPackagesUsername=<your-github-username>
   githubPackagesPassword=<your-github-pat>
   EOF

   ln -sf /home/vscode/vod-noads/vendor/revanced-patches /home/vscode/vod-noads/analysis/revanced-patches
   ```

2. Run the patch script:
   ```bash
   cd /home/vscode/vod-noads
   bash analysis/primevideo/scripts/patch-primevideo-skipads.sh \
     apks/<input.apk> apks/<output.apk>
   ```

3. If "Skip ads" fails with fingerprint error:
   - Decompile the APK and check `StateBase.smali` → `doTrigger()` access modifier
   - Check `ServerInsertedAdBreakState.smali` → `enter()` still has `getPrimaryPlayer()` call
   - Update `Fingerprints.kt` in `vendor/revanced-patches` accordingly
   - Rebuild with `--no-build-cache` and re-run ReVanced CLI
   - Re-verify injection in the patched APK
   - Regenerate the patch file: `git -C vendor/revanced-patches diff > patches/revanced-primevideo-skipads.patch`

4. Add the new version to `compatibleWith(...)` in `SkipAdsPatch.kt` and update `patches/primevideo-patches/README.md`.

## Files To Look At
- Patch script: `analysis/primevideo/scripts/patch-primevideo-skipads.sh`
- Patch bundle diff: `patches/revanced-primevideo-skipads.patch`
- Modified sources (after applying patch to submodule):
  - `vendor/revanced-patches/patches/src/main/kotlin/app/revanced/patches/primevideo/ads/Fingerprints.kt`
  - `vendor/revanced-patches/patches/src/main/kotlin/app/revanced/patches/primevideo/ads/SkipAdsPatch.kt`
  - `vendor/revanced-patches/settings.gradle.kts`
- Compatible versions + how-it-works: `patches/primevideo-patches/README.md`
