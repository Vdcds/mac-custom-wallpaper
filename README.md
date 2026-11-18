# Wake Scenes

A small native macOS menu-bar app. Import a video, choose a scene, and get one muted intro after unlocking or waking your Mac, followed by its final still.

This is an early local build for macOS 14+. Physical lid-open and unlock timing still need testing on more Macs. No notarized download is available yet.

## Build and open the app

Use macOS 14 or later with the Swift compiler and Apple command-line SDKs installed. Xcode is optional.

```sh
git clone https://github.com/Vdcds/mac-custom-wallpaper.git
cd mac-custom-wallpaper
./scripts/build.sh
open ".build/Wake Scenes.app"
```

The build script creates `.build/Wake Scenes.app` for the Mac's current architecture and signs it locally. The delivered build is for Apple silicon. It has no package dependencies. Local playback works offline; repository imports need a network connection.

To use launch at login, quit the app, copy it to Applications, and open that copy. Enable **Launch at login** in the library. If macOS requests approval, use the app's **Open Settings** button. Keep the installed copy at the same path. This local build is ad-hoc signed, not notarized for distribution.

## Choose a wallpaper

1. Open **Wake Scenes** from its sun-shaped menu-bar icon.
2. Drop local videos onto the library window, or click **Import**. You can select several files.
3. Click **Use scene**. The intro plays once, muted, then settles on the saved final frame.
4. Use **Replay now** whenever you want another intro.

For the visual scene carousel, choose **Choose Scene** from the menu bar or library. Use the left and right arrow keys to browse, then press Return to play. Click a thumbnail to play it immediately. Escape closes the picker without changing the wallpaper. While Wake Scenes is active, Command-Shift-S opens the picker. The library and picker hide during playback so the desktop is visible.

The first import becomes the selected system wallpaper. Selecting a scene explicitly plays its intro. Launching or resuming the app restores the still without replaying. The same scene fills every connected display, cropped to fill each screen.

Import support depends on the codecs macOS can decode, rather than a fixed extension list. H.264 MP4 and HEVC MOV have been tested. If a file fails, try opening it in QuickTime Player and choosing **File → Export As**. Export an H.264 or HEVC MOV or MP4 copy, then import that copy. The app does not include a converter or promise support for every codec.

Imported videos are copies. Moving or deleting the source does not affect the library. Importing the same bytes again does not add a duplicate. Removing a scene deletes the imported copy and cached still, while preserving the original video.

## Import from a repository

1. Open the library and click **From GitHub…**.
2. Paste a public GitHub repository link and click **Find wallpapers**. Branch, folder, and video file links also work.
3. Select the videos you want. The list shows file paths, download sizes, and matching stills. Only the first video is selected initially.
4. Click **Import & use**. The first selected scene plays once, and every completed import stays in your local library.

For example, paste `https://github.com/yamz8/omarchy-flight-15-theme` for Flight 15, or `https://github.com/omacom/omarchy/tree/quattro/themes/lumon` for a theme inside Omarchy's main repository.

The importer finds videos recursively. It pairs `backgrounds/intros/name.mp4` with `backgrounds/name.webp` (or another supported image format), and standalone videos with matching images in their own folder. Without a matching image, it extracts the video's final usable frame. Matching images are saved as PNG at their source dimensions. Videos are copied without transcoding, so their quality depends on the original footage.

Downloads are pinned to the scanned commit. Source links appear in the library, and available repository notices, licenses, and the root README are kept under `Source Packs/GitHub` in the app's data folder. Git LFS media is downloaded and checked against its declared size and SHA-256 hash. The displayed size for an LFS pointer can be smaller than the final media. Downloads have a 2 GB video limit and an 8 GB video total per import.

Reimporting a video keeps its existing local copy. If that copy has no paired repository poster yet, the importer adds it. Existing posters are preserved.

Only media files are imported. Theme scripts and Linux desktop effects are not run. Image-only themes, videos hosted only in release assets or external links, private repositories, and hosts other than GitHub need a local video import instead. A supported filename does not guarantee that macOS can decode its codec. Canceling keeps completed imports and removes temporary downloads. Imported scenes work offline afterward.

## Lock and unlock

While locked, the selected still remains installed as the system wallpaper. After a successful unlock, the app waits briefly for the lock screen to clear and plays the selected intro once. Touch ID works the same way as a password. Locking during playback stops the intro and settles on the still. An unsuccessful authentication does not start playback.

The app listens for session unlock. It does not read or validate passwords. macOS controls lock-screen appearance, including blur and overlays. The pre-boot FileVault screen and a login that finishes before the app launches are outside this running-session feature.

## Keep the same wallpaper across Spaces

The selected still is installed as your actual macOS system wallpaper. In **System Settings → Wallpaper**, enable **Show on all Spaces** to use it on every desktop and display, including Mission Control thumbnails. macOS can turn this setting off after an application selects a different image, so check it again after choosing another scene.

Desktop windows remain in place during Space changes. They fill the screen and render at its native Retina scale. Original-resolution PNG stills are retained. Repository imports use matching posters when available. A 4K file can still contain soft, compressed, interpolated, or upscaled source detail; importing it cannot recover missing detail.

## Stop and quit

Turn off **Wake & unlock replays**, or choose **Stop Automatic Replays** from the menu bar to stop animation. The selected system wallpaper stays in place. Quitting also keeps it. Closing the library window keeps the menu-bar app running.

Use **Restore Previous Wallpaper** to stop replays and restore the wallpaper saved before the first native install. A local backup retains its image and display options. Wallpaper assets live outside scene folders so removing an imported scene does not delete the image macOS uses. The app does not change desktop icons or unrelated preferences.

## Verify the app

Run the app verification from a logged-in, unlocked graphical session. `ffmpeg` is needed only to generate test footage.

```sh
./scripts/verify.sh
```

`./scripts/test-lifecycle.sh` runs 13 focused event-state checks without changing the desktop. The full script runs those checks, builds the app, and runs H.264 and portrait HEVC tests in separate libraries under `artifacts/`. Each run writes `run.log` and `library/verification.json`. It posts synthetic sleep and wake notifications inside the test process; it does not sleep or lock your Mac.

See [verification results and remaining manual tests](docs/VERIFICATION.md) and [lifecycle behavior and storage](docs/BEHAVIOR.md).

`./scripts/test-repository.sh` runs offline repository parsing and download-failure checks. `./scripts/verify-repository.sh` additionally downloads real media from public repositories and exercises import, playback, still handoff, provenance, and persistence in an isolated app library. It requires network access and an unlocked graphical session. Its playback check uses desktop windows without changing the native system wallpaper. The app verification writes its report under `artifacts/`.

## Credits and license

Source code is MIT licensed. The Flight 15 scenes shown in the demo come from [yamz8/omarchy-flight-15-theme](https://github.com/yamz8/omarchy-flight-15-theme), using SpaceX footage. That footage retains its original rights and is not included with the app. See [media notices](NOTICE.md).
