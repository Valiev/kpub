---
name: kpub
description: Build, install, develop, and operate the kpub macOS offline media client, including download links, audio selection, encoding, and subtitle verification. Use for kpub application tasks.
---

# kpub

Locate the checkout from the user's context; it contains `Package.swift`, `Makefile`, and `Sources/KpubCore`. Read its README before choosing commands. Do not assume the current directory is the checkout.

## Build and install

Use `make check` for tests, app packaging, and signature verification. `make install` installs into `~/Applications`; override `INSTALL_DIR` when requested. `make run` launches `build/kpub.app`. ffmpeg/ffprobe are external dependencies, not bundled.

Do not interrupt active downloads or encoding just to restart an app. Inspect the queue first. Local credentials and the queue are in `~/Library/Application Support/Kpub/` and must stay out of logs and commits.

## Download through the application

Use the UI or `kpub://download` URLs handled by `AppModel.handleDeepLink`. A URL queues work immediately: use it only for the user's requested title, episodes, and settings. Do not edit `downloads.json` while the application is running.

Find the actual item ID and season/episode numbers through the authenticated mirror API. Do not infer current availability from past examples. Prefer the existing login session; let the user enter credentials if needed.

Example shape (replace the item ID):

```text
kpub://download?item=ITEM_ID&season=4&audio=eng&quality=720&subs=eng&external=eng&preset=compact720&container=mkv
```

`quality` selects the source; `preset` selects encoding. Check `EncodeSettings.swift` for valid preset IDs. `episodes` is comma-separated; omit it for the season. Already queued/completed video IDs are skipped. External subtitles are fallback-only when that language is absent at the provider; timing may differ across releases.

## Verify completion

Inspect queue status, then use ffprobe on every requested output to verify resolution, language tags, subtitle streams, and duration. A completed job alone does not prove subtitles were found. A 720p widescreen source may be 1280×576. Report failed/missing episodes or subtitles explicitly; do not claim sync was verified from language tags or cue bounds alone.

## Code map

- `Sources/Kpub/App`: state, bookmarks, deep links.
- `Sources/Kpub/UI`: SwiftUI screens and AVKit playback.
- `Sources/KpubCore/API`: mirror API, models, local credentials.
- `Sources/KpubCore/Downloads`: queue, HLS, ffmpeg, external subtitles.
- `Tests/KpubCoreTests`: fixtures and media pipeline tests.

Keep real cookies, access tokens, signed CDN URLs, and downloaded media out of fixtures. Live subtitle checks are opt-in with `KP_LIVE=1`. GitHub publishing requires a separate user request.
