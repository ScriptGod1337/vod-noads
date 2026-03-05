package app.revanced.patches.disney.ads

import app.revanced.patcher.extensions.InstructionExtensions.addInstruction
import app.revanced.patcher.extensions.InstructionExtensions.addInstructions
import app.revanced.patcher.extensions.InstructionExtensions.getInstruction
import app.revanced.patcher.extensions.InstructionExtensions.replaceInstructions
import app.revanced.patcher.patch.bytecodePatch
import com.android.tools.smali.dexlib2.Opcode
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction

// =============================================================================
// Patch 1: Force noAds = true in SessionFeatures
// =============================================================================

val forceNoAdsPatch = bytecodePatch(
    name = "Force no-ads flag",
    description = "Forces SessionFeatures.noAds to true, enabling the ad-free experience.",
) {
    compatibleWith("com.disney.disneyplus"("26.1.2"))

    execute {
        // --- a) DSS SDK SessionFeatures constructor: force noAds param to true ---
        dssSessionFeaturesConstructorFingerprint.method.let { method ->
            // Find the iput-boolean instruction that stores the noAds field.
            val noAdsFieldIndex = method.implementation!!.instructions.indexOfFirst { instruction ->
                instruction.opcode == Opcode.IPUT_BOOLEAN &&
                    (instruction as? ReferenceInstruction)?.reference.toString()?.contains("noAds") == true
            }

            if (noAdsFieldIndex >= 0) {
                // The noAds param is in v3 for a (ZZZ)V constructor (p3 = v3 when no locals).
                // Insert const/4 v3, 0x1 right before the iput-boolean to force it true.
                method.addInstruction(
                    noAdsFieldIndex,
                    "const/4 v3, 0x1",
                )
            }
        }

        // --- b) Bamtech SessionFeatures constructor: force noAds fields ---
        bamtechSessionFeaturesConstructorFingerprint.method.let { method ->
            val instructions = method.implementation!!.instructions

            // Find all iput-boolean instructions and patch the noAds-equivalent fields.
            // Field ->c:Z is noAds (force true), field ->d:Z is adSuppression (force false).
            instructions.forEachIndexed { index, instruction ->
                if (instruction.opcode == Opcode.IPUT_BOOLEAN) {
                    val fieldRef = (instruction as? ReferenceInstruction)?.reference.toString() ?: return@forEachIndexed

                    when {
                        fieldRef.endsWith("->c:Z") -> {
                            // Force noAds = true: set register to 1 before the iput
                            method.addInstruction(index, "const/4 v3, 0x1")
                        }
                        fieldRef.endsWith("->d:Z") -> {
                            // Force adSuppression = false: set register to 0 before the iput
                            method.addInstruction(index, "const/4 v1, 0x0")
                        }
                    }
                }
            }
        }

        // --- c) Override getNoAds() to always return true ---
        getNoAdsFingerprint.method.let { method ->
            method.replaceInstructions(
                0,
                """
                    const/4 v0, 0x1
                    return v0
                """,
            )
        }
    }
}

// =============================================================================
// Patch 2: Disable interstitial ad scheduling and playback
// =============================================================================

val disableInterstitialsPatch = bytecodePatch(
    name = "Disable interstitial ads",
    description = "Prevents SGAI interstitial ads from being scheduled or played.",
) {
    compatibleWith("com.disney.disneyplus"("26.1.2"))

    execute {
        // No-op scheduleInterstitial() — prevent ad scheduling entirely
        scheduleInterstitialFingerprint.method.addInstruction(0, "return-void")

        // No-op playInterstitial() — prevent ad playback
        playInterstitialFingerprint.method.addInstruction(0, "return-void")

        // No-op onResolvingPreRoll() — prevent pre-roll ad loading
        onResolvingPreRollFingerprint.method.addInstruction(0, "return-void")
    }
}

// =============================================================================
// Patch 3: Disable ad tracking beacons (optional)
// =============================================================================

val disableAdTrackingPatch = bytecodePatch(
    name = "Disable ad tracking",
    description = "Suppresses ad beacon/telemetry requests to prevent Disney from detecting ad skipping.",
    use = false, // Disabled by default — user must opt in
) {
    compatibleWith("com.disney.disneyplus"("26.1.2"))

    execute {
        // No-op the beacon firing method so no tracking requests are sent
        adBeaconFingerprint.method.addInstruction(0, "return-void")
    }
}
