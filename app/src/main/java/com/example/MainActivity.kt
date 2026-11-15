package com.example

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.webkit.WebView
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import com.example.ui.theme.DayBackground
import com.example.ui.theme.MidnightNavy
import com.example.ui.theme.MyApplicationTheme
import com.example.ui.theme.PlayGold
import com.example.webview.APP_START_URL
import com.example.webview.JsDialogState
import com.example.webview.createConfiguredWebView
import com.example.webview.isNetworkAvailable
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

class MainActivity : ComponentActivity() {
  private var incomingReferralCode by mutableStateOf<String?>(null)

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    incomingReferralCode = extractReferralCode(intent)
    enableEdgeToEdge()
    setContent {
      var isDayTheme by remember { mutableStateOf(false) }

      val view = LocalView.current
      if (!view.isInEditMode) {
        SideEffect {
          val window = (view.context as? Activity)?.window ?: return@SideEffect
          val controller = WindowCompat.getInsetsController(window, view)
          controller.isAppearanceLightStatusBars = isDayTheme
          controller.isAppearanceLightNavigationBars = isDayTheme
        }
      }

      MyApplicationTheme(darkTheme = !isDayTheme) {
        Play2WinShell(
          isDayTheme = isDayTheme,
          initialReferralCode = incomingReferralCode,
          onReferralConsumed = { incomingReferralCode = null },
          onThemeChanged = { isDay -> isDayTheme = isDay },
        )
      }
    }
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    extractReferralCode(intent)?.let { code -> incomingReferralCode = code }
  }

  private fun extractReferralCode(intent: Intent?): String? {
    val data: Uri = intent?.data ?: return null
    val ref = data.getQueryParameter("ref")?.trim()
    if (!ref.isNullOrEmpty()) return ref
    if (data.scheme == "play2win" && data.host == "refer") {
      return data.lastPathSegment?.trim()?.takeIf { it.isNotEmpty() }
    }
    return null
  }
}

@Composable
fun Play2WinShell(
  isDayTheme: Boolean,
  initialReferralCode: String?,
  onReferralConsumed: () -> Unit,
  onThemeChanged: (Boolean) -> Unit,
) {
  val context = LocalContext.current
  val backdropColor = if (isDayTheme) DayBackground else MidnightNavy

  var progress by remember { mutableIntStateOf(0) }
  var isLoading by remember { mutableStateOf(true) }
  var hasLoadedOnce by remember { mutableStateOf(false) }
  var errorMessage by remember { mutableStateOf<String?>(null) }
  var canGoBack by remember { mutableStateOf(false) }
  var jsDialog by remember { mutableStateOf<JsDialogState?>(null) }
  val canPullRefresh = remember { AtomicBoolean(true) }
  var swipeRefreshRef by remember { mutableStateOf<SwipeRefreshLayout?>(null) }

  val startUrl = remember {
    val ref = initialReferralCode
    if (!ref.isNullOrBlank()) "$APP_START_URL?ref=${Uri.encode(ref)}" else APP_START_URL
  }

  val webView = remember {
    createConfiguredWebView(
      context = context,
      canPullRefresh = canPullRefresh,
      onProgressChanged = { progress = it },
      onLoadingChanged = { loading -> isLoading = loading },
      onRefreshFinished = {
        hasLoadedOnce = true
        swipeRefreshRef?.isRefreshing = false
      },
      onErrorChanged = { errorMessage = it },
      onThemeChanged = onThemeChanged,
      onJsDialog = { jsDialog = it },
      onCanGoBackChanged = { canGoBack = it },
    ).apply {
      if (isNetworkAvailable(context)) {
        loadUrl(startUrl)
      } else {
        isLoading = false
        errorMessage = context.getString(R.string.offline_body)
      }
    }
  }

  LaunchedEffect(initialReferralCode, hasLoadedOnce) {
    val code = initialReferralCode
    if (hasLoadedOnce && !code.isNullOrBlank()) {
      val quoted = JSONObject.quote(code)
      webView.evaluateJavascript(
        "window.Play2WinApplyIncomingRef && window.Play2WinApplyIncomingRef($quoted);",
        null,
      )
      onReferralConsumed()
    }
  }

  val swipeRefreshLayout = remember(webView) {
    SwipeRefreshLayout(context).apply {
      setColorSchemeColors(
        android.graphics.Color.parseColor("#FFC94D"),
        android.graphics.Color.parseColor("#FF9F1C"),
      )
      setProgressBackgroundColorSchemeColor(android.graphics.Color.parseColor("#171A3C"))
      setOnChildScrollUpCallback { _, _ ->
        !canPullRefresh.get() || webView.scrollY > 0 || webView.canScrollVertically(-1)
      }
      setOnRefreshListener {
        if (isNetworkAvailable(context)) {
          errorMessage = null
          webView.reload()
        } else {
          isRefreshing = false
          errorMessage = context.getString(R.string.offline_body)
        }
      }
      addView(webView)
      swipeRefreshRef = this
    }
  }

  DisposableEffect(webView) {
    onDispose {
      swipeRefreshLayout.removeAllViews()
      webView.stopLoading()
      webView.destroy()
    }
  }

  BackHandler(enabled = canGoBack) {
    if (webView.canGoBack()) {
      webView.goBack()
    }
  }

  Surface(
    modifier =
      Modifier
        .fillMaxSize()
        .background(backdropColor)
        .windowInsetsPadding(WindowInsets.safeDrawing),
    color = backdropColor,
  ) {
    Box(modifier = Modifier.fillMaxSize()) {
      AndroidView(
        factory = { swipeRefreshLayout },
        update = { refreshLayout ->
          val bgHex = if (isDayTheme) "#FFFFFF" else "#171A3C"
          val fgHex = if (isDayTheme) "#FF8A00" else "#FFC94D"
          refreshLayout.setProgressBackgroundColorSchemeColor(android.graphics.Color.parseColor(bgHex))
          refreshLayout.setColorSchemeColors(
            android.graphics.Color.parseColor(fgHex),
            android.graphics.Color.parseColor("#FF9F1C"),
          )
        },
        modifier = Modifier.fillMaxSize().testTag("play2win_webview"),
      )

      if (isLoading && progress in 1..99) {
        LinearProgressIndicator(
          progress = { progress / 100f },
          modifier = Modifier.fillMaxWidth().align(Alignment.TopCenter),
          color = PlayGold,
        )
      }

      AnimatedVisibility(
        visible = isLoading && !hasLoadedOnce && errorMessage == null,
        enter = fadeIn(),
        exit = fadeOut(),
      ) {
        Box(
          modifier = Modifier.fillMaxSize().background(backdropColor.copy(alpha = 0.92f)),
          contentAlignment = Alignment.Center,
        ) {
          Column(horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator(
              modifier = Modifier.size(44.dp),
              color = PlayGold,
              strokeWidth = 3.5.dp,
            )
            Spacer(modifier = Modifier.height(16.dp))
            Text(
              text = stringResource(R.string.loading_message),
              style = MaterialTheme.typography.titleMedium,
              color = MaterialTheme.colorScheme.onBackground,
              fontWeight = FontWeight.SemiBold,
            )
          }
        }
      }

      if (errorMessage != null) {
        OfflineFallbackOverlay(
          message = errorMessage.orEmpty(),
          onRetry = {
            if (isNetworkAvailable(context)) {
              errorMessage = null
              isLoading = true
              webView.loadUrl(startUrl)
            } else {
              errorMessage = context.getString(R.string.offline_body)
            }
          },
        )
      }
    }
  }

  JsBridgeDialogs(dialog = jsDialog, onDismiss = { jsDialog = null })
}

@Composable
private fun OfflineFallbackOverlay(message: String, onRetry: () -> Unit) {
  Box(
    modifier =
      Modifier
        .fillMaxSize()
        .background(MaterialTheme.colorScheme.background)
        .padding(24.dp),
    contentAlignment = Alignment.Center,
  ) {
    Column(
      modifier = Modifier.widthIn(max = 420.dp),
      horizontalAlignment = Alignment.CenterHorizontally,
      verticalArrangement = Arrangement.Center,
    ) {
      Icon(
        imageVector = Icons.Rounded.WifiOff,
        contentDescription = stringResource(R.string.offline_title),
        modifier = Modifier.size(56.dp),
        tint = MaterialTheme.colorScheme.primary,
      )
      Spacer(modifier = Modifier.height(16.dp))
      Text(
        text = stringResource(R.string.offline_title),
        style = MaterialTheme.typography.headlineSmall,
        fontWeight = FontWeight.Bold,
        textAlign = TextAlign.Center,
      )
      Spacer(modifier = Modifier.height(8.dp))
      Text(
        text = message,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.78f),
        textAlign = TextAlign.Center,
      )
      Spacer(modifier = Modifier.height(24.dp))
      Button(
        onClick = onRetry,
        modifier = Modifier.testTag("retry_button"),
        colors =
          ButtonDefaults.buttonColors(
            containerColor = MaterialTheme.colorScheme.primary,
            contentColor = MaterialTheme.colorScheme.onPrimary,
          ),
      ) {
        Text(text = stringResource(R.string.retry_button), fontWeight = FontWeight.Bold)
      }
    }
  }
}

@Composable
private fun JsBridgeDialogs(dialog: JsDialogState?, onDismiss: () -> Unit) {
  when (dialog) {
    is JsDialogState.Alert -> {
      AlertDialog(
        onDismissRequest = {
          dialog.result.cancel()
          onDismiss()
        },
        text = { Text(dialog.message) },
        confirmButton = {
          TextButton(
            onClick = {
              dialog.result.confirm()
              onDismiss()
            },
            modifier = Modifier.testTag("js_alert_ok"),
          ) {
            Text(stringResource(R.string.dialog_ok))
          }
        },
      )
    }

    is JsDialogState.Confirm -> {
      AlertDialog(
        onDismissRequest = {
          dialog.result.cancel()
          onDismiss()
        },
        text = { Text(dialog.message) },
        confirmButton = {
          TextButton(
            onClick = {
              dialog.result.confirm()
              onDismiss()
            },
            modifier = Modifier.testTag("js_confirm_ok"),
          ) {
            Text(stringResource(R.string.dialog_confirm))
          }
        },
        dismissButton = {
          TextButton(
            onClick = {
              dialog.result.cancel()
              onDismiss()
            },
            modifier = Modifier.testTag("js_confirm_cancel"),
          ) {
            Text(stringResource(R.string.dialog_cancel))
          }
        },
      )
    }

    is JsDialogState.Prompt -> {
      var input by remember(dialog) { mutableStateOf(dialog.defaultValue) }
      AlertDialog(
        onDismissRequest = {
          dialog.result.cancel()
          onDismiss()
        },
        text = {
          Column {
            Text(dialog.message)
            Spacer(modifier = Modifier.height(12.dp))
            OutlinedTextField(
              value = input,
              onValueChange = { input = it },
              singleLine = true,
              modifier = Modifier.fillMaxWidth().testTag("js_prompt_input"),
            )
          }
        },
        confirmButton = {
          TextButton(
            onClick = {
              dialog.result.confirm(input)
              onDismiss()
            },
            modifier = Modifier.testTag("js_prompt_ok"),
          ) {
            Text(stringResource(R.string.dialog_confirm))
          }
        },
        dismissButton = {
          TextButton(
            onClick = {
              dialog.result.cancel()
              onDismiss()
            },
            modifier = Modifier.testTag("js_prompt_cancel"),
          ) {
            Text(stringResource(R.string.dialog_cancel))
          }
        },
      )
    }

    null -> Unit
  }
}
