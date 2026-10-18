# TODO

Items that are real and not done. Each one names the phase that picks it up.

- Phase 8: WebView inspection, after spike S8 is actually run.
- Dart `HttpClient` ignores the system HTTP proxy. On-device VPN capture lists DNS and TLS SNI. SOCKS5 MITM is off: this Play image cannot install a system CA, Flutter does not trust a user CA, and intercepting TLS put Lookmeal on a no-network screen.
- iOS live frames stay on `simctl` polling until Screen Recording works in the signed app. idb is not installed. iOS taps and the iOS tree are not available.
- Git commits and phase tags need `user.name` and `user.email`. They are unset on this machine, and this project does not change git config.
