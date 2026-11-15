package com.example

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
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
  fun `bundled html asset is packaged`() {
    val context = ApplicationProvider.getApplicationContext<Context>()
    val html = context.assets.open("aistudio/index_5ad215fb.html").bufferedReader().use { it.readText() }
    assertTrue(html.contains("<title>Play2Win</title>"))

    val homeSection = html.substringAfter("<section id=\"v-home\"").substringBefore("</section>")
    assertTrue(!homeSection.contains("ref-banner"))

    val settingsSection = html.substringAfter("<section id=\"v-settings\"").substringBefore("<section id=\"v-tx\"")
    assertTrue(settingsSection.contains("id=\"m-share\""))
    assertTrue(settingsSection.contains("id=\"v-share\""))
    assertTrue(settingsSection.contains("id=\"referral-card\""))
    assertTrue(html.contains("function resolveAppDownloadUrl"))
  }
}
