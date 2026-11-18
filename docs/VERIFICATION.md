# Verification results

Verified on November 18, 2026, on an Apple silicon Mac running macOS 27.2.1 with Swift 6.4.2 and Apple's command-line SDKs. Full Xcode was not installed.

The final run of `./scripts/verify.sh` passed 36 checks for each of two fixtures. The H.264 MP4 has four seconds of picture and eight seconds of audio. The portrait HEVC MOV has four seconds of picture. Both settle near the four-second video endpoint.

The retained machine-readable reports are checked in:

- [H.264 report](verification/h264.json)
- [HEVC report](verification/hevc.json)

Run the verification script to regenerate reports and runtime logs in the ignored local artifacts directory.

The checks use the running native app, its import code, AVPlayer, and actual desktop windows. They confirm advancing playback, decoded frames ready for display, muted audio, and retained still layers after the player and item are released. They also cover corrupt imports, content deduplication, persisted selection and stop state, screen-window rebuilds, wallpaper window levels, native system-wallpaper installation, persistence after closing all overlay windows, explicit restoration, retained window identities, and Retina backing scales.

Sleep and wake integration checks post NSWorkspace notifications inside the app process. Lock and unlock checks drive both the state machine and the monitor's actual receive path. They use explicit timestamps and session availability. No global loginwindow notifications are broadcast to other apps. Those checks establish the app's event handling, not the OS's physical event delivery.

Additional native UI checks confirmed import through NSOpenPanel, scene selection, Replay returning to the still state, a rendered wallpaper window, and selected-scene restoration after a process relaunch. SMAppService registration toggled on and off through the library without an error. The setting was left off. Command-Q exited the app after adding its native application menu.

The native wallpaper update additionally installed the selected Top Down Exhaust poster at 4096×2304. All 12 local Flight 15 scenes received their original high-resolution stills. System Settings showed Show on all Spaces enabled. A read-only inspection of WallpaperAgent's store found the selected image in the shared entry and zero individual Space overrides. Quitting the actual app left that native wallpaper installed with no WakeScenes process running. Live Space-navigation automation was unavailable, so no visual transition test is claimed.

The app's local code signature passed `codesign --verify --deep --strict`. No sample footage or codec library ships inside the generated Apple silicon bundle.

## Scene picker update

The X reference at https://x.com/yamzeight/status/2122812842311053688/video/1 was downloaded for local comparison. The app now has a horizontal thumbnail carousel with an orange selection border. Arrow keys change the highlighted scene, Return plays it, and Escape cancels. Thumbnail clicks play immediately. Command-Shift-S reopens the picker while Wake Scenes is active.

Native UI verification confirmed arrow navigation, Escape without applying the highlighted scene, shortcut reopening, Return selection, and thumbnail selection. Both selection paths close the picker. The 4K Wide Reflection Water intro was observed on the desktop, and its selection persisted. The synthetic codec runs also check that switching scenes preserves the old still during loading and installs the new still after playback. The File menu shortcut was verified through the native UI. The running-app checks also confirm that errors bring the library forward to report them.

## Unlock replay update

The focused lifecycle regression failed before the change at “lock and successful unlock replay without any sleep.” All 13 checks in `./scripts/test-lifecycle.sh` now pass. They cover lock-only unlock, unsuccessful authentication retaining the locked state, debounce, duplicate signals, missed wake signals, session reactivation, canceled cycles, and successive real cycles.

The full H.264 and HEVC runs also lock the monitor during real playback, observe decoder release to a still, inject a successful unlock, and verify that AVPlayer starts exactly one intro. These are synthetic event tests. A physical password or Touch ID unlock has not been performed by the agent.

## GitHub repository importer

`./scripts/test-repository.sh` passed 30 offline checks covering URL validation, recursive scene discovery, Omarchy intro pairing, folder and file scopes, source links, legacy library decoding, HTTP rate-limit messages, incomplete trees and downloads, Git LFS resolution and checksums, cleanup after failure, and cancellation.

`./scripts/verify-repository.sh` passed 18 checks in the running native app using public GitHub repositories. It found Flight 15's twelve intro/still pairs, imported its Caught at the Tower scene and a Lumon scene from Omarchy's main repository, and reported a real image-only theme without inventing a video. The imported Flight 15 movie matched its pinned Git blob byte for byte. Its paired poster remained at its original pixel dimensions, and a video first imported locally could gain its matching repository poster. Repository notices, provenance, deduplication, partial failure, cancellation, selected-scene persistence, real muted playback, and the handoff to a still with decoder release passed. The test used isolated storage and disabled the native wallpaper-install callback during playback.

The retained [repository report](verification/repository.json) records the source commits. Git LFS failure paths use controlled offline responses; a live Git LFS repository has not been tested.

Native UI verification pasted the Lumon folder link into **From GitHub…**, found both videos with their matching stills, and used **Import & use**. The sheet closed, the scene appeared on the desktop, and the library reported the settled still state. The new scene remained in the library. The previously selected Flight 15 scene was restored afterward, and **Show on all Spaces** was re-enabled. The H.264 and HEVC app verification runs also passed all 36 checks each after the importer was added.

## Complete the physical checks

These checks remain unperformed. Use a short clip with visible motion and a recognizable ending.

1. Select the clip, then close the lid until the Mac sleeps. Open the lid and unlock. Confirm that the intro begins after unlock, plays once, and holds its ending. Leave the desktop idle for a minute and confirm that it does not replay.
2. Lock the Mac and let its display sleep. Wake it but wait at the lock screen longer than the clip. Unlock and confirm that the full intro is still shown once. Lock and unlock without display sleep and confirm that the intro also replays exactly once. Try an incorrect password first and confirm that no intro runs until authentication succeeds.
3. Switch between Spaces and a full-screen app. Return to the desktop and confirm that the still remains beneath icons. Click a desktop icon to confirm that the wallpaper does not intercept input.
4. Connect and disconnect an external display while settled, then during Replay. Confirm that each display is filled, playback does not restart, and no black window remains after disconnect.
5. Stop wake replays, repeat sleep and wake, then quit and relaunch. Confirm that the selected system still remains visible. Use Restore Previous Wallpaper and confirm that the saved previous image returns. Check Show on all Spaces after selecting a different scene or restoring.
6. Copy the app to Applications and enable Launch at login. Log out and back in. Confirm that the menu-bar app starts with the selected still. Disable the setting afterward if you do not want it enabled.

Physical lid, lock-screen timing, monitor hot-plug, multiple Spaces, and an actual login launch are not claimed as tested.
