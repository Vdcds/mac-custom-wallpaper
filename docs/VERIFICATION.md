# Verification results

Verified on November 18, 2026, on an Apple silicon Mac running macOS 27.2.1 with Swift 6.4.2 and Apple's command-line SDKs. Full Xcode was not installed.

The final run of `./scripts/verify.sh` passed 29 checks for each of two fixtures. The H.264 MP4 has four seconds of picture and eight seconds of audio. The portrait HEVC MOV has four seconds of picture. Both settle near the four-second video endpoint.

The retained machine-readable reports are checked in:

- [H.264 report](verification/h264.json)
- [HEVC report](verification/hevc.json)

Run the verification script to regenerate reports and runtime logs in the ignored local artifacts directory.

The checks use the running native app, its import code, AVPlayer, and actual desktop windows. They confirm advancing playback, decoded frames ready for display, muted audio, and retained still layers after the player and item are released. They also cover corrupt imports, content deduplication, persisted selection and stop state, screen-window rebuilds, wallpaper window levels, and unchanged system wallpaper URLs.

Sleep and wake integration checks post NSWorkspace notifications inside the app process. Lock and unlock checks drive the state machine with explicit timestamps and session availability. Those checks establish the app's event handling, not the OS's physical event delivery.

Additional native UI checks confirmed import through NSOpenPanel, scene selection, Replay returning to the still state, a rendered wallpaper window, and selected-scene restoration after a process relaunch. SMAppService registration toggled on and off through the library without an error. The setting was left off. Command-Q exited the app after adding its native application menu.

The app's local code signature passed `codesign --verify --deep --strict`. The generated Apple silicon bundle is about 5.5 MB. No sample footage or codec library ships inside it.

## Scene picker update

The X reference at https://x.com/yamzeight/status/2122812842311053688/video/1 was downloaded for local comparison. The app now has a horizontal thumbnail carousel with an orange selection border. Arrow keys change the highlighted scene, Return plays it, and Escape cancels. Thumbnail clicks play immediately. Command-Shift-S reopens the picker while Wake Scenes is active.

Native UI verification confirmed arrow navigation, Escape without applying the highlighted scene, shortcut reopening, Return selection, and thumbnail selection. Both selection paths close the picker. The 4K Wide Reflection Water intro was observed on the desktop, and its selection persisted. The synthetic codec runs also check that switching scenes preserves the old still during loading and installs the new still after playback. The File menu shortcut was verified through the native UI. The running-app checks also confirm that errors bring the library forward to report them.

## Complete the physical checks

These checks remain unperformed. Use a short clip with visible motion and a recognizable ending.

1. Select the clip, then close the lid until the Mac sleeps. Open the lid and unlock. Confirm that the intro begins after unlock, plays once, and holds its ending. Leave the desktop idle for a minute and confirm that it does not replay.
2. Lock the Mac and let its display sleep. Wake it but wait at the lock screen longer than the clip. Unlock and confirm that the full intro is still shown once. Lock and unlock without display sleep and confirm that it does not replay.
3. Switch between Spaces and a full-screen app. Return to the desktop and confirm that the still remains beneath icons. Click a desktop icon to confirm that the wallpaper does not intercept input.
4. Connect and disconnect an external display while settled, then during Replay. Confirm that each display is filled, playback does not restart, and no black window remains after disconnect.
5. Stop the wallpaper, repeat sleep and wake, then quit and relaunch. Confirm that the original wallpaper remains visible until you resume.
6. Copy the app to Applications and enable Launch at login. Log out and back in. Confirm that the menu-bar app starts with the selected still. Disable the setting afterward if you do not want it enabled.

Physical lid, lock-screen timing, monitor hot-plug, multiple Spaces, and an actual login launch are not claimed as tested.
