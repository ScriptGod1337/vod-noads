package app.revanced.patches.hbomax.ads

import app.revanced.patcher.extensions.InstructionExtensions.addInstruction
import app.revanced.patcher.extensions.InstructionExtensions.getInstruction
import app.revanced.patcher.extensions.InstructionExtensions.replaceInstructions
import app.revanced.patcher.patch.bytecodePatch
import com.android.tools.smali.dexlib2.Opcode
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction

// =============================================================================
// Patch 1: Force ad-free strategy
// =============================================================================

val forceAdFreeStrategyPatch = bytecodePatch(
    name = "Force ad-free strategy",
    description = "Forces BoltAdStrategyMapper to always return \"ad_free\", disabling ad modules.",
) {
    compatibleWith("com.hbo.hbonow"("6.16.2.2"))

    execute {
        // BoltAdStrategyMapper.map() checks for "ad_free" in the strategies array,
        // then "ad_light", with "ad_full" as fallback.
        // We replace the entire method body to always return "ad_free".
        boltAdStrategyMapperFingerprint.method.replaceInstructions(
            0,
            """
                const-string v0, "ad_free"
                return-object v0
            """,
        )
    }
}

// =============================================================================
// Patch 2: Disable pause ads
// =============================================================================

val disablePauseAdsPatch = bytecodePatch(
    name = "Disable pause ads",
    description = "Prevents pause ads from being shown by no-opping the pause ad interactor and use cases.",
) {
    compatibleWith("com.hbo.hbonow"("6.16.2.2"))

    execute {
        // No-op PauseAdsInteractor.listen() — prevents subscribing to player pause events.
        // Without this subscription, the interactor never triggers pause ad display.
        pauseAdsInteractorListenFingerprint.method.addInstruction(0, "return-void")

        // No-op ShowDynamicPauseAdUseCase — prevents dynamic (on-demand fetched) pause ads.
        showDynamicPauseAdFingerprint.method.addInstruction(0, "return-void")

        // No-op ShowPauseAdUseCase — prevents static (pre-loaded from metadata) pause ads.
        showStaticPauseAdFingerprint.method.addInstruction(0, "return-void")
    }
}

// =============================================================================
// Patch 3: Auto-skip SSAI ad breaks
// =============================================================================

val autoSkipAdBreaksPatch = bytecodePatch(
    name = "Auto-skip ad breaks",
    description = "Automatically skips SSAI ad breaks by reusing HBO's built-in skip logic for already-watched breaks.",
) {
    compatibleWith("com.hbo.hbonow"("6.16.2.2"))

    execute {
        // --- a) Auto-skip during normal playback ---
        //
        // AdSkipModule.onAdBreakWillStart() is called when playback reaches an ad break.
        // It checks state.watchedSlots.contains(adBreakIndex):
        //   - If true (already watched) → auto-skips to nextChapterStart() (content after ad)
        //   - If false (unwatched) → forces user to watch via FORCE_WATCH seek
        //
        // We force the Set.contains() result to true so every ad break is treated as
        // "already watched", triggering the existing auto-skip path. This means the
        // player automatically jumps to content after the ad break — no manual seeking.
        onAdBreakWillStartFingerprint.method.let { method ->
            val instructions = method.implementation!!.instructions

            // Find the Set.contains() call that checks if the ad break was watched.
            // Pattern: invoke-interface vN, vM, Ljava/util/Set;->contains(Ljava/lang/Object;)Z
            val containsIndex = instructions.indexOfFirst { inst ->
                inst.opcode == Opcode.INVOKE_INTERFACE &&
                    (inst as? ReferenceInstruction)?.reference?.toString()
                        ?.contains("Set;->contains") == true
            }

            if (containsIndex >= 0) {
                val moveResultIndex = containsIndex + 1
                val moveResultInstr = instructions.elementAt(moveResultIndex)
                if (moveResultInstr.opcode == Opcode.MOVE_RESULT) {
                    val resultRegister = (moveResultInstr as OneRegisterInstruction).registerA
                    // Force result to 1 (true) = "already watched" → triggers auto-skip
                    method.addInstruction(
                        moveResultIndex + 1,
                        "const/4 v$resultRegister, 0x1",
                    )
                }
            }
        }

        // --- b) Allow manual seeking past ad breaks ---
        //
        // Even with auto-skip, the user might try to manually seek forward over an
        // ad break (e.g., scrubbing the timeline). Without this, the AdSkipModule
        // would intercept the seek and snap back.
        adSkipModuleSkipFingerprint.method.addInstruction(0, "return-void")
        adSkipModuleRedirectFingerprint.method.addInstruction(0, "return-void")
    }
}

// =============================================================================
// Patch 4: Disable ad tracking (optional)
// =============================================================================

val disableAdTrackingPatch = bytecodePatch(
    name = "Disable ad tracking",
    description = "Suppresses SSAI beacon and pause ad tracking requests.",
    use = false, // Disabled by default — user must opt in
) {
    compatibleWith("com.hbo.hbonow"("6.16.2.2"))

    execute {
        // No-op the SSAI beacon repository to prevent impression/quartile beacon HTTP requests.
        ssaiBeaconRepositoryFingerprint.method.addInstruction(0, "return-void")

        // No-op the pause ad beacon emitter to prevent pause ad impression tracking.
        pauseAdBeaconEmitterFingerprint.method.addInstruction(0, "return-void")

        // No-op the pause ad beacon dispatch use case.
        dispatchPauseAdBeaconFingerprint.method.addInstruction(0, "return-void")
    }
}
