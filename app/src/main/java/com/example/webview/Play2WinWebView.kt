package com.example.webview

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import com.example.R
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

const val APP_ASSET_HOST = "appassets.androidplatform.net"
const val APP_START_URL = "https://$APP_ASSET_HOST/www/index.html"
private const val SUPABASE_FALLBACK_HOST = "splendorous-jalebi-a6d440.netlify.app"

sealed interface JsDialogState {
  data class Alert(val message: String, val result: JsResult) : JsDialogState

  data class Confirm(val message: String, val result: JsResult) : JsDialogState

  data class Prompt(val message: String, val defaultValue: String, val result: JsPromptResult) :
    JsDialogState
}

class Play2WinNativeBridge(
  private val context: Context,
  private val onThemeChanged: (Boolean) -> Unit,
  private val canPullRefresh: AtomicBoolean,
) {
  private val mainHandler = Handler(Looper.getMainLooper())

  @JavascriptInterface
  fun isNativeApp(): Boolean = true

  @JavascriptInterface
  fun onThemeChanged(theme: String?) {
    val isDay = theme == "day"
    mainHandler.post { onThemeChanged(isDay) }
  }

  @JavascriptInterface
  fun setCanPullRefresh(allowed: Boolean) {
    canPullRefresh.set(allowed)
  }

  @JavascriptInterface
  fun shareText(title: String?, text: String?) {
    val payload = text.orEmpty().trim()
    if (payload.isEmpty()) return
    mainHandler.post {
      val sendIntent =
        Intent(Intent.ACTION_SEND).apply {
          type = "text/plain"
          putExtra(Intent.EXTRA_SUBJECT, title ?: context.getString(R.string.app_name))
          putExtra(Intent.EXTRA_TEXT, payload)
        }
      val chooser =
        Intent.createChooser(sendIntent, title ?: context.getString(R.string.app_name)).apply {
          addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
      try {
        context.startActivity(chooser)
      } catch (_: ActivityNotFoundException) {
        Toast.makeText(context, context.getString(R.string.no_upi_app), Toast.LENGTH_SHORT).show()
      }
    }
  }

  @JavascriptInterface
  fun copyToClipboard(label: String?, text: String?) {
    val value = text.orEmpty()
    if (value.isEmpty()) return
    mainHandler.post {
      val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
      cm?.setPrimaryClip(ClipData.newPlainText(label ?: "Play2Win", value))
    }
  }
}

fun isNetworkAvailable(context: Context): Boolean {
  val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return true
  val network = cm.activeNetwork ?: return false
  val caps = cm.getNetworkCapabilities(network) ?: return false
  return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
}

@SuppressLint("SetJavaScriptEnabled")
@Suppress("DEPRECATION")
fun createConfiguredWebView(
  context: Context,
  canPullRefresh: AtomicBoolean,
  onProgressChanged: (Int) -> Unit,
  onLoadingChanged: (Boolean) -> Unit,
  onRefreshFinished: () -> Unit,
  onErrorChanged: (String?) -> Unit,
  onThemeChanged: (Boolean) -> Unit,
  onJsDialog: (JsDialogState) -> Unit,
  onCanGoBackChanged: (Boolean) -> Unit,
): WebView {
  return WebView(context).apply {
    layoutParams =
      ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
    overScrollMode = View.OVER_SCROLL_NEVER
    isVerticalScrollBarEnabled = true
    isHorizontalScrollBarEnabled = false
    setBackgroundColor(android.graphics.Color.parseColor("#0B0D22"))

    val cookieManager = CookieManager.getInstance()
    cookieManager.setAcceptCookie(true)
    cookieManager.setAcceptThirdPartyCookies(this, true)

    settings.apply {
      javaScriptEnabled = true
      domStorageEnabled = true
      databaseEnabled = true
      cacheMode = WebSettings.LOAD_DEFAULT
      mediaPlaybackRequiresUserGesture = false
      allowFileAccess = false
      allowContentAccess = false
      setSupportZoom(false)
      builtInZoomControls = false
      displayZoomControls = false
      useWideViewPort = true
      loadWithOverviewMode = true
      javaScriptCanOpenWindowsAutomatically = true
      setSupportMultipleWindows(false)
      mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
      // Strip WebView markers so Google OAuth does not block with disallowed_useragent.
      userAgentString =
        userAgentString
          .replace("; wv)", ")")
          .replace(Regex("Version/\\d+\\.\\d+\\s*"), "")
    }

    if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
      WebSettingsCompat.setRequestedWithHeaderOriginAllowList(settings, emptySet())
    }

    addJavascriptInterface(
      Play2WinNativeBridge(context, onThemeChanged, canPullRefresh),
      "Play2WinNative",
    )

    webViewClient =
      object : WebViewClient() {
        override fun shouldInterceptRequest(
          view: WebView?,
          request: WebResourceRequest?,
        ): WebResourceResponse? {
          val url = request?.url ?: return null
          if (url.host != APP_ASSET_HOST) return null

          val rawPath = (url.path ?: "").trimStart('/')
          val assetPath =
            when {
              rawPath.isEmpty() || rawPath == "index.html" || rawPath == "www/index.html" ->
                "aistudio/index_5ad215fb.html"
              else -> rawPath
            }

          return try {
            val stream = context.assets.open(assetPath)
            val mimeType =
              when {
                assetPath.endsWith(".html") -> "text/html"
                assetPath.endsWith(".js") -> "application/javascript"
                assetPath.endsWith(".css") -> "text/css"
                assetPath.endsWith(".svg") -> "image/svg+xml"
                assetPath.endsWith(".png") -> "image/png"
                else -> "application/octet-stream"
              }
            WebResourceResponse(mimeType, "UTF-8", stream)
          } catch (_: IOException) {
            null
          }
        }

        private fun redirectOAuthCallbackIfNeeded(view: WebView?, uri: Uri?): Boolean {
          if (uri == null) return false
          val urlStr = uri.toString()
          if (
            uri.host?.equals(SUPABASE_FALLBACK_HOST, ignoreCase = true) == true &&
              (urlStr.contains("access_token=") ||
                urlStr.contains("code=") ||
                urlStr.contains("error="))
          ) {
            val query = uri.encodedQuery?.let { "?$it" }.orEmpty()
            val fragment = uri.encodedFragment?.let { "#$it" }.orEmpty()
            view?.stopLoading()
            view?.loadUrl("$APP_START_URL$query$fragment")
            return true
          }
          return false
        }

        override fun shouldOverrideUrlLoading(
          view: WebView?,
          request: WebResourceRequest?,
        ): Boolean {
          val uri = request?.url ?: return false
          if (redirectOAuthCallbackIfNeeded(view, uri)) return true
          return handleUri(context, uri)
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
          val uri = url?.let { Uri.parse(it) }
          if (redirectOAuthCallbackIfNeeded(view, uri)) return
          onErrorChanged(null)
          onLoadingChanged(true)
          canPullRefresh.set(true)
          onCanGoBackChanged(view?.canGoBack() == true)
        }

        override fun onPageFinished(view: WebView?, url: String?) {
          onLoadingChanged(false)
          onRefreshFinished()
          onCanGoBackChanged(view?.canGoBack() == true)
          view?.evaluateJavascript(
            """
            (function() {
              try {
                var notify = function() {
                  var t = document.documentElement.getAttribute('data-theme') || 'night';
                  if (window.Play2WinNative && window.Play2WinNative.onThemeChanged) {
                    window.Play2WinNative.onThemeChanged(t);
                  }
                };
                notify();
                if (!window.__p2wThemeObs) {
                  window.__p2wThemeObs = new MutationObserver(notify);
                  window.__p2wThemeObs.observe(document.documentElement, {
                    attributes: true,
                    attributeFilter: ['data-theme']
                  });
                }
                if (!window.__p2wPullHook) {
                  window.__p2wPullHook = true;
                  document.addEventListener('touchstart', function(ev) {
                    var sc = ev.target && ev.target.closest ? ev.target.closest('.scroll') : null;
                    var atTop = !sc || sc.scrollTop <= 0;
                    if (window.Play2WinNative && window.Play2WinNative.setCanPullRefresh) {
                      window.Play2WinNative.setCanPullRefresh(atTop);
                    }
                  }, { passive: true });
                }
              } catch (e) {}
            })();
            """.trimIndent(),
            null,
          )
        }

        override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
          onCanGoBackChanged(view?.canGoBack() == true)
        }

        override fun onReceivedError(
          view: WebView?,
          request: WebResourceRequest?,
          error: WebResourceError?,
        ) {
          if (request?.isForMainFrame == true) {
            onLoadingChanged(false)
            onRefreshFinished()
            onErrorChanged(error?.description?.toString() ?: context.getString(R.string.offline_body))
          }
        }
      }

    webChromeClient =
      object : WebChromeClient() {
        override fun onProgressChanged(view: WebView?, newProgress: Int) {
          onProgressChanged(newProgress)
        }

        override fun onJsAlert(
          view: WebView?,
          url: String?,
          message: String?,
          result: JsResult?,
        ): Boolean {
          if (result == null) return false
          onJsDialog(JsDialogState.Alert(message.orEmpty(), result))
          return true
        }

        override fun onJsConfirm(
          view: WebView?,
          url: String?,
          message: String?,
          result: JsResult?,
        ): Boolean {
          if (result == null) return false
          onJsDialog(JsDialogState.Confirm(message.orEmpty(), result))
          return true
        }

        override fun onJsPrompt(
          view: WebView?,
          url: String?,
          message: String?,
          defaultValue: String?,
          result: JsPromptResult?,
        ): Boolean {
          if (result == null) return false
          onJsDialog(JsDialogState.Prompt(message.orEmpty(), defaultValue.orEmpty(), result))
          return true
        }
      }
  }
}

private fun handleUri(context: Context, uri: Uri): Boolean {
  val scheme = uri.scheme?.lowercase() ?: return false
  if (scheme == "http" || scheme == "https") {
    val host = uri.host?.lowercase().orEmpty()
    val keepInApp =
      host == APP_ASSET_HOST ||
        host == SUPABASE_FALLBACK_HOST ||
        host.endsWith(".supabase.co") ||
        host == "accounts.google.com" ||
        host.endsWith(".google.com") ||
        host.endsWith(".gstatic.com") ||
        host.endsWith(".googleapis.com")
    if (keepInApp) {
      return false
    }
    return openExternalIntent(context, Intent(Intent.ACTION_VIEW, uri))
  }

  if (scheme == "intent") {
    return try {
      val parsed = Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME)
      openExternalIntent(context, parsed)
    } catch (_: Exception) {
      true
    }
  }

  return openExternalIntent(context, Intent(Intent.ACTION_VIEW, uri))
}

private fun openExternalIntent(context: Context, intent: Intent): Boolean {
  return try {
    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
    true
  } catch (_: ActivityNotFoundException) {
    Toast.makeText(context, context.getString(R.string.no_upi_app), Toast.LENGTH_SHORT).show()
    true
  }
}
