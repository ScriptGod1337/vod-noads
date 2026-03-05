package app.revanced.patches.netflix.ads

import app.revanced.patcher.fingerprint

// --- Patch 1: Disable pause ads feature flag ---

/**
 * PauseAdsFeatureFlagHelperImpl.e() — the main gate method.
 *
 * Obfuscated class: Lo/fVb; (implements Lo/fUW;)
 * Method: e()Z — returns true if pause ads should be shown.
 *
 * Identified via PlayerFragmentV2.C() which contains unique log strings
 * "Pause Ads: Video view is null..." and calls fUW.e()Z as the primary gate.
 *
 * The fingerprint targets PlayerFragmentV2.C() (the caller) because it has
 * stable log strings that survive obfuscation. The patch then navigates to
 * the feature flag helper class from the call site.
 */
internal val pauseAdsPlayerGateFingerprint = fingerprint {
    strings(
        "Pause Ads: Video view is null. Cannot show pause ad.",
        "Pause Ads: Playable is null. Cannot show pause ad.",
    )
    returns("V")
}

/**
 * PauseAdsPrefetchPresenterImpl — prefetches pause ad data.
 *
 * Contains log strings like "Pause Ads: prefetching adUrl " and
 * "Pause Ads: ad content error for " which are stable identifiers.
 *
 * The present() coroutine calls fUW.e()Z as the "should show ad?" gate,
 * then proceeds to fetch ad data from PauseAdsRepositoryImpl.
 */
internal val pauseAdsPrefetchFingerprint = fingerprint {
    strings("Pause Ads: prefetching adUrl ")
    returns("V")
}

/**
 * PauseAdsPrefetchPresenterImpl error handler.
 *
 * Contains "Pause Ads: fetching ad data failed." and
 * "Pause Ads: ad content error for " strings.
 */
internal val pauseAdsPrefetchErrorFingerprint = fingerprint {
    strings("Pause Ads: fetching ad data failed.")
    returns("V")
}

// --- Patch 2: Disable pause ad event tracking (optional) ---

/**
 * Pause ad event logger — fires AdDisplayPauseEvent beacons.
 *
 * Obfuscated class: Lo/fVc; — calls fUW.a() and fUW.d() to gate
 * whether to log ad impression/viewability events.
 *
 * Identified by the PauseAdsUiState toString pattern.
 */
internal val pauseAdsUiStateFingerprint = fingerprint {
    strings("PauseAdsUiState(adUrl=")
    returns("Ljava/lang/String;")
}
