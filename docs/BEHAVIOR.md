# Lifecycle behavior and storage

Wake Scenes uses AppKit desktop-level windows and AVFoundation playback. The library window uses SwiftUI. Its desktop windows sit above the system wallpaper and below desktop icons. The selected still is also installed through NSWorkspace's public desktop-image API. Quitting keeps that native wallpaper. An explicit restore action uses a saved copy of the previous image and its display options.

## Playback and stills

Import copies a video into a staging directory, checks AVFoundation playback support, and extracts a frame near the end of the video track with exact time tolerance. Extraction retries earlier positions if the end cannot be decoded. Audio that continues after the picture does not extend the intro. The video and PNG move into the library after import succeeds.

Stills are extracted at native source dimensions. A scene-local wallpaper.png, when present, supplies an original high-resolution poster; otherwise still.png supplies the extracted ending. Both still and video layers use each screen's backing scale.

A shared muted AVPlayer drives the display windows. The previous scene's still remains underneath the player layers while the next video prepares its first frames. The new scene's ending is installed only when its intro finishes or is suspended. A boundary observer at the extracted frame's timestamp switches to the matching still. Completion and failure notifications also settle playback. Settling pauses the player, detaches every video layer, removes observers, clears the player item, and releases the player. No looping, periodic player observer, or active video decoder remains.

Import validation checks the playable track and end frame, rather than decoding the entire file. Damage elsewhere in a clip can still fail during playback. The app reports playback failure and keeps the cached still visible. Load and stall timeouts also return to the still.

## Local storage

The default library is `~/Library/Application Support/Wake Scenes/`. Its `library.json` records scene metadata, selection, and the enabled state. Content-hash folders contain the copied video and `still.png`. Manifest writes are atomic. A malformed manifest produces an error and blocks writes, preserving the existing files.

The optional `--library /absolute/path` argument selects an isolated library for verification. Import runs off the main thread and processes one batch at a time. The app makes no network requests.

## Wake events

A public NSWorkspace system-sleep or display-sleep notification arms a replay. Wake and screen-wake notifications allow that pending cycle to proceed after a short debounce. Overlapping wake events consume one pending cycle. An unlock or session activation without a sleep event cannot arm playback.

The app checks the current console session before playback. It supplements public workspace session notifications with loginwindow's distributed lock and unlock notifications and the session dictionary's lock flag. Those lock indicators are undocumented OS behavior, so physical unlock timing requires checking on the target macOS release. The app does not use a privileged helper or access the lock screen.

macOS does not provide a dependable public distinction between opening a lid, waking by keyboard, and other system wakes. Display sleep also arms a replay, including on external displays. The app makes no claim to detect a physical lid opening precisely. A screen saver or lock that does not sleep the display does not by itself trigger a replay.

Display changes reconcile desktop windows by display ID, preserving existing windows and playback position. Space changes retain those same windows and synchronize the native image without replaying. Those changes do not start a replay. The windows join all Spaces and stay beneath full-screen app content. One scene appears on all displays. The app does not edit WallpaperAgent's private preference store. Native sharing across inactive Spaces uses the system's Show on all Spaces setting. NSWorkspace changes can disable sharing when selecting a different image, so enable it again in Wallpaper settings if needed. Physical monitor hot-plug and animated Space transitions still need the manual checks in VERIFICATION.md.

Startup and resume restore the still. Stop persists the disabled replay state and removes all desktop windows. The selected native wallpaper remains. A later wake cannot re-enable stopped replays.

## Local files

The default library is `~/Library/Application Support/Wake Scenes/`. It contains an atomic `library.json` manifest and a directory per video's SHA-256 hash. Each scene directory holds an owned video copy and `still.png`. There are no uploads or bundled videos. Native wallpaper copies are retained in System Wallpapers, independently of removable scene folders. Previous Wallpaper and previous-wallpaper.json preserve the original desktop image and display options. A damaged manifest produces an error and prevents overwriting the existing library.

For development, pass `--library /absolute/path` to use another library and `--show-library` to open the window on launch. Keep each running test process in a separate library. Normal Launch Services launches use one app instance.

Launch at login uses Apple's SMAppService. macOS owns its registration and approval status; the app displays that status rather than storing a separate toggle preference. Signing, install location, or OS policy can reject registration, in which case the app reports the error.

## Inspiration and footage

The intro-to-still experience was inspired by [yamz8/omarchy-flight-15-theme](https://github.com/yamz8/omarchy-flight-15-theme). That project distinguishes its own MIT-licensed files from SpaceX footage in its [NOTICE.md](https://github.com/yamz8/omarchy-flight-15-theme/blob/main/NOTICE.md). No reference footage is bundled with the app. Locally imported Flight 15 packs retain their upstream notices. Automated verification uses original synthetic clips generated locally by ffmpeg.
