package app.revanced.patches.primevideo.ads

import app.revanced.patcher.extensions.InstructionExtensions.addInstructions
import app.revanced.patcher.extensions.InstructionExtensions.instructions
import app.revanced.patcher.patch.bytecodePatch
import app.revanced.patches.primevideo.misc.extension.sharedExtensionPatch
import com.android.tools.smali.dexlib2.AccessFlags
import com.android.tools.smali.dexlib2.Opcode
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction
import com.android.tools.smali.dexlib2.iface.reference.MethodReference

@Suppress("unused")
val skipAdsPatch = bytecodePatch(
    name = "Skip ads",
    description = "Automatically skips video stream ads.",
) {
    compatibleWith(
        "com.amazon.avod.thirdpartyclient"(
            "3.0.412.2947",
            "3.0.438.2347"
        )
    )

    dependsOn(sharedExtensionPatch)

    // Skip all the logic in ServerInsertedAdBreakState.enter(), which plays all the ad clips in this
    // ad break. Instead, force the video player to seek over the entire break and reset the state machine.
    execute {
        // Force doTrigger() access to public so we can call it from our extension.
        doTriggerFingerprint.method.accessFlags = AccessFlags.PUBLIC.value;

        enterServerInsertedAdBreakStateFingerprint.method.apply {
            val implementation = implementation ?: throw IllegalStateException("Missing implementation for ServerInsertedAdBreakState.enter()")

            // Find the instruction where we obtain the primary VideoPlayer:
            //  invoke-virtual ... ->getPrimaryPlayer()Lcom/amazon/avod/media/playback/VideoPlayer;
            //  move-result-object vX
            val (getPlayerIndex, playerRegister) = implementation.instructions.withIndex().firstNotNullOf { (index, instruction) ->
                if (instruction.opcode != Opcode.INVOKE_VIRTUAL) return@firstNotNullOf null

                val methodRef = (instruction as ReferenceInstruction).reference as? MethodReference ?: return@firstNotNullOf null
                if (methodRef.name != "getPrimaryPlayer" || methodRef.returnType != "Lcom/amazon/avod/media/playback/VideoPlayer;") {
                    return@firstNotNullOf null
                }

                val moveResult = implementation.instructions.getOrNull(index + 1) ?: return@firstNotNullOf null
                if (moveResult.opcode != Opcode.MOVE_RESULT_OBJECT) return@firstNotNullOf null

                val reg = (moveResult as OneRegisterInstruction).registerA
                Pair(index, reg)
            }

            // NOTE: We don't rely on a fixed opcode fingerprint index because newer Prime builds
            // add setup/cast instructions at the beginning of the method.

            // Reuse the params from the original method:
            //  p0 = ServerInsertedAdBreakState
            //  p1 = AdBreakTrigger
            addInstructions(
                getPlayerIndex + 2,
                """
                    invoke-static { p0, p1, v$playerRegister }, Lapp/revanced/extension/primevideo/ads/SkipAdsPatch;->enterServerInsertedAdBreakState(Lcom/amazon/avod/media/ads/internal/state/ServerInsertedAdBreakState;Lcom/amazon/avod/media/ads/internal/state/AdBreakTrigger;Lcom/amazon/avod/media/playback/VideoPlayer;)V
                    return-void
                """
            )
        }
    }
}
