# Mister Download Manager — iOS port

SwiftUI reimplementation of [anefzaoui/misterdownloadmanager](https://github.com/anefzaoui/misterdownloadmanager) (GPL-3.0, Rust/egui desktop app for Windows, Mac and Linux), scoped to what iOS sandboxing actually allows. Plus a full in-app web browser, built for iOS 16 and later.

## Download manager

- Segmented HTTP/HTTPS downloads (up to 16 connections), resume, per-segment progress bars, speed limiting, retry
- Categories (Video, Music, Documents, Compressed, Programs, Images, Torrents, Other), search, queue / start-all / pause-all
- Add URL with probe (size, resume support, MIME, filename), referer, checksum verification (MD5/SHA1/SHA256)
- Scheduler window (gates starting/pausing while the app runs; iOS cannot wake or shut down the phone)
- Video / gallery grabber from page HTML (direct mp4/m3u8/image links) + unencrypted HLS segment download
- Debrid unrestricting (Real-Debrid, AllDebrid, Premiumize, TorBox, Mega-Debrid) with your own keys
- Torrent metadata (.torrent parsing, file list, tracker announce, peer list) + experimental sequential single-file peer download
- ZIP extraction (ZIPFoundation); downloaded files visible in the Files app, share, preview, rename
- LAN remote control (plain HTTP, trusted Wi-Fi, foreground only), clipboard link detection, download notifications
- Themes (Classic, Dark, Light, High contrast, Metro, Adwaita, Breeze, Luna, Aero, Aqua), interface scale, URL scheme `mdm://add?url=…`

## In-app browser

Open it from the Downloads screen ("Kembali ke Download" in the ⋯ menu goes back). Safari-style floating bottom navbar (back / address pill with progress / tabs / ⋯ menu) over a Chrome-style tab system.

- **Tabs:** unlimited tabs, live snapshot previews, favicons, search filter, swipe/tab grid overview, tab groups (name + color + favicon collage), incognito tabs with a non-persistent data store, inactive tabs (unused for 21+ days), pull-to-refresh, stop/reload in the address pill, back/forward gestures
- **Start page:** search box, favorites grid (bookmarks), privacy card with factual stats, Google as the default search engine (DuckDuckGo, Bing, Yahoo, Ecosia and Brave available)
- **AdBlock:** built-in + custom URL filters compiled together into one content-rule list, allowlist wins, per-site shield in the address pill
- **Extensions:** JavaScript userscripts (real Chrome extensions cannot run on iOS) with document-start / document-end timing, create/edit/enable/disable, applied per tab. Scripts can also be imported from `.js` files — a `==UserScript==` metadata block's `@name` and `@run-at` are respected when present
- **Download capture:** attachment responses, common file extensions and binary MIME types are intercepted straight into the download queue. JavaScript-generated `blob:` downloads are not captured yet
- **Media finder:** lists playable video/audio on the page for one-tap download
- **Background playback + Picture in Picture:** YouTube and other media keep playing with the app in the background or the screen locked (toggleable in settings). PiP is entered from the **PiP** button inside the page: on YouTube it sits in the player's own control bar next to the fullscreen button; on other sites it floats at the video's corner — a real tap on the page is what WebKit accepts as the gesture for PiP. ⋯ > Picture in Picture is kept as a fallback. YouTube can change its player at any time, so this may need maintenance
- **DevTools (F12):** ⋯ > DevTools (F12) opens Console (page logs + JavaScript REPL, with level filter), Elements (tap-to-inspect, computed style, full DOM with filter, copy HTML), Network (navigation responses + live fetch/XHR + resource timing; tap an entry to see request/response headers and the response body — bodies are only available for fetch/XHR, WebKit does not expose navigation bodies) and Storage (cookies, local/session storage, with per-item delete and clearing). No JavaScript debugger/breakpoints, profiler, device emulation or WebSocket frame inspection — WKWebView does not expose those
- **History, bookmarks, clear browsing data:** ⋯ > Riwayat (searchable, grouped by day, private tabs never recorded), ⋯ > Bookmark (list, edit, delete, plus import of the bookmark HTML file Safari/Chrome export on desktop — iOS does not let apps read their bookmarks directly), ⋯ > Hapus Data Penjelajahan (history, cookies, cache, all site data)
- **Content settings:** block script popups (tapped links still open), link preview on long-press on/off, address detection (street addresses become links to Google Maps for routes and local info), Web Inspector (inspect pages from Safari on a Mac)
- **Reader mode:** ⋯ > Mode Baca shows a clean article view with adjustable text size (best effort: works best on articles)
- **Translate, find in page, reading list:** ⋯ > Terjemahkan halaman (in-place Google Translate, reload restores the original; page text goes through Google's servers), ⋯ > Cari di halaman (match count + next/previous), ⋯ > Daftar Bacaan (save pages for later, read/unread state, survives restarts)
- **Ask AI ("Minta AI"):** send the current page (title, URL, text) to Gemini, ChatGPT or Claude via their public streaming APIs, or hand off to Muse on the web. API keys are entered in the app and stored only in the device Keychain — they are never written to settings files or sent anywhere else

## Honestly not ported

Chrome extensions and the desktop browser native-messaging host (the in-app browser captures downloads itself instead), system tray, wake/shutdown, yt-dlp/ffmpeg processing, 7z/RAR via 7-Zip, MCP server, CLI switches, DHT/uTP/UPnP torrenting and background seeding, the full 86-language catalogue, desktop screen-reader menus. See Settings → About in the app.

## Build & install

Push to `main` — GitHub Actions (macOS runner + XcodeGen) builds an **unsigned** `.ipa` artifact. Install via TrollStore / Feather / ESign / AltStore. No signing identity is required or used.

```
brew install xcodegen
xcodegen generate
xcodebuild -project MDM.xcodeproj -scheme MDM -configuration Release -sdk iphoneos -archivePath build/MDM.xcarchive archive CODE_SIGNING_ALLOWED=NO
```

## Privacy

Downloads and browsing stay on the device. Ask AI provider keys live only in the iOS Keychain. No account, no analytics, no tracking.

## License

GPL-3.0, like the original. See `LICENSE`. This port is not affiliated with or endorsed by the original author; it is a separate SwiftUI implementation of the same ideas.
