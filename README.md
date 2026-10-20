# kpub

A native macOS client for browsing a media catalog and downloading movies and shows for offline viewing. Built with SwiftUI, AVKit, and ffmpeg.

## Features

- Browse, search, and filter the catalog; open actor and director filmographies.
- Add titles to lists using a poster's context menu, or create a list.
- Keep cover artwork on disk for offline browsing, including existing downloads on startup. Missing artwork is fetched when a connection is available.
- Resize posters with the toolbar slider or Command–=/Command–minus; Command–0 resets the size.
- Download individual episodes, seasons, or movies with selected audio tracks and subtitles.
- Resume segmented HLS downloads after interruption and encode with hardware HEVC/H.264 or software x265.
- Fetch missing English subtitles from OpenSubtitles, with no API key required by the current legacy integration.
- Recompress downloaded files locally while preserving audio and subtitles. Keep the original if the result is larger.
- Play supported files offline, remember playback position, and adjust subtitle appearance.

The interface currently uses Russian labels. The project documentation is in English.

## Requirements

- macOS 14 or later.
- Xcode or Command Line Tools with Swift 5.10 or later.
- `ffmpeg` and `ffprobe` on PATH or configured in the application's settings.
- An account with access to the configured media provider.

```sh
brew install ffmpeg
```

Media tools are not bundled. Hardware encoding depends on your Mac's VideoToolbox support.

## Build and install

Run these commands from the checkout:

```sh
make build                    # Build the executable
make test                     # Run offline tests
make app                      # Build build/kpub.app with an ad-hoc signature
make install                  # Install into ~/Applications/kpub.app
make run                      # Build and launch
make check                    # Test, package, lint the plist, verify signature
make dist                     # Create build/kpub-macos.zip after checks
make clean                    # Clean Swift build products
```

Overrides:

```sh
make app CONFIGURATION=debug
make install INSTALL_DIR=/Applications
```

These are local builds, without Apple notarization or a Developer ID signature. `make install` updates the destination app bundle; quit the installed app before updating it. Build artifacts are ignored by Git.

## Sign in and download

1. Open kpub and enter your own HTTPS mirror address on the login screen. No mirror is supplied by default. The address is saved locally; the API follows it unless you configure a separate API address in Settings.
2. Sign in on the embedded website. The mirror's session cookies authorize its `/v1` endpoints.
3. Select episodes or a movie, then choose source quality, audio, subtitles, and encoding profile.
4. Follow live progress in Downloads (sidebar or Command–J). The standalone Downloads window is available even while signed out. It separates running work, waiting jobs, pauses, failures, and completed files, with per-job progress, transferred bytes, and speed. Finished files appear in the local library.

The mirror proxies `/manifest/` URLs; media segments are downloaded from the CDN. Device-code OAuth and manual token login are alternatives, but OAuth endpoints may not be reachable from every network.

A 720p widescreen release may be 1280×576 rather than 1280×720. Source quality and output encoding are separate settings. External subtitles can belong to a different release: automatic duration checks do not guarantee synchronization. If subtitles cannot be fetched, the video may still complete without them.

## App links

The app registers the `kpub://` URL scheme. Opening a download link queues work immediately; the application must be installed or registered with Launch Services and signed in.

```sh
open 'kpub://download?item=ITEM_ID&season=4&audio=eng&quality=720&subs=eng&external=eng&preset=compact720&container=mkv'
```

Replace `ITEM_ID` with the provider's numeric ID. Parameters:

| Parameter | Meaning |
| --- | --- |
| `item` | Required title ID |
| `season` | Season number; omit to select all seasons |
| `episodes` | Comma-separated episode numbers; omit for all selected episodes |
| `audio` | Comma-separated languages or API track indices; first is default |
| `quality` | Source quality class, such as `720`; default is automatic |
| `subs` | Languages to select from provider subtitles |
| `external` | Fallback subtitle languages if missing at the provider |
| `preset` | Encoding preset ID; see `EncodeSettings.swift` |
| `container` | `mp4` or `mkv` |

Already queued or completed video IDs are skipped. Without a preset the app uses the last encoding settings. Without an audio match it falls back to the first track, so verify the resulting queue when exact language selection matters.

## Local data and privacy

Credentials and queue state live in `~/Library/Application Support/Kpub/`; credentials are written with mode `0600`. Default downloads go to `~/Movies/Kpub/`. An existing configured download directory can be kept unchanged.

Do not commit session cookies, authentication files, signed CDN URLs, or downloaded media. The OAuth integration includes the shared public Kodi client identifier and client secret; these are client identifiers, not user credentials. No credentials are needed for offline tests. Do not post authentication files in issues.

## Agent skill

The reusable skill is in [`skills/kpub/SKILL.md`](skills/kpub/SKILL.md). Install it for Codex with:

```sh
make skill-install
# Optional: make skill-install SKILLS_DIR=/your/skills/directory
```

The skill covers build/install commands, app links, queue operation, and output verification.

## Development

`Sources/Kpub` contains the SwiftUI app; `Sources/KpubCore` contains API and download logic. `Tests/KpubCoreTests` covers parsing and real ffmpeg pipelines using synthetic media and sanitized fixtures. ffmpeg-dependent tests can be skipped when tools are absent. Network subtitle tests are opt-in:

```sh
KP_LIVE=1 swift test --filter testLiveOpenSubtitles
```

GitHub Actions runs `make check` on macOS. Publishing and release uploads are manual.

Use only media you are authorized to access and download. This is an independent client and is not affiliated with the provider. A distribution license has not yet been selected; add one before offering the project under an open-source license.

## Versioning and releases

`VERSION` is the source of truth for the app version. The build script writes it into both bundle version fields before signing. Release notes are maintained in [CHANGELOG.md](CHANGELOG.md).

```sh
make version                 # Print the current version
make bump PART=patch         # Or minor / major
make dist                    # Build and validate a versioned macOS ZIP
```

Before a release, move the Unreleased changes into a dated version section, commit the version and changelog together, then create an annotated `vMAJOR.MINOR.PATCH` tag. Distributable builds currently use ad-hoc signing and are not notarized. ffmpeg must be installed separately.
