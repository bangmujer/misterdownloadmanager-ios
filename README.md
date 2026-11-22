# Mister Download Manager — iOS port

SwiftUI reimplementation of [anefzaoui/misterdownloadmanager](https://github.com/anefzaoui/misterdownloadmanager) (GPL-3.0, Rust/egui desktop app for Windows, Mac and Linux), scoped to what iOS sandboxing actually allows.

## What is ported

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

## Honestly not ported

Browser-extension download capture, system tray, wake/shutdown, yt-dlp/ffmpeg processing, 7z/RAR via 7-Zip, MCP server, CLI switches, native-messaging host, DHT/uTP/UPnP torrenting and background seeding, the full 86-language catalogue, desktop screen-reader menus. See Settings → About in the app.

## Build

Push to `main` — GitHub Actions (macOS runner + XcodeGen) builds an **unsigned** `.ipa` artifact. Install via TrollStore / Feather / ESign / AltStore. No signing identity is required or used.

```
brew install xcodegen
xcodegen generate
xcodebuild -project MDM.xcodeproj -scheme MDM -configuration Release -sdk iphoneos -archivePath build/MDM.xcarchive archive CODE_SIGNING_ALLOWED=NO
```

## License

GPL-3.0, like the original. See `LICENSE`. This port is not affiliated with or endorsed by the original author; it is a separate SwiftUI implementation of the same ideas.
