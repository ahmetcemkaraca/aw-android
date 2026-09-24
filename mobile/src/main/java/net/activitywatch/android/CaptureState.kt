package net.activitywatch.android

internal enum class CaptureState {
    RECORDING,
    PAUSED,
    PERMISSION_REQUIRED,
}

internal fun captureState(recordingEnabled: Boolean, usageAccessGranted: Boolean): CaptureState = when {
    !recordingEnabled -> CaptureState.PAUSED
    !usageAccessGranted -> CaptureState.PERMISSION_REQUIRED
    else -> CaptureState.RECORDING
}

internal data class CaptureSources(
    val usageStats: Boolean,
    val browser: Boolean,
    val media: Boolean,
)

internal fun captureSources(
    vaultReady: Boolean,
    recordingEnabled: Boolean,
    usageAccessGranted: Boolean,
    browserOptIn: Boolean,
    accessibilityGranted: Boolean,
    mediaOptIn: Boolean,
    notificationAccessGranted: Boolean,
): CaptureSources {
    val active = vaultReady && recordingEnabled
    return CaptureSources(
        usageStats = active && usageAccessGranted,
        browser = active && browserOptIn && accessibilityGranted,
        media = active && mediaOptIn && notificationAccessGranted,
    )
}
