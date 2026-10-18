# WBFlutter

`flutter run --machine` on a pseudo-terminal. The driver waits for `app.debugPort` and sends `app.restart` and `app.stop`. The VM service client speaks JSON-RPC over the `wsUri` WebSocket. After a hot restart it is `getVM` again, because the isolate id changes.
