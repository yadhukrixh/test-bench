package com.qaworkbench.spike_fixture

import android.app.Activity
import android.os.Bundle
import android.webkit.WebView
import android.webkit.WebViewClient

class WebLabActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    WebView.setWebContentsDebuggingEnabled(true)
    val view = WebView(this)
    view.webViewClient = WebViewClient()
    view.settings.javaScriptEnabled = true
    val url = intent?.data?.toString() ?: "https://example.com"
    view.loadUrl(url)
    setContentView(view)
  }
}
