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

The build script creates `.build/Wake Scenes.app` for the Mac's current architecture and signs it locally. The delivered build is for Apple silicon. It has no package dependencies and needs no network connection.

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

## Lock and unlock

While locked, the selected still remains installed as the system wallpaper. After a successful unlock, the app waits briefly for the lock screen to clear and plays the selected intro once. Touch ID works the same way as a password. Locking during playback stops the intro and settles on the still. An unsuccessful authentication does not start playback.

The app listens for session unlock. It does not read or validate passwords. macOS controls lock-screen appearance, including blur and overlays. The pre-boot FileVault screen and a login that finishes before the app launches are outside this running-session feature.

## Keep the same wallpaper across Spaces

The selected still is installed as your actual macOS system wallpaper. In **System Settings → Wallpaper**, enable **Show on all Spaces** to use it on every desktop and display, including Mission Control thumbnails. macOS can turn this setting off after an application selects a different image, so check it again after choosing another scene.

Desktop windows remain in place during Space changes. They fill the screen and render at its native Retina scale. Original-resolution PNG stills are retained. The local Flight 15 library can use its original lossless high-resolution posters instead of video-compressed ending frames.

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

## Credits and license

Source code is MIT licensed. The Flight 15 scenes shown in the demo come from [yamz8/omarchy-flight-15-theme](https://github.com/yamz8/omarchy-flight-15-theme), using SpaceX footage. That footage retains its original rights and is not included with the app. See [media notices](NOTICE.md).
