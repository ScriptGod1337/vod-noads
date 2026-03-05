package app.revanced.patches.disney.ads

import app.revanced.patcher.fingerprint

// --- Patch 1: Force noAds = true ---

/**
 * DSS SDK SessionFeatures constructor.
 * Class: com.dss.sdk.orchestration.common.SessionFeatures
 * Method: <init>(ZZZ)V — constructor with 3 boolean params, references "noAds" field.
 */
internal val dssSessionFeaturesConstructorFingerprint = fingerprint {
    strings("noAds")
    parameters("Z", "Z", "Z")
    returns("V")
    custom { method, _ ->
        method.name == "<init>"
    }
}

/**
 * Bamtech SessionFeatures constructor.
 * Class: com.bamtechmedia.dominguez.session.SessionState$ActiveSession$SessionFeatures
 * Method: <init>(ZZZ)V — constructor with 3 boolean params, uses xor-int/lit8 opcode.
 */
internal val bamtechSessionFeaturesConstructorFingerprint = fingerprint {
    parameters("Z", "Z", "Z")
    returns("V")
    opcodes(
        com.android.tools.smali.dexlib2.Opcode.XOR_INT_LIT8,
    )
    custom { method, _ ->
        method.name == "<init>" &&
            method.definingClass.contains("SessionFeatures") &&
            method.definingClass.contains("bamtechmedia")
    }
}

/**
 * DSS SDK SessionFeatures.getNoAds() getter.
 * Class: com.dss.sdk.orchestration.common.SessionFeatures
 * Method: getNoAds()Z — public method returning boolean.
 */
internal val getNoAdsFingerprint = fingerprint {
    returns("Z")
    strings("noAds")
    custom { method, _ ->
        method.name == "getNoAds"
    }
}

// --- Patch 2: Disable interstitial ad scheduling ---

/**
 * SgaiInterstitialController.scheduleInterstitial()
 * Identified by log string: "SgaiInterstitialController scheduleInterstitial()"
 */
internal val scheduleInterstitialFingerprint = fingerprint {
    strings("SgaiInterstitialController scheduleInterstitial()")
    returns("V")
}

/**
 * SgaiInterstitialController.playInterstitial()
 * Identified by log string: "SgaiInterstitialController playInterstitial()"
 */
internal val playInterstitialFingerprint = fingerprint {
    strings("SgaiInterstitialController playInterstitial()")
    returns("V")
}

/**
 * Pre-roll ad resolver callback.
 * Identified by log string: "onResolvingPreRoll() setting state to loadingAdPod"
 */
internal val onResolvingPreRollFingerprint = fingerprint {
    strings("onResolvingPreRoll() setting state to loadingAdPod")
    returns("V")
}

// --- Patch 3: Disable ad tracking beacons ---

/**
 * Beacon service configuration / firing method.
 * Identified by reference to "beaconUrl" string in the beacon service.
 */
internal val adBeaconFingerprint = fingerprint {
    strings("beaconUrl")
    returns("V")
}
