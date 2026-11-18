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

    val rewardsSection = html.substringAfter("<section id=\"v-rewards\"").substringBefore("<section id=\"v-wallet\"")
    assertTrue(rewardsSection.contains("id=\"m-share\""))
    assertTrue(rewardsSection.contains("id=\"m-ref-network\""))
    assertTrue(html.contains("id=\"v-wallet\""))
    assertTrue(html.contains("id=\"wallet-bal-amount\""))
    assertTrue(html.contains("id=\"m-add\""))
    assertTrue(html.contains("id=\"m-withdraw\""))
    assertTrue(html.contains("id=\"v-share\""))
    assertTrue(html.contains("id=\"referral-card\""))
    assertTrue(html.contains("id=\"bottom-nav\""))
    assertTrue(html.contains("data-bnav=\"home\""))
    assertTrue(html.contains("data-bnav=\"rewards\""))
    assertTrue(html.contains("data-bnav=\"wallet\""))
    assertTrue(html.contains("data-bnav=\"settings\""))
    assertFalse(html.contains("id=\"gear\""))
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
    assertTrue(html.contains("j.success===false"))
    assertTrue(html.contains("else if(id.indexOf('@')>0)"))
    assertTrue(html.contains("function normalizeAuthError"))
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
    assertTrue(html.contains("id=\"v-ref-network\""))
    assertTrue(html.contains("get_my_referral_network_stats"))
    assertTrue(html.contains("admin_set_referral_network_access"))
    assertTrue(html.contains("admin_list_referral_access"))
    assertTrue(html.contains("Referrer earns +20 Coins"))
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
    assertTrue(html.contains("id=\"p2w-update-modal\""))
    assertTrue(html.contains("id=\"p2w-upd-go\""))
    assertTrue(html.contains("id=\"admin-app-update-card\""))
    assertTrue(html.contains("id=\"admin-upd-save\""))
    val profileSection = html.substringAfter("<section id=\"v-settings\"").substringBefore("<section id=\"v-tx\"")
    assertTrue(profileSection.contains("id=\"settings-profile\""))
    assertTrue(profileSection.contains("id=\"m-pw\""))
    assertTrue(profileSection.contains("id=\"s-logout\""))
    assertTrue(profileSection.contains("id=\"m-check-update\""))
    assertTrue(html.contains("admin_set_app_update"))
    assertTrue(html.contains("id=\"av-sound-btn\""))
    assertTrue(html.contains("function startFlySound"))
    assertTrue(html.contains("function playCrashSound"))
    assertFalse(html.contains("M21 3L14.2 21L10.5 13.5L3 9.8L21 3Z"))
    assertEquals(7, BuildConfig.VERSION_CODE)
    assertEquals("1.6", BuildConfig.VERSION_NAME)
    assertTrue(html.contains("#bal::after{display:none}"))
    assertTrue(html.contains("\$('bal').textContent=isAdmin()?'Admin':Number(S.balance||0).toLocaleString('en-IN');"))
    assertTrue(html.contains("id=\"p2w-reject-wdr-modal\""))
    assertTrue(html.contains("id=\"p2w-reject-wdr-reason\""))
    assertTrue(html.contains("id=\"p2w-reject-wdr-confirm\""))
    assertTrue(html.contains("admin_reject_withdrawal"))
    assertTrue(html.contains("my_withdrawal_requests_v2"))
    assertTrue(html.contains("admin_list_withdrawal_requests_v2"))
    assertTrue(html.contains("wdr-reject-reason-box"))
    assertTrue(html.contains("id=\"coming-soon-row-head\""))
    assertTrue(html.contains("Coming Soon"))
    assertFalse(html.contains("data-coming-soon=\"Ludo\""))
    assertTrue(html.contains("data-open-route=\"ludo\""))
    assertTrue(html.contains("data-coming-soon=\"3 Patti\""))
    assertFalse(html.contains("data-coming-soon=\"Rummy\""))
    assertTrue(html.contains("data-open-route=\"rummy\""))
    assertTrue(html.contains("id=\"v-ludo\""))
    assertTrue(html.contains("id=\"ludo-mode-tabs\""))
    assertTrue(html.contains("id=\"ludo-bet-tabs\""))
    listOf(5, 10, 25, 50, 100, 200, 500).forEach { bet ->
      assertTrue(html.contains("data-ludo-bet=\"$bet\""))
    }
    assertTrue(html.contains("id=\"ludo-search-stage\""))
    assertTrue(html.contains("id=\"ludo-board-svg\""))
    assertTrue(html.contains("ludo_matchmake"))
    assertTrue(html.contains("ludo_start_with_bots"))
    assertTrue(html.contains("ludo_finish_match"))
    assertTrue(html.contains("id=\"bets-tab-ludo\""))
    assertTrue(html.contains("id=\"bets-pane-ludo\""))
    assertTrue(html.contains("admin_ludo_bets"))
    assertTrue(html.contains("Platform Fee (15%)"))
    assertTrue(html.contains("Winner Prize (85%)"))
    assertTrue(html.contains("id=\"ludo-turn-timer\""))
    assertTrue(html.contains("ludo-hearts"))
    assertTrue(html.contains("function rollDiceValue"))
    assertTrue(html.contains("id=\"lb-from-date\""))
    assertTrue(html.contains("id=\"lb-to-date\""))
    assertTrue(html.contains("id=\"lb-daily-rows\""))
    assertTrue(html.contains("id=\"v-rummy\""))
    assertTrue(html.contains("@keyframes rummyPileGlow"))
    assertFalse(html.contains(".rummy-pile-btn.can-draw{border-style:solid;border-color:#ffd43b;background:rgba(255,212,59,.12);animation:ludoTokPulse"))
    assertTrue(html.contains("id=\"rummy-bet-tabs\""))
    listOf(5, 10, 25, 50, 100, 200, 500).forEach { bet ->
      assertTrue(html.contains("data-rummy-bet=\"$bet\""))
    }
    assertTrue(html.contains("id=\"rummy-search-stage\""))
    assertTrue(html.contains("id=\"rummy-turn-timer\""))
    assertTrue(html.contains("rummy_matchmake"))
    assertTrue(html.contains("rummy_start_with_bots"))
    assertTrue(html.contains("rummy_finish_match"))
    assertTrue(html.contains("id=\"bets-tab-rummy\""))
    assertTrue(html.contains("id=\"bets-pane-rummy\""))
    assertTrue(html.contains("admin_rummy_bets"))
    assertTrue(html.contains("id=\"rb-from-date\""))
    assertTrue(html.contains("id=\"rb-to-date\""))
    assertTrue(html.contains("id=\"rb-daily-rows\""))
    assertTrue(html.contains("id=\"rummy-finish-slot\""))
    assertTrue(html.contains("id=\"rummy-move-left\""))
    assertTrue(html.contains("id=\"rummy-move-right\""))
    assertTrue(html.contains("id=\"rummy-group-btn\""))
    assertTrue(html.contains("function moveCardInGroups"))
    assertTrue(html.contains("function sfxShuffle"))
    assertTrue(html.contains("function sfxDraw"))
    assertTrue(html.contains("rummy-drag-ghost"))
    val ludoScript = html.substringAfter("<script id=\"play2win-ludo-game\">").substringBefore("</script>")
    val rummyScript = html.substringAfter("<script id=\"play2win-rummy-game\">").substringBefore("</script>")
    assertTrue(ludoScript.contains("turnDeadlineMs"))
    assertTrue(ludoScript.contains("function syncTurnClock"))
    assertTrue(ludoScript.contains("else if(phase!=='playing'){clearAllTimers();}"))
    assertTrue(ludoScript.contains("var sixBoost=(pCount===2)?1.41:(pCount===3)?1.11:1.00;"))
    assertTrue(rummyScript.contains("turnDeadlineMs"))
    assertTrue(rummyScript.contains("function syncTurnClock"))
    assertTrue(rummyScript.contains("DECLARE_REVEAL_SECONDS=10"))
    assertTrue(rummyScript.contains("function startOpponentDeclareReveal"))
    assertTrue(html.contains("id=\"rummy-declare-overlay\""))
    assertTrue(html.contains("id=\"rummy-decl-groups\""))
    assertTrue(rummyScript.contains("if(p.is_bot&&Math.random()<0.56)"))
    val scriptStart = html.indexOf("<script>\n(function(){")
    assertTrue(scriptStart > html.indexOf("id=\"p2w-reject-wdr-modal\""))
    assertTrue(scriptStart > html.indexOf("id=\"p2w-update-modal\""))
    assertTrue(html.contains("id=\"admin-upd-live-status\""))
    assertTrue(html.contains("function compareVersionNames"))
    assertTrue(html.contains("checkForAppUpdate(false,true)"))
    assertTrue(html.contains("grid-template-columns:repeat(3,minmax(0,1fr))!important"))
    assertFalse(html.contains("#v-home .game-launch-item,#v-home .game-launch-icon{width:58px!important"))
    assertTrue(html.contains("https://drive.google.com/uc?export=download&confirm=t&id="))
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
