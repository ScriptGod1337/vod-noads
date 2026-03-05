package app.revanced.patches.hbomax.ads

import app.revanced.patcher.fingerprint

// =============================================================================
// Patch 1: Force ad_free strategy
// =============================================================================

/**
 * BoltAdStrategyMapper.map() — resolves the ad strategy from a server-provided array.
 *
 * Class: com.discovery.player.utils.adstrategy.BoltAdStrategyMapper
 * Method: map([Ljava/lang/String;)Ljava/lang/String;
 *
 * The method checks for "ad_free" first, then "ad_light", with "ad_full" as fallback.
 * Identified by the "ad_free" and "ad_light" string constants used in array-contains checks.
 */
internal val boltAdStrategyMapperFingerprint = fingerprint {
    strings("ad_free", "ad_light", "ad_full")
    returns("Ljava/lang/String;")
    parameters("[Ljava/lang/String;")
}

// =============================================================================
// Patch 2: Disable pause ads
// =============================================================================

/**
 * PauseAdsInteractor.listen() — entry point that subscribes to player pause events.
 *
 * Class: com.discovery.adtech.pauseads.domain.interactor.PauseAdsInteractor
 * Method: listen(PlayerEvents, Continuation)Object
 *
 * Identified by the log string emitted when a pause event is detected.
 */
internal val pauseAdsInteractorListenFingerprint = fingerprint {
    strings("Detected player is paused. PauseAd will be shown after a delay.")
}

/**
 * ShowDynamicPauseAdUseCase — fetches and shows dynamic pause ads.
 *
 * Class: com.discovery.adtech.pauseads.domain.interactor.ShowDynamicPauseAdUseCase
 *
 * Identified by its unique log string for canceling in-flight requests.
 */
internal val showDynamicPauseAdFingerprint = fingerprint {
    strings("Canceling old pause ad request if active")
}

/**
 * ShowPauseAdUseCase — shows static pause ads from stream metadata.
 *
 * Class: com.discovery.adtech.pauseads.domain.interactor.ShowPauseAdUseCase
 *
 * Identified by the "Attempting to show" log string.
 */
internal val showStaticPauseAdFingerprint = fingerprint {
    strings("Attempting to show pause ad after player paused and idle...")
}

// =============================================================================
// Patch 3: Auto-skip SSAI ad breaks
// =============================================================================

/**
 * AdSkipModule.onAdBreakWillStart() — called when playback reaches an ad break.
 *
 * Class: com.discovery.adtech.adskip.AdSkipModule
 * Method: onAdBreakWillStart(AdBreakEvent$AdBreakWillStart)V
 *
 * This method checks `state.watchedSlots.contains(adBreakIndex)`. If the break
 * was already watched, it auto-skips to the next chapter via `nextChapterStart()`.
 * If unwatched, it forces the user to watch via `FORCE_WATCH`.
 *
 * By forcing the contains() result to true, every break is treated as
 * "already watched" and the existing auto-skip logic handles the rest.
 *
 * Matched by class name + method name (non-obfuscated).
 */
internal val onAdBreakWillStartFingerprint = fingerprint {
    custom { method, classDef ->
        classDef.type == "Lcom/discovery/adtech/adskip/AdSkipModule;" &&
            method.name == "onAdBreakWillStart"
    }
}

/**
 * AdSkipModule — handles seek interception over unwatched ad breaks.
 *
 * Class: com.discovery.adtech.adskip.AdSkipModule
 *
 * The "Skipping an adbreak" string is logged when the module decides to skip/redirect.
 * No-opping this allows manual seeking past unwatched ad breaks.
 */
internal val adSkipModuleSkipFingerprint = fingerprint {
    strings("AdSkipModule Skipping an adbreak ")
}

/**
 * AdSkipModule — companion method that redirects to a new ad break.
 *
 * Identified by "AdSkipModule Skipping to " log string.
 */
internal val adSkipModuleRedirectFingerprint = fingerprint {
    strings("AdSkipModule Skipping to ")
}

// =============================================================================
// Patch 4: Disable SSAI beaconing (optional, tracking suppression)
// =============================================================================

/**
 * SsaiClientSideBeaconRepositoryImpl — sends HTTP beacon requests for SSAI ads.
 *
 * Class: com.discovery.adtech.ssaibeaconing.repository.SsaiClientSideBeaconRepositoryImpl
 *
 * Identified by the class reference string used in logging.
 */
internal val ssaiBeaconRepositoryFingerprint = fingerprint {
    strings("SsaiClientSideBeaconRepositoryImpl")
    returns("V")
}

/**
 * PauseAdsBeaconEmitterImpl — fires HTTP beacons for pause ad impressions/completions.
 *
 * Class: com.discovery.adtech.pauseads.beacons.PauseAdsBeaconEmitterImpl
 *
 * Identified by the " for PauseAd beacon " log string.
 */
internal val pauseAdBeaconEmitterFingerprint = fingerprint {
    strings(" for PauseAd beacon ")
}

/**
 * DispatchPauseAdBeaconUseCase — orchestrates pause ad beacon dispatch.
 *
 * Class: com.discovery.adtech.pauseads.domain.interactor.DispatchPauseAdBeaconUseCase
 *
 * Identified by the Kotlin file name string (used in stack traces / logging).
 */
internal val dispatchPauseAdBeaconFingerprint = fingerprint {
    strings("DispatchPauseAdBeaconUseCase.kt")
    returns("V")
}
