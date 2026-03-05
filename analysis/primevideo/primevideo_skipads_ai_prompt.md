# AI Agent Prompt: Analyze and Patch Prime Video Skip-Ads

You are an AI coding/reverse-engineering agent working in a local workspace with APK files and a cloned ReVanced repository.

## Objective
Analyze and patch Amazon Prime Video APKs so stream ads are skipped safely, using ReVanced Prime Video skip-ads logic as the baseline reference.

## Reference Links (must be used)
- ReVanced patch catalog entry (Prime):
  - https://revanced.app/patches?s=amazon
- Sample patch source to map behavior from (Prime Video Skip Ads):
  - https://github.com/ReVanced/revanced-patches/blob/main/patches/src/main/kotlin/app/revanced/patches/primevideo/ads/SkipAdsPatch.kt
- Related fingerprints:
  - https://github.com/ReVanced/revanced-patches/blob/main/patches/src/main/kotlin/app/revanced/patches/primevideo/ads/Fingerprints.kt
- Related extension implementation:
  - https://github.com/ReVanced/revanced-patches/blob/main/extensions/primevideo/src/main/java/app/revanced/extension/primevideo/ads/SkipAdsPatch.java

## Prime Mapping (what this patch targets)
Map the patch to these Prime classes and behaviors:
- Target method hook:
  - `com.amazon.avod.media.ads.internal.state.ServerInsertedAdBreakState.enter(Lcom/amazon/avod/fsm/Trigger;)V`
- Required trigger API:
  - `AdBreakTrigger.getSeekStartPosition()`
  - `AdBreakTrigger.getSeekTarget()`
  - `AdBreakTrigger.getBreak()`
- Required ad-break API:
  - `AdBreak.getDurationExcludingAux()`
- Required player/time API:
  - `VideoPlayer.getCurrentPosition()`
  - `VideoPlayer.seekTo(long)`
  - `TimeSpan.getTotalMilliseconds()`
- State machine transition:
  - `new SimpleTrigger(AdEnabledPlayerTriggerType.NO_MORE_ADS_SKIP_TRANSITION)`
  - `StateBase.doTrigger(Trigger)`

## Required Workflow
1. Identify APK targets (old known-good + latest).
2. Decompile both APKs (smali-level is sufficient for patching).
3. Compare target method shape in both versions.
4. Decide if upstream fingerprint is still valid.
5. If incompatible, adapt patch anchor safely.
6. Implement patch pipeline script:
   - prefer dex-only patching when possible (update a single `classesN.dex`, then resign)
   - otherwise: decompile (apktool) -> inject smali -> rebuild -> sign
7. Add strict fail-safe checks:
   - required symbol/class/method existence checks
   - anchor state classification: `clean`, `patched`, `incompatible`
   - stop on `patched` (prevent double patch)
   - stop on `incompatible`
8. Add post-injection verification checks.
9. Add runtime safety behavior in injected code:
   - wrap injected logic in a `try/catch (Exception)` and exit the method (`return-void`) on failure
   - do not partially run injected logic and then continue into original `enter()` code (this can leave the state machine in a broken/undefined state)
10. Validate resulting APK:
   - zipalign/signature verified
   - patched block present in rebuilt smali
11. Provide exact commands and outputs summary.

## Safety Requirements
- Never silently patch if anchor does not match expected shape.
- Prefer preserving original APK structure if any ambiguity exists:
  - avoid full apktool rebuild for release APKs when possible; round-tripping resources/dex can cause runtime instability even if the smali change is correct.
- Any detected incompatibility must hard-fail with explicit reason.
- Prevent accidental re-patching of already patched APK.

## Dex/Smali Pitfalls (must handle)
- **Interface vs class invoke**: In some Prime builds (e.g. `3.0.438.2347`), `com.amazon.avod.media.playback.VideoPlayer` is an **interface**.
  - Calling it with `invoke-virtual` will crash at runtime with `IncompatibleClassChangeError`.
  - You must detect whether `VideoPlayer` is declared as an interface and then emit:
    - `invoke-interface` for `VideoPlayer.getCurrentPosition()` and `VideoPlayer.seekTo(J)`
    - `invoke-virtual` only if it is a concrete class.
  - Detection options:
    - from smali header (apktool/baksmali output): `.class public interface abstract Lcom/amazon/avod/media/playback/VideoPlayer;`
    - from dex metadata: check the class_def `access_flags & ACC_INTERFACE`.
- **Rebuild fragility**: apktool reassembly can change multi-dex layout or resource table encoding and lead to subtle playback/UI issues.
  - Prefer a dex-only patch flow: disassemble one `classesN.dex` -> patch -> reassemble -> update only that entry in the APK -> resign.

## Signing Requirements
- Support default debug signing.
- Support optional custom keystore signing:
  - `--keystore`
  - `--ks-alias`
  - `--ks-pass`
  - `--key-pass`

## Runtime/Test Notes
- Same package name cannot be installed side-by-side with official Prime app unless signatures match.
- For testing patched APK with same package name, uninstall official app first.
- If crash occurs, capture logcat and iterate on smallest failing assumption (anchor/register/null-path/state transition).

## Known Latest-Version Hint (3.0.438.2347)
- Symptom seen in latest patch attempts:
  - app can crash during seeking with `java.lang.IncompatibleClassChangeError` if the injected code uses the wrong invoke opcode for `VideoPlayer`.
  - apktool-rebuilt APKs can show unstable player/UI behavior even when the injection “works” on paper.
- Fix pattern that worked:
  - keep the same anchor (right after `getPrimaryPlayer()` + `move-result-object vX`),
  - inject skip logic and then **unconditionally exit `enter()`** (`return-void`), matching the ReVanced approach,
  - ensure `VideoPlayer` calls use `invoke-interface` when `VideoPlayer` is an interface (common in 3.0.438.2347),
  - prefer dex-only patching (do not rebuild the whole APK with apktool unless you have to).

## Existing Local Script (use/update this first)
- `analysis/scripts/patch-primevideo-skipads.sh`
- If ReVanced CLI is unavailable or too heavy, prefer `analysis/scripts/patch-primevideo-skipads-dex.sh`.

## Definition of Done
- Patch script produces a signed patched APK for target version.
- Playback no longer crashes.
- Ad-skip logic is injected and verified in smali.
- Script fails safely on incompatible versions.
- Summary includes exact file changes, commands used, and generated APK paths.

## Related: Cast Playback Ads
If ads still appear when using "Cast to device", see `analysis/primevideo_cast_ads_ai_prompt.md` for an analysis workflow to determine whether cast ads are controlled by:
- server-side stream insertion,
- the receiver app/device,
- or client-side Android APK code.
