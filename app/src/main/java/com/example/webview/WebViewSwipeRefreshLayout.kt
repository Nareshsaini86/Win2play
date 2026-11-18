package com.example.webview

import android.content.Context
import android.view.MotionEvent
import android.view.ViewGroup
import android.webkit.WebView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import java.util.concurrent.atomic.AtomicBoolean

/**
 * [SwipeRefreshLayout] wrapper around a [WebView] that coordinates pull-to-refresh gestures with
 * both the WebView's vertical scroll position and inner HTML scrollable containers reported via
 * [canPullRefresh].
 */
class WebViewSwipeRefreshLayout(
  context: Context,
  private val webView: WebView,
  private val canPullRefresh: AtomicBoolean,
  private val pullRefreshLocked: AtomicBoolean = AtomicBoolean(false),
) : SwipeRefreshLayout(context) {
  private var hasActiveDownPointer = false

  init {
    layoutParams =
      ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
    setOnChildScrollUpCallback { _, _ ->
      pullRefreshLocked.get() ||
        !canPullRefresh.get() ||
        webView.scrollY > 0 ||
        webView.canScrollVertically(-1)
    }
    addView(webView)
  }

  fun applyThemeColors(isDayTheme: Boolean) {
    val bgHex = if (isDayTheme) "#FFFFFF" else "#171A3C"
    val fgHex = if (isDayTheme) "#FF8A00" else "#FFC94D"
    setProgressBackgroundColorSchemeColor(android.graphics.Color.parseColor(bgHex))
    setColorSchemeColors(
      android.graphics.Color.parseColor(fgHex),
      android.graphics.Color.parseColor("#FF9F1C"),
    )
  }

  override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
    if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
      hasActiveDownPointer = false
    }
    val handled = super.dispatchTouchEvent(ev)
    if (
      ev.actionMasked == MotionEvent.ACTION_UP ||
        ev.actionMasked == MotionEvent.ACTION_CANCEL
    ) {
      hasActiveDownPointer = false
      if (!pullRefreshLocked.get()) {
        canPullRefresh.set(true)
      }
    }
    return handled
  }

  override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
    if (!isEnabled || pullRefreshLocked.get() || !canPullRefresh.get()) {
      hasActiveDownPointer = false
      return false
    }
    return when (ev.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        val eligible = isEnabled && !pullRefreshLocked.get() && !isRefreshing && !canChildScrollUp()
        val intercepted = super.onInterceptTouchEvent(ev)
        hasActiveDownPointer = eligible
        intercepted
      }
      MotionEvent.ACTION_MOVE -> {
        if (!hasActiveDownPointer) return false
        super.onInterceptTouchEvent(ev)
      }
      MotionEvent.ACTION_UP,
      MotionEvent.ACTION_CANCEL -> {
        val res = super.onInterceptTouchEvent(ev)
        hasActiveDownPointer = false
        res
      }
      else -> super.onInterceptTouchEvent(ev)
    }
  }

  override fun onTouchEvent(ev: MotionEvent): Boolean {
    if (!isEnabled || pullRefreshLocked.get() || !canPullRefresh.get()) {
      hasActiveDownPointer = false
      return false
    }
    return when (ev.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        val eligible = isEnabled && !pullRefreshLocked.get() && !isRefreshing && !canChildScrollUp()
        val handled = super.onTouchEvent(ev)
        hasActiveDownPointer = eligible
        handled
      }
      MotionEvent.ACTION_MOVE -> {
        if (!hasActiveDownPointer) return false
        super.onTouchEvent(ev)
      }
      MotionEvent.ACTION_UP,
      MotionEvent.ACTION_CANCEL -> {
        val res = if (hasActiveDownPointer) super.onTouchEvent(ev) else false
        hasActiveDownPointer = false
        res
      }
      else -> if (hasActiveDownPointer) super.onTouchEvent(ev) else false
    }
  }
}
