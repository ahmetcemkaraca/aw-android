package net.activitywatch.android.fragments

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Bundle
import android.webkit.WebSettings
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import androidx.fragment.app.Fragment
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView

import android.util.Log
import android.webkit.URLUtil
import android.webkit.WebResourceRequest
import android.webkit.WebViewClient
import net.activitywatch.android.R
import org.json.JSONObject
import java.lang.Thread.sleep
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private const val TAG = "WebUI"

private const val ARG_URL = "url"
private const val MAX_NATIVE_MESSAGE_CHARS = 16 * 1024 * 1024

// The embedded server lives on loopback, so keep those navigations inside the app WebView.
internal fun isTrustedDashboardUrl(url: String): Boolean {
    val uri = try {
        URI(url)
    } catch (_: Exception) {
        return false
    }

    return isLocalDashboardOrigin(uri)
        && uri.rawQuery == null
        && (uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")
}

internal fun isTrustedDashboardOrigin(origin: String): Boolean {
    val uri = try {
        URI(origin)
    } catch (_: Exception) {
        return false
    }
    return isLocalDashboardOrigin(uri)
        && uri.rawQuery == null && uri.rawFragment == null
        && (uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")
}

private fun isLocalDashboardOrigin(uri: URI): Boolean =
    uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port == 5600
        && uri.rawUserInfo == null

/**
 * A simple [Fragment] subclass.
 * Activities that contain this fragment must implement the
 * [WebUIFragment.OnFragmentInteractionListener] interface
 * to handle interaction events.
 * Use the [WebUIFragment.newInstance] factory method to
 * create an instance of this fragment.
 *
 */
class WebUIFragment : Fragment() {
    // TODO: Rename and change types of parameters
    private var listener: OnFragmentInteractionListener? = null
    private var bridgeExecutor: ExecutorService? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        // Inflate the layout for this fragment
        val view = inflater.inflate(R.layout.fragment_web_ui, container, false)

        // Enables WebView debugging, in testing builds
        // https://developers.google.com/web/tools/chrome-devtools/remote-debugging/webviews
        if (0 != view.context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) {
            WebView.setWebContentsDebuggingEnabled(true)
        }

        val myWebView: WebView = view.findViewById(R.id.webview) as WebView

        class MyWebViewClient : WebViewClient() {
            override fun onReceivedError(
                view: WebView,
                errorCode: Int,
                description: String,
                failingUrl: String
            ) {
                // Retry
                // TODO: Find way to not show the blinking Android error page
                Log.e(TAG, "WebView received error: $description")
                sleep(100);
                arguments?.let {
                    it.getString(ARG_URL)?.let { it1 -> myWebView.loadUrl(it1) }
                }
            }

            // Open external links in external browser
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val uri = request?.url ?: return true
                val url = uri.toString()
                if (isTrustedDashboardUrl(url)) return false
                if (uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port == 5600) return true
                if (URLUtil.isNetworkUrl(url) && (uri.scheme == "http" || uri.scheme == "https")) {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                    } catch (_: ActivityNotFoundException) {
                        Log.w(TAG, "No browser available for external link")
                    }
                }
                return true
            }
        }
        myWebView.webViewClient = MyWebViewClient()

        myWebView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            val rust = net.activitywatch.android.RustInterface(requireContext())
            val executor = Executors.newSingleThreadExecutor()
            bridgeExecutor = executor
            WebViewCompat.addWebMessageListener(
                myWebView,
                "Android",
                setOf("http://127.0.0.1:5600")
            ) { _, message, sourceOrigin, isMainFrame, replyProxy ->
                if (!isMainFrame || !isTrustedDashboardOrigin(sourceOrigin.toString())
                    || message.data.length > MAX_NATIVE_MESSAGE_CHARS) return@addWebMessageListener
                val request = try {
                    JSONObject(message.data)
                } catch (_: Exception) {
                    return@addWebMessageListener
                }
                val id = request.optString("id")
                val command = request.optString("command")
                if (id.isBlank() || id.length > 100 || command.isBlank()) return@addWebMessageListener
                val arguments = request.optJSONObject("args")?.toString() ?: "{}"
                executor.execute {
                    val response = try {
                        JSONObject(rust.localNativeCommand(command, arguments))
                    } catch (_: Exception) {
                        JSONObject().put("error", "The local operation failed.")
                    }
                    replyProxy.postMessage(response.put("id", id).toString())
                }
            }
        } else {
            Log.e(TAG, "Origin-scoped web message listener is unavailable in Android WebView")
        }
        arguments?.let {
            it.getString(ARG_URL)?.let { url ->
                if (isTrustedDashboardUrl(url)) myWebView.loadUrl(url)
                else Log.e(TAG, "Rejected non-local dashboard URL")
            }
        }

        return view
    }

    override fun onAttach(context: Context) {
        super.onAttach(context)
        if (context is OnFragmentInteractionListener) {
            listener = context
        } else {
            throw RuntimeException(context.toString() + " must implement OnFragmentInteractionListener")
        }
    }

    override fun onDetach() {
        super.onDetach()
        listener = null
    }

    override fun onDestroyView() {
        bridgeExecutor?.shutdown()
        bridgeExecutor = null
        super.onDestroyView()
    }

    /**
     * This interface must be implemented by activities that contain this
     * fragment to allow an interaction in this fragment to be communicated
     * to the activity and potentially other fragments contained in that
     * activity.
     *
     *
     * See the Android Training lesson [Communicating with Other Fragments]
     * (http://developer.android.com/training/basics/fragments/communicating.html)
     * for more information.
     */
    interface OnFragmentInteractionListener {
        // TODO: Update argument type and name
        fun onFragmentInteraction(uri: Uri)
    }

    companion object {
        // TODO: Rename and change types and number of parameters
        @JvmStatic
        fun newInstance(url: String) =
            WebUIFragment().apply {
                arguments = Bundle().apply {
                    putString(ARG_URL, url)
                }
            }
    }
}
