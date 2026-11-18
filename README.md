# Wake Scenes

A small native macOS menu-bar app. Import a video, choose a scene, and get one muted intro after wake, followed by its final still.

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

The first import becomes the selected still. Selecting a scene explicitly plays its intro. Launching or resuming the app restores the still without replaying. The same scene fills every connected display, cropped to fill each screen.

Import support depends on the codecs macOS can decode, rather than a fixed extension list. H.264 MP4 and HEVC MOV have been tested. If a file fails, try opening it in QuickTime Player and choosing **File → Export As**. Export an H.264 or HEVC MOV or MP4 copy, then import that copy. The app does not include a converter or promise support for every codec.

Imported videos are copies. Moving or deleting the source does not affect the library. Importing the same bytes again does not add a duplicate. Removing a scene deletes the imported copy and cached still, while preserving the original video.

## Stop and quit

Turn off **Wallpaper on**, or choose **Stop Wallpaper** from the menu bar. Your existing wallpaper appears immediately. Use **Quit Wake Scenes** to close the app completely. Closing the library window keeps the menu-bar app running.

The app never changes your system wallpaper, desktop icons, or unrelated preferences. Its desktop windows ignore mouse clicks.

## Verify the app

Run the app verification from a logged-in, unlocked graphical session. `ffmpeg` is needed only to generate test footage.

```sh
./scripts/verify.sh
```

The script builds the app and runs H.264 and portrait HEVC tests in separate libraries under `artifacts/`. Each run writes `run.log` and `library/verification.json`. It posts synthetic sleep and wake notifications inside the test process; it does not sleep or lock your Mac.

See [verification results and remaining manual tests](docs/VERIFICATION.md) and [lifecycle behavior and storage](docs/BEHAVIOR.md).

## Credits and license

Source code is MIT licensed. The Flight 15 scenes shown in the demo come from [yamz8/omarchy-flight-15-theme](https://github.com/yamz8/omarchy-flight-15-theme), using SpaceX footage. That footage retains its original rights and is not included with the app. See [media notices](NOTICE.md).
