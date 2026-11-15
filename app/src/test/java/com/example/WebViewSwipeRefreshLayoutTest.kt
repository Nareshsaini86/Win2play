package com.example

import android.content.Context
import android.webkit.WebView
import androidx.test.core.app.ApplicationProvider
import com.example.webview.WebViewSwipeRefreshLayout
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class WebViewSwipeRefreshLayoutTest {

  @Test
  fun `canChildScrollUp reflects WebView scroll and canPullRefresh flag`() {
    val context = ApplicationProvider.getApplicationContext<Context>()
    val webView = WebView(context)
    val canPullRefresh = AtomicBoolean(true)
    val wrapper = WebViewSwipeRefreshLayout(context, webView, canPullRefresh)

    assertTrue(webView.parent === wrapper)
    assertFalse(wrapper.canChildScrollUp())

    canPullRefresh.set(false)
    assertTrue(wrapper.canChildScrollUp())

    canPullRefresh.set(true)
    assertFalse(wrapper.canChildScrollUp())

    webView.scrollTo(0, 120)
    assertTrue(wrapper.canChildScrollUp())

    wrapper.applyThemeColors(isDayTheme = true)
    wrapper.applyThemeColors(isDayTheme = false)
  }
}
