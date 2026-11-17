package com.example.webview

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Bundle
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
import androidx.webkit.UserAgentMetadata
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import com.example.BuildConfig
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

  @JavascriptInterface
  fun getAppVersionCode(): Int = BuildConfig.VERSION_CODE

  @JavascriptInterface
  fun getAppVersionName(): String = BuildConfig.VERSION_NAME

  @JavascriptInterface
  fun openExternalUrl(url: String?) {
    val cleanUrl = url.orEmpty().trim()
    if (!cleanUrl.startsWith("https://") && !cleanUrl.startsWith("http://")) return
    mainHandler.post {
      val viewIntent =
        Intent(Intent.ACTION_VIEW, Uri.parse(cleanUrl)).apply {
          if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
      try {
        context.startActivity(viewIntent)
      } catch (_: ActivityNotFoundException) {
        openInCustomTabOrBrowser(context, Uri.parse(cleanUrl))
      }
    }
  }

  @JavascriptInterface
  fun openExternalAuth(url: String?) {
    val cleanUrl = url.orEmpty().trim()
    if (!cleanUrl.startsWith("https://") && !cleanUrl.startsWith("http://")) return
    mainHandler.post {
      openInCustomTabOrBrowser(context, Uri.parse(cleanUrl))
    }
  }

  var onGoogleErrorDetected: ((String) -> Unit)? = null

  @JavascriptInterface
  fun onGoogleAuthError(reason: String?) {
    val clean = reason.orEmpty().trim().ifEmpty { "google_error" }
    mainHandler.post { onGoogleErrorDetected?.invoke(clean) }
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
      // Strip WebView markers so Google OAuth works inside the in-app WebView.
      userAgentString =
        userAgentString
          .replace(Regex(";\\s*wv\\b"), "")
          .replace(Regex("Version/\\d+\\.\\d+\\s*"), "")
    }

    if (WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) {
      val existingMetadata = WebSettingsCompat.getUserAgentMetadata(settings)
      val cleanedBrands =
        existingMetadata.brandVersionList.map { brand ->
          if (brand.brand.contains("WebView", ignoreCase = true)) {
            UserAgentMetadata.BrandVersion.Builder()
              .setBrand("Google Chrome")
              .setMajorVersion(brand.majorVersion)
              .setFullVersion(brand.fullVersion)
              .build()
          } else {
            brand
          }
        }
      val updatedMetadata =
        UserAgentMetadata.Builder(existingMetadata)
          .setBrandVersionList(cleanedBrands)
          .build()
      WebSettingsCompat.setUserAgentMetadata(settings, updatedMetadata)
    }

    if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
      WebSettingsCompat.setRequestedWithHeaderOriginAllowList(settings, emptySet())
    }

    val nativeBridge = Play2WinNativeBridge(context, onThemeChanged, canPullRefresh)
    nativeBridge.onGoogleErrorDetected = { reason ->
      stopLoading()
      loadUrl("$APP_START_URL?google_error=${Uri.encode(reason)}")
    }
    addJavascriptInterface(nativeBridge, "Play2WinNative")

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

        private var clearHistoryOnNextAppLoad = false

        private fun interceptOAuthOrWebSiteRedirect(
          view: WebView?,
          uri: Uri?,
          stopCurrentLoad: Boolean,
        ): Boolean {
          val targetUrl = extractInAppRedirectUrl(uri) ?: return false
          val urlStr = uri?.toString().orEmpty()
          val isPlay2WinAuth =
            uri?.scheme?.equals("play2win", ignoreCase = true) == true &&
              uri.host?.equals("auth-callback", ignoreCase = true) == true
          val hasOAuthPayload =
            isPlay2WinAuth ||
              urlStr.contains("access_token=") ||
              urlStr.contains("code=") ||
              urlStr.contains("error=")
          if (hasOAuthPayload) {
            clearHistoryOnNextAppLoad = true
          }
          if (stopCurrentLoad) {
            view?.stopLoading()
          }
          view?.post { view.loadUrl(targetUrl) }
          return true
        }

        override fun shouldOverrideUrlLoading(
          view: WebView?,
          request: WebResourceRequest?,
        ): Boolean {
          val uri = request?.url ?: return false
          if (interceptOAuthOrWebSiteRedirect(view, uri, stopCurrentLoad = false)) return true
          return handleUri(context, uri)
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
          val uri = url?.let { Uri.parse(it) }
          if (interceptOAuthOrWebSiteRedirect(view, uri, stopCurrentLoad = true)) return
          onErrorChanged(null)
          onLoadingChanged(true)
          canPullRefresh.set(true)
          onCanGoBackChanged(view?.canGoBack() == true)
        }

        override fun onPageFinished(view: WebView?, url: String?) {
          onLoadingChanged(false)
          onRefreshFinished()
          if (clearHistoryOnNextAppLoad && url?.startsWith(APP_START_URL) == true) {
            clearHistoryOnNextAppLoad = false
            view?.clearHistory()
            onCanGoBackChanged(false)
          } else {
            onCanGoBackChanged(view?.canGoBack() == true)
          }
          if (
            url?.startsWith(APP_START_URL) == true &&
              (url.contains("access_token=") || url.contains("code=") || url.contains("error="))
          ) {
            view?.evaluateJavascript(
              "window.Play2WinHandleOAuthCallback && window.Play2WinHandleOAuthCallback(location.search || '', location.hash || '');",
              null,
            )
          } else if (url?.contains("accounts.google.") == true) {
            view?.evaluateJavascript(
              """
              (function() {
                try {
                  var txt = (document.body && document.body.innerText) || '';
                  if (/400\.\s*That['’]s an error|malformed\.\s*It should not be retried|disallowed_useragent/i.test(txt)) {
                    if (window.Play2WinNative && window.Play2WinNative.onGoogleAuthError) {
                      window.Play2WinNative.onGoogleAuthError('google_400_malformed');
                    }
                  }
                } catch (e) {}
              })();
              """.trimIndent(),
              null,
            )
          }
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
                  var hasScrolledAncestor = function(target) {
                    var el = target && target.nodeType === 1 ? target : (target && target.parentElement ? target.parentElement : null);
                    while (el && el !== document.body && el !== document.documentElement) {
                      if (el.scrollTop > 0) {
                        var style = window.getComputedStyle ? window.getComputedStyle(el) : null;
                        var oy = style ? style.overflowY : '';
                        if (oy === 'auto' || oy === 'scroll' || oy === 'overlay' || el.classList.contains('scroll')) {
                          return true;
                        }
                      }
                      el = el.parentElement;
                    }
                    var docScroll = document.scrollingElement || document.documentElement || document.body;
                    return !!(docScroll && docScroll.scrollTop > 0);
                  };
                  document.addEventListener('touchstart', function(ev) {
                    var blocked = hasScrolledAncestor(ev.target);
                    if (window.Play2WinNative && window.Play2WinNative.setCanPullRefresh) {
                      window.Play2WinNative.setCanPullRefresh(!blocked);
                    }
                  }, { capture: true, passive: true });
                  var resetPull = function() {
                    if (window.Play2WinNative && window.Play2WinNative.setCanPullRefresh) {
                      window.Play2WinNative.setCanPullRefresh(true);
                    }
                  };
                  document.addEventListener('touchend', resetPull, { capture: true, passive: true });
                  document.addEventListener('touchcancel', resetPull, { capture: true, passive: true });
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

        override fun onReceivedHttpError(
          view: WebView?,
          request: WebResourceRequest?,
          errorResponse: WebResourceResponse?,
        ) {
          val host = request?.url?.host?.lowercase().orEmpty()
          val code = errorResponse?.statusCode ?: 0
          if (request?.isForMainFrame == true && host.startsWith("accounts.google.") && code >= 400) {
            clearHistoryOnNextAppLoad = true
            view?.stopLoading()
            view?.post { view.loadUrl("$APP_START_URL?google_error=http_$code") }
          }
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

    setDownloadListener { downloadUrl, _, _, _, _ ->
      nativeBridge.openExternalUrl(downloadUrl)
    }
  }
}

internal fun extractInAppRedirectUrl(uri: Uri?): String? {
  if (uri == null) return null
  val scheme = uri.scheme?.lowercase().orEmpty()
  val host = uri.host?.lowercase().orEmpty()
  val isPlay2WinAuth = scheme == "play2win" && host == "auth-callback"
  val isNetlifySite = host == SUPABASE_FALLBACK_HOST
  if (!isPlay2WinAuth && !isNetlifySite) return null

  val query = uri.encodedQuery?.let { "?$it" }.orEmpty()
  val fragment = uri.encodedFragment?.let { "#$it" }.orEmpty()
  return "$APP_START_URL$query$fragment"
}

internal fun shouldKeepUrlInWebView(uri: Uri?): Boolean {
  if (uri == null) return false
  val scheme = uri.scheme?.lowercase().orEmpty()
  if (scheme != "http" && scheme != "https") return false
  val host = uri.host?.lowercase().orEmpty()
  val isGoogleAuthHost =
    host == "accounts.google.com" ||
      host.startsWith("accounts.google.") ||
      host == "accounts.youtube.com" ||
      host == "gds.google.com" ||
      host == "myaccount.google.com" ||
      (host.endsWith(".google.com") && !host.startsWith("play."))
  return host == APP_ASSET_HOST ||
    isGoogleAuthHost ||
    host.endsWith(".supabase.co") ||
    host.endsWith(".gstatic.com") ||
    host.endsWith(".googleapis.com") ||
    host.endsWith(".googleusercontent.com")
}

private fun handleUri(context: Context, uri: Uri): Boolean {
  val scheme = uri.scheme?.lowercase() ?: return false
  if (scheme == "http" || scheme == "https") {
    if (shouldKeepUrlInWebView(uri)) {
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

fun openInCustomTabOrBrowser(context: Context, uri: Uri) {
  val customTabsExtras =
    Bundle().apply {
      putBinder("android.support.customtabs.extra.SESSION", null)
    }
  val customTabsIntent =
    Intent(Intent.ACTION_VIEW, uri).apply {
      putExtras(customTabsExtras)
      putExtra(
        "android.support.customtabs.extra.TOOLBAR_COLOR",
        android.graphics.Color.parseColor("#0B0D22"),
      )
      putExtra("android.support.customtabs.extra.TITLE_VISIBILITY", 1)
      if (context !is Activity) {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
    }
  val serviceIntent = Intent("android.support.customtabs.action.CustomTabsService")
  val customTabPackages =
    context.packageManager
      .queryIntentServices(serviceIntent, 0)
      .mapNotNull { it.serviceInfo?.packageName }
  val preferredPackage =
    customTabPackages.firstOrNull { it == "com.android.chrome" } ?: customTabPackages.firstOrNull()
  if (preferredPackage != null) {
    customTabsIntent.setPackage(preferredPackage)
  }
  try {
    context.startActivity(customTabsIntent)
  } catch (_: ActivityNotFoundException) {
    val fallback =
      Intent(Intent.ACTION_VIEW, uri).apply {
        if (context !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
    try {
      context.startActivity(fallback)
    } catch (_: ActivityNotFoundException) {
      Toast.makeText(context, context.getString(R.string.no_browser_app), Toast.LENGTH_SHORT).show()
    }
  }
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
