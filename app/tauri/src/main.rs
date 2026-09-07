// Genie 1 — the desktop app, one source for macOS, Windows and Linux.
//
// WHY THIS REPLACED THE SWIFT BUILD
// The first version was Swift + AppKit + WebKit. It was small and it worked, and it could only
// ever be a macOS app — those frameworks do not exist on the other two platforms, so a Windows
// build was not a compile away, it was a rewrite. Tauri uses whatever webview the host already
// ships (WebKit on macOS, WebView2 on Windows, WebKitGTK on Linux), which keeps the one property
// that mattered about the Swift build: no bundled browser, a few megabytes instead of 150.
//
// THE APP SHIPS THE CHAT. The UI lives in the bundle and only the API is remote. That is what
// makes this an app rather than a browser pointed at the website — and it is the reason a
// deployment mishap on the site cannot leave the app showing a marketing page.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use std::collections::HashMap;
use tauri::Emitter;

const ORIGIN: &str = "https://xearn.com";

#[derive(Serialize)]
struct ApiReply {
    status: u16,
    body: String,
    content_type: String,
}

/// The app's ONE door to the API.
///
/// THE BUG THIS ENDS. The bundled page calls fetch("/api/chat"). Served from tauri://localhost
/// that resolves to tauri://localhost/api/chat, which does not exist — so in the app the chat
/// never answered, sign-in methods never loaded (which is why the email door never appeared and
/// the only visible option was a wallet button), the NFT and name lookups returned nothing, and
/// the ledger stayed empty. Every one of those read as a different bug. They were one bug.
///
/// Rewriting the URL to the site in the page does not fix it either: the API sends no
/// access-control-allow-origin header, so a webview request from tauri://localhost is blocked
/// before it leaves. This call is made by Rust, which is not a browser and has no CORS.
///
/// THE PATH GUARD IS THE SECURITY MODEL. Only /api/… may be requested, and the host is fixed
/// here rather than passed in — so a compromised page cannot turn this into a general-purpose
/// requester pointed anywhere, and cannot reach the rest of the site either.
#[tauri::command]
async fn api_fetch(
    path: String,
    method: Option<String>,
    body: Option<String>,
    headers: Option<HashMap<String, String>>,
) -> Result<ApiReply, String> {
    if !path.starts_with("/api/") || path.contains("..") {
        return Err(format!("refused: {path} is not an API path"));
    }

    let url = format!("{ORIGIN}{path}");
    let verb = method.unwrap_or_else(|| "GET".into()).to_uppercase();

    let client = reqwest::Client::builder()
        .user_agent("Genie1-desktop")
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = match verb.as_str() {
        "POST" => client.post(&url),
        "PUT" => client.put(&url),
        "DELETE" => client.delete(&url),
        _ => client.get(&url),
    };
    if let Some(h) = headers {
        for (k, v) in h {
            req = req.header(k, v);
        }
    }
    if let Some(b) = body {
        req = req.body(b);
    }

    let res = req.send().await.map_err(|e| e.to_string())?;
    let status = res.status().as_u16();
    let content_type = res
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/json")
        .to_string();
    // The body is returned whatever the status is. An error body from the API carries the
    // message the page is written to show; swallowing it on a 4xx would replace a real
    // explanation with a generic one.
    let body = res.text().await.map_err(|e| e.to_string())?;

    Ok(ApiReply { status, body, content_type })
}

/// Open a URL in the SYSTEM browser, not in this window.
///
/// The whole point of the wallet handoff is to leave the webview — opening the connect page in
/// the app would land it back in the same webview that has no extension. The URL is checked
/// rather than trusted: only https, and only our own host, so a compromised page cannot use the
/// app as a launcher for anything it likes.
#[tauri::command]
fn open_external(url: String) -> Result<(), String> {
    if !url.starts_with("https://xearn.com/") {
        return Err(format!("refused: {url} is not ours"));
    }
    #[cfg(target_os = "macos")]
    let r = std::process::Command::new("open").arg(&url).spawn();
    #[cfg(target_os = "windows")]
    let r = std::process::Command::new("cmd").args(["/C", "start", "", &url]).spawn();
    #[cfg(all(unix, not(target_os = "macos")))]
    let r = std::process::Command::new("xdg-open").arg(&url).spawn();
    r.map(|_| ()).map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        // Registered FIRST, before anything else can take the launch: a second start hands its
        // arguments to the instance already running and exits, rather than opening a rival
        // window that owns none of the state the first one has.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            use tauri::Manager;
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.set_focus();
            }
            // A deep link arriving at a cold start comes in as an argument rather than through
            // on_open_url, so it is forwarded on the same channel and the page needs one path.
            for a in argv.iter().skip(1) {
                if a.starts_with("genie1://") {
                    let _ = app.emit("deep-link", a.clone());
                }
            }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .setup(|app| {
            // THE RETURN TRIP. The browser finishes the connect and sends the app to
            // genie1://connected?address=0x…  Every arriving link is handed to the page as one
            // event; the page decides what to do with it, and nothing here parses an address —
            // an address is only useful for READING what a wallet holds, and everything that
            // signs still happens in the wallet's own window.
            use tauri_plugin_deep_link::DeepLinkExt;
            let handle = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() {
                    let _ = handle.emit("deep-link", url.to_string());
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![api_fetch, open_external])
        .run(tauri::generate_context!())
        .expect("Genie 1 failed to start");
}
