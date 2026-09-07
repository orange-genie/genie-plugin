# Genie 1 — the desktop app

One source for macOS, Windows and Linux. Tauri: the app uses whatever webview the host already
ships (WebKit on macOS, WebView2 on Windows, WebKitGTK on Linux), so the download is a few
megabytes instead of the ~150 a bundled browser costs.

    app/tauri/       the Rust shell — two commands, and nothing else
    app/build/web/   the UI, generated from the site's ask.html and settings.html

## The two commands, and why they exist

`api_fetch` — a page served from `tauri://localhost` that calls `fetch("/api/chat")` resolves it
against the bundle and gets nothing. Pointing it at the site instead is blocked: the API sends no
CORS header for any origin. So the request is made from Rust, which is not a browser and has no
CORS. Only `/api/…` on one compiled-in host is reachable through it.

`open_external` — a wallet extension injects `window.ethereum` into a browser TAB and never into
a native webview, so a Connect button here could only pretend. This opens the system browser at
the connect page; the address returns over the `genie1://` scheme. The URL is checked against our
own host rather than trusted.

## Build

    cd app/tauri
    cargo tauri build                                  # this platform
    cargo tauri build --target universal-apple-darwin  # macOS, Intel + Apple Silicon

Releases are built by `.github/workflows/desktop.yml` on all three platforms at once.
