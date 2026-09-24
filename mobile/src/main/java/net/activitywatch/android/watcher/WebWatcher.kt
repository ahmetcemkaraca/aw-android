package net.activitywatch.android.watcher

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import net.activitywatch.android.captureSources
import net.activitywatch.android.AWPreferences
import net.activitywatch.android.RustInterface
import org.json.JSONObject

private fun extractTextByViewId(event: AccessibilityEvent, viewId: String): String? {
    event.source?.let { source ->
        val nodes = source.findAccessibilityNodeInfosByViewId(viewId)
        try {
            return processExtractedText(nodes.firstOrNull()?.text?.toString())
        } finally {
            nodes.forEach { it.recycle() }
            source.recycle()
        }
    }
    return null
}

private val privateBrowsingIndicator = Regex("(?i)\\b(incognito|private browsing|private tab)\\b")

internal fun isPrivateBrowsingIndicator(text: String?): Boolean =
    text?.let(privateBrowsingIndicator::containsMatchIn) == true

class WebWatcher : AccessibilityService() {

    // The toolbar is a sibling of the content area, so we search from the window root.
    // findAccessibilityNodeInfosByViewId requires "package:id/name" format and silently
    // rejects bare testTag names, so we traverse manually.
    private fun extractFirefoxUrl(event: AccessibilityEvent): String? {
        val root = rootInActiveWindow ?: return null
        try {
            val found = findNode(root) { it.viewIdResourceName == "ADDRESSBAR_URL_BOX" }
            val result = parseFirefoxAddressBarContentDescription(found?.contentDescription?.toString())
            if (found !== root) found?.recycle()
            return result
        } finally {
            root.recycle()
        }
    }

    private val TAG = "WebWatcher"
    private val bucket_id = "aw-watcher-android-web"

    @Volatile private var ri : RustInterface? = null
    private var lastWindowId: Int? = null
    private val sessionTracker = BrowserSessionTracker()

    // Applies stripProtocol uniformly to whatever extractor matched, so the logged url is
    // formatted identically no matter which browser/view-variant produced it.
    private fun extractUrl(packageName: String, event: AccessibilityEvent): String? = when (packageName) {
        "com.android.chrome" -> extractTextByViewId(event, "com.android.chrome:id/url_bar")
        "org.mozilla.firefox" ->
            // Compose toolbar (current)
            extractFirefoxUrl(event)
                // View-based toolbar (older Firefox versions)
                ?: extractTextByViewId(event, "org.mozilla.firefox:id/url_bar_title")
                ?: extractTextByViewId(event, "org.mozilla.firefox:id/mozac_browser_toolbar_url_view")
        "com.sec.android.app.sbrowser" ->
            extractTextByViewId(event, "com.sec.android.app.sbrowser:id/location_bar_edit_text")
                ?: extractTextByViewId(event, "com.sec.android.app.sbrowser:id/custom_tab_toolbar_url_bar_text")
        "com.opera.browser" ->
            extractTextByViewId(event, "com.opera.browser:id/url_field")
                ?: extractTextByViewId(event, "com.opera.browser:id/address_field")
        "com.microsoft.emmx" -> extractTextByViewId(event, "com.microsoft.emmx:id/url_bar")
        else -> null
    }?.let(stripProtocol)

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Creating WebWatcher")
        try {
            ri = RustInterface(applicationContext).also { it.createBucketHelper(bucket_id, "web.tab.current") }
        } catch (ex: Throwable) {
            // Catch Throwable (not just Exception) because System.loadLibrary() throws
            // UnsatisfiedLinkError (an Error subclass) when the native library is missing.
                Log.e(TAG, "Failed to initialize RustInterface (${ex.javaClass.simpleName})")
        }
    }

    // TODO: This method is called very often, which might affect performance. Future optimizations needed.
    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        val preferences = AWPreferences(applicationContext)
        val browserCaptureAllowed = captureSources(
            vaultReady = ri?.needsVaultRecovery == false,
            recordingEnabled = preferences.isCaptureEnabled(),
            usageAccessGranted = false,
            browserOptIn = preferences.isBrowserCaptureEnabled(),
            accessibilityGranted = UsageStatsWatcher.isAccessibilityAllowed(applicationContext),
            mediaOptIn = false,
            notificationAccessGranted = false,
        ).browser
        if (!browserCaptureAllowed) {
            sessionTracker.discardCurrentSession()
            return
        }
        if (isPrivateBrowsingIndicator(event.contentDescription?.toString())
            || event.text.any { isPrivateBrowsingIndicator(it?.toString()) }) {
            sessionTracker.discardCurrentSession()
            lastWindowId = event.windowId
            return
        }
        if (shouldIgnoreEvent(event)) {
            return
        }

        val packageName = event.packageName?.toString()
        val isKnownBrowser = packageName != null && packageName in KNOWN_BROWSER_PACKAGES

        val windowChanged = windowChanged(event.windowId)
        lastWindowId = event.windowId

        if (!isKnownBrowser) {
            // for some browsers like Firefox event.packageName can be null (no extractor matched)
            // but we are still on the same window
            if (windowChanged) {
                Log.i(TAG, "Window changed away from a supported browser; ending the local session")
                handleUrl(null, newBrowser = null)
            }

            return
        }

        try {
            event.source?.let { source ->
                try {
                    val browser = packageName!!
                    val newUrl = extractUrl(browser, event)
                    val webView = findWebView(source)
                    val title = webView?.text?.toString()
                    if (webView != null && webView !== source) webView.recycle()
                    if (isPrivateBrowsingIndicator(title)) {
                        sessionTracker.discardCurrentSession()
                    } else {
                        if (newUrl == null) {
                            Log.d(TAG, "No supported URL was available from this browser event")
                        } else {
                            handleUrl(newUrl, newBrowser = browser)
                        }
                        title?.let(::handleWindowTitle)
                    }
                } finally {
                    source.recycle()
                }
            }
        } catch(ex : Exception) {
            Log.e(TAG, "Accessibility event processing failed (${ex.javaClass.simpleName})")
        }
    }

    private fun windowChanged(windowId: Int): Boolean = windowId != lastWindowId

    private fun shouldIgnoreEvent(event: AccessibilityEvent) =
        event.packageName == "com.android.systemui"

    // TODO(maintainer): this never finds a match for Firefox, so its page title is never
    // captured (logged events show title:""). Confirmed live on-device (2026-07-01, Fenix,
    // GeckoView content): dumping the full accessibility tree of rootInActiveWindow while a
    // real page was loaded showed `browserLayout` has exactly 3 children - a ComposeView
    // (whose only child had zero further descendants), an unexplained childless node with a
    // null className, and the toolbar (composable_toolbar, which is where ADDRESSBAR_URL_BOX
    // lives - see extractFirefoxUrl above). The page content is not a descendant of this
    // window's root at all, so no restructuring of findWebView's search root will find it.
    // GeckoView most likely exposes its content as a *separate* accessibility window rather
    // than as nodes within this one. Fixing this needs AccessibilityService#getWindows() to
    // be enumerated to find the window that hosts GeckoView's content (if any - it's also
    // possible the title isn't exposed as an accessibility node at all, e.g. only via a
    // window title property), which is a bigger change than this function's shape allows for.
    private fun findWebView(info: AccessibilityNodeInfo): AccessibilityNodeInfo? =
        findNode(info) { it.className == "android.webkit.WebView" && it.text != null }

    private fun handleUrl(newUrl : String?, newBrowser: String?) {
        sessionTracker.handleUrl(newUrl, newBrowser)?.let { logBrowserEvent(it) }
    }

    private fun handleWindowTitle(newWindowTitle: String) {
        if (isPrivateBrowsingIndicator(newWindowTitle)) {
            sessionTracker.discardCurrentSession()
            return
        }
        sessionTracker.handleWindowTitle(newWindowTitle)
    }

    private fun logBrowserEvent(session: CompletedBrowserSession) {
        if (isPrivateBrowsingIndicator(session.title)) return
        val data = JSONObject()
            .put("url", session.url)
            .put("browser", session.browser)
            .put("title", session.title)

        ri?.heartbeatHelper(bucket_id, session.start, session.duration.seconds.toDouble(), data, 1.0)
    }

    override fun onInterrupt() {}

    companion object {
        internal val KNOWN_BROWSER_PACKAGES = setOf(
            "com.android.chrome",
            "org.mozilla.firefox",
            "com.sec.android.app.sbrowser",
            "com.opera.browser",
            "com.microsoft.emmx"
        )
    }
}
