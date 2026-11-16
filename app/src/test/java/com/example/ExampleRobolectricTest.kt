package com.example

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import com.example.webview.APP_START_URL
import com.example.webview.extractInAppRedirectUrl
import com.example.webview.shouldKeepUrlInWebView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class ExampleRobolectricTest {

  @Test
  fun `read string from context`() {
    val context = ApplicationProvider.getApplicationContext<Context>()
    val appName = context.getString(R.string.app_name)
    assertEquals("Play2Win", appName)
  }

  @Test
  fun `bundled html asset is packaged and configured for in-app google login`() {
    val context = ApplicationProvider.getApplicationContext<Context>()
    val html = context.assets.open("aistudio/index_5ad215fb.html").bufferedReader().use { it.readText() }
    assertTrue(html.contains("<title>Play2Win</title>"))

    val homeSection = html.substringAfter("<section id=\"v-home\"").substringBefore("</section>")
    assertFalse(homeSection.contains("ref-banner"))

    val settingsSection = html.substringAfter("<section id=\"v-settings\"").substringBefore("<section id=\"v-tx\"")
    assertTrue(settingsSection.contains("id=\"m-share\""))
    assertTrue(settingsSection.contains("id=\"v-share\""))
    assertTrue(settingsSection.contains("id=\"referral-card\""))
    assertTrue(html.contains("function resolveAppDownloadUrl"))
    assertFalse(html.contains("openExternalAuth"))
    assertTrue(html.contains("Play2WinHandleOAuthCallback"))
    assertTrue(html.contains("id=\"auth-tab-signup\""))
    assertTrue(html.contains("id=\"su-email\""))
    assertTrue(html.contains("id=\"su-pw\""))
    assertTrue(html.contains("id=\"su-go\""))
    assertTrue(html.contains("id=\"su-show-pw\""))
    assertTrue(html.contains("id=\"a-show-pw\""))
    assertTrue(html.contains("id=\"pw-show\""))
    assertTrue(html.contains("id=\"su-match\""))
    assertTrue(html.contains("email_signup"))
    assertTrue(html.contains("data-open-route=\"aviator\""))
    assertTrue(html.contains("id=\"v-aviator\""))
    assertTrue(html.contains("id=\"av-canvas\""))
    assertTrue(html.contains("id=\"av-bet\""))
    assertTrue(html.contains("max=\"1000\""))
    assertTrue(html.contains("id=\"av-action\""))
    assertTrue(html.contains("aviator_place_bet"))
    assertTrue(html.contains("aviator_cashout"))
    assertTrue(html.contains("id=\"av-tab-results\""))
    assertTrue(html.contains("id=\"av-tab-bets\""))
    assertTrue(html.contains("id=\"av-swipe-viewport\""))
    assertTrue(html.contains("id=\"bets-pane-number\""))
    assertTrue(html.contains("id=\"bets-pane-gold\""))
    assertTrue(html.contains("id=\"bets-pane-aviator\""))
    assertTrue(html.contains("admin_gold_bets"))
    assertTrue(html.contains("admin_aviator_bets"))
    assertTrue(html.contains("Coins bet → mostly fast crash (rare 5x–10x)"))
    assertFalse(html.contains("No bet → 25x–50x"))
    assertTrue(html.contains("min=\"300\""))
    assertTrue(html.contains("Minimum withdrawal ₹300"))
    assertTrue(html.contains("id=\"b-admin-ctrl\""))
    assertTrue(html.contains("id=\"ab-admin-ctrl\""))
    assertTrue(html.contains("admin_set_number_result"))
    assertTrue(html.contains("admin_set_aviator_crash"))
    assertTrue(settingsSection.contains("id=\"m-ref-network\""))
    assertTrue(settingsSection.contains("id=\"v-ref-network\""))
    assertTrue(html.contains("get_my_referral_network_stats"))
    assertTrue(html.contains("admin_set_referral_network_access"))
    assertTrue(html.contains("admin_list_referral_access"))
    assertTrue(html.contains("Referrer ko +20 Coins"))
    assertFalse(html.contains("dono ko 20 Bonus Coins"))
    assertTrue(html.contains("id=\"admin-cat-tabs\""))
    assertTrue(html.contains("id=\"admin-pane-payments\""))
    assertTrue(html.contains("id=\"admin-pane-referrals\""))
    assertTrue(html.contains("id=\"admin-pane-users\""))
    assertTrue(html.contains("id=\"admin-user-search\""))
    assertTrue(html.contains("id=\"admin-users-bulk-bar\""))
    assertTrue(html.contains("id=\"admin-users-select-all\""))
    assertTrue(html.contains("id=\"admin-users-select-all-top\""))
    assertTrue(html.contains("class=\"admin-user-cb\""))
    assertTrue(html.contains("id=\"admin-bulk-add\""))
    assertTrue(html.contains("id=\"admin-bulk-deduct\""))
    assertTrue(html.contains("id=\"admin-bulk-network-on\""))
    assertTrue(html.contains("id=\"admin-bulk-reset-pw\""))
    assertTrue(html.contains("id=\"admin-bulk-delete\""))
    assertFalse(html.contains("admin-user-actions"))
  }

  @Test
  fun `oauth and netlify redirects are intercepted back to local app url`() {
    assertEquals(
      "$APP_START_URL#access_token=tok&refresh_token=ref",
      extractInAppRedirectUrl(
        Uri.parse("https://splendorous-jalebi-a6d440.netlify.app/#access_token=tok&refresh_token=ref")
      ),
    )
    assertEquals(
      "$APP_START_URL?code=pkce123",
      extractInAppRedirectUrl(Uri.parse("https://splendorous-jalebi-a6d440.netlify.app/?code=pkce123")),
    )
    assertEquals(
      APP_START_URL,
      extractInAppRedirectUrl(Uri.parse("https://splendorous-jalebi-a6d440.netlify.app/")),
    )
    assertEquals(
      "$APP_START_URL#access_token=tok",
      extractInAppRedirectUrl(Uri.parse("play2win://auth-callback#access_token=tok")),
    )
    assertNull(extractInAppRedirectUrl(Uri.parse("https://accounts.google.com/o/oauth2/v2/auth")))
  }

  @Test
  fun `google and supabase auth urls stay inside webview`() {
    assertTrue(shouldKeepUrlInWebView(Uri.parse("https://accounts.google.com/v3/signin/identifier")))
    assertTrue(shouldKeepUrlInWebView(Uri.parse("https://accounts.google.co.in/ServiceLogin")))
    assertTrue(shouldKeepUrlInWebView(Uri.parse("https://tcirnuhynvtwbprbogqp.supabase.co/auth/v1/authorize")))
    assertTrue(shouldKeepUrlInWebView(Uri.parse("https://appassets.androidplatform.net/www/index.html")))
    assertFalse(shouldKeepUrlInWebView(Uri.parse("https://play.google.com/store/apps")))
    assertFalse(shouldKeepUrlInWebView(Uri.parse("upi://pay?pa=test@upi")))
  }
}
