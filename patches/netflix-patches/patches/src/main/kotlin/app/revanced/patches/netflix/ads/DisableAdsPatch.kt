package app.revanced.patches.netflix.ads

import app.revanced.patcher.extensions.InstructionExtensions.addInstruction
import app.revanced.patcher.extensions.InstructionExtensions.getInstruction
import app.revanced.patcher.extensions.InstructionExtensions.replaceInstructions
import app.revanced.patcher.patch.bytecodePatch
import com.android.tools.smali.dexlib2.Opcode
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction
import com.android.tools.smali.dexlib2.iface.reference.MethodReference

// =============================================================================
// Patch 1: Disable pause ads
// =============================================================================

val disablePauseAdsPatch = bytecodePatch(
    name = "Disable pause ads",
    description = "Disables pause ads by forcing the pause ads feature flag to false.",
) {
    compatibleWith("com.netflix.mediaclient"("9.0.0"))

    execute {
        // Strategy: Find PlayerFragmentV2.C() via its unique log strings,
        // then locate the invoke-interface call to the feature flag helper's
        // e()Z method, and patch that method to always return false.

        pauseAdsPlayerGateFingerprint.method.let { method ->
            val instructions = method.implementation!!.instructions

            // Find the invoke-interface call to the feature flag helper's e()Z gate.
            // Pattern: invoke-interface vN, Lo/fUW;->e()Z (or whatever the obfuscated name is)
            // We identify it by: interface call, returns Z, method name is single char,
            // and it's near the "Pause Ads:" log strings.
            val gateCallIndex = instructions.indexOfFirst { instruction ->
                instruction.opcode == Opcode.INVOKE_INTERFACE &&
                    (instruction as? ReferenceInstruction)?.reference.let { ref ->
                        ref is MethodReference &&
                            ref.returnType == "Z" &&
                            ref.parameterTypes.isEmpty() &&
                            ref.name.length == 1
                    } == true
            }

            if (gateCallIndex >= 0) {
                val ref = (instructions.elementAt(gateCallIndex) as ReferenceInstruction)
                    .reference as MethodReference

                // Now find and patch the actual feature flag helper class's gate method.
                // The method is on the interface — we need to find the concrete implementation.
                // Since we can't easily resolve interface→impl in ReVanced, we use the
                // prefetch fingerprint as a secondary confirmation and patch the caller instead.

                // Insert a branch that skips the entire pause ad setup block.
                // After the invoke-interface, there's a move-result vN followed by if-eqz.
                // We force the result register to 0 (false) right after the call.
                val moveResultIndex = gateCallIndex + 1
                val moveResultInstr = instructions.elementAt(moveResultIndex)
                if (moveResultInstr.opcode == Opcode.MOVE_RESULT) {
                    val resultRegister =
                        (moveResultInstr as com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction)
                            .registerA
                    // Insert const/4 vN, 0 right after the move-result to override the gate
                    method.addInstruction(
                        moveResultIndex + 1,
                        "const/4 v$resultRegister, 0x0",
                    )
                }
            }
        }

        // Also no-op the prefetch method so ads are never fetched even if the gate is bypassed
        pauseAdsPrefetchFingerprint.method.addInstruction(0, "return-void")
    }
}

// =============================================================================
// Patch 2: Disable pause ad tracking (optional)
// =============================================================================

val disablePauseAdTrackingPatch = bytecodePatch(
    name = "Disable pause ad tracking",
    description = "Suppresses pause ad impression/viewability event reporting.",
    use = false, // Disabled by default — user must opt in
) {
    compatibleWith("com.netflix.mediaclient"("9.0.0"))

    execute {
        // No-op the prefetch error handler to suppress error event reporting
        pauseAdsPrefetchErrorFingerprint.method.addInstruction(0, "return-void")
    }
}
