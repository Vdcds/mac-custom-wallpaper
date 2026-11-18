import AppKit
import AVFoundation

@MainActor
func runVerification(model: AppModel, arguments: [String]) async {
    var checks: [String] = []
    func require(_ condition: Bool, _ text: String) throws {
        guard condition else { throw ImportFailure(message: "FAILED: \(text)") }
        checks.append(text)
        print("PASS: \(text)")
    }
    func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    func wait(_ seconds: Double, until predicate: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < end { await pause(0.1) }
        return predicate()
    }
    let root = model.disk.root
    do {
        guard let fixtureIndex = arguments.firstIndex(of: "--fixture"), arguments.count > fixtureIndex + 1 else {
            throw ImportFailure(message: "--self-test requires --fixture and --library with an isolated directory")
        }
        let fixture = URL(fileURLWithPath: arguments[fixtureIndex + 1])
        let originals = NSScreen.screens.map { NSWorkspace.shared.desktopImageURL(for: $0) }
        model.importFiles([fixture])
        let imported = await wait(20) { !model.busy }
        try require(imported && model.error == nil && model.state.scenes.count == 1, "real app import creates one local scene")
        guard let scene = model.selected else { throw ImportFailure(message: "No selected scene") }
        try require(FileManager.default.fileExists(atPath: model.disk.movie(scene).path), "owned video copy exists")
        try require(scene.stillTime > 0 && scene.stillTime < scene.duration, "final usable frame has a real timestamp")
        if let index = arguments.firstIndex(of: "--expected-duration"), arguments.count > index + 1,
           let expected = Double(arguments[index + 1]) {
            try require(abs(scene.duration - expected) < 0.1 && scene.stillTime > expected - 0.1,
                        "still and playback end at the last video frame, independent of audio length")
        }
        let persisted = try model.disk.read()
        try require(persisted.selectedID == scene.id && persisted.scenes == model.state.scenes, "manifest preserves library and selection")
        model.importFiles([fixture])
        _ = await wait(20) { !model.busy }
        try require(model.state.scenes.count == 1, "duplicate import is deduplicated by content")
        let bad = root.appendingPathComponent("broken.mp4")
        try Data("this is not a video".utf8).write(to: bad)
        model.importFiles([bad])
        _ = await wait(10) { !model.busy }
        try require(model.error?.contains("QuickTime") == true && model.state.scenes.count == 1, "corrupt import reports conversion guidance without adding a scene")
        try require(NSApp.windows.contains { $0.title == "Wake Scenes · Verification" && $0.isVisible },
                    "an import or playback error brings the library forward to report it")
        model.error = nil
        // Model reconstruction exercises the same loading path as a new launch.
        let restored = AppModel(root: root)
        try require(restored.selected == scene && restored.state.enabled, "fresh model restores selection and enabled preference")
        restored.shutdown()
        model.replay()
        let playing = await wait(10) { model.engine.player?.rate ?? 0 > 0 }
        await pause(0.7)
        try require(playing && (model.engine.player?.currentTime().seconds ?? 0) > 0.2, "AVPlayer really advances through the intro")
        try require(model.engine.player?.isMuted == true, "playback is muted")
        try require(model.engine.surfaces.allSatisfy { $0.video.isReadyForDisplay && $0.video.opacity == 1 }, "video layers display decoded frames on every screen")
        try require(model.engine.surfaces.allSatisfy {
            $0.window.level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)) &&
            $0.window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)) && $0.window.ignoresMouseEvents
        }, "wallpaper windows sit below icons and pass through clicks")
        let settled = await wait(scene.duration + 10) { model.engine.decoderReleased }
        try require(settled && model.engine.phase.hasPrefix("Still"), "intro ends on still and releases player, item, and layers")
        try require(model.engine.surfaces.allSatisfy { $0.image.contents != nil && $0.video.opacity == 0 }, "cached still remains visible after decoder release")
        let windowsBefore = model.engine.surfaces.map { $0.window.windowNumber }
        model.engine.rebuildScreens()
        try require(model.engine.surfaces.map { $0.window.windowNumber } == windowsBefore,
                    "display reconciliation reuses windows instead of exposing another wallpaper")
        try require(model.engine.surfaces.allSatisfy { surface in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == surface.displayID }?.backingScaleFactor == surface.image.contentsScale
        }, "still layers render at each display's native Retina scale")
        try require(model.engine.decoderReleased && model.engine.surfaces.count == NSScreen.screens.count, "screen rebuild retains still without starting playback")

        if let index = arguments.firstIndex(of: "--second-fixture"), arguments.count > index + 1 {
            let secondURL = URL(fileURLWithPath: arguments[index + 1])
            let disk = model.disk
            let second = try await Task.detached { try await disk.ingest(secondURL) }.value
            guard let oldContents = model.engine.surfaces.first?.image.contents else {
                throw ImportFailure(message: "No previous wallpaper to compare")
            }
            let oldImage = oldContents as! CGImage
            try model.engine.play(second, disk: disk)
            guard let loadingContents = model.engine.surfaces.first?.image.contents else {
                throw ImportFailure(message: "Previous wallpaper disappeared while loading")
            }
            let loadingImage = loadingContents as! CGImage
            try require(oldImage.width == loadingImage.width && oldImage.height == loadingImage.height,
                        "switching scenes keeps the previous still visible while the intro loads")
            _ = await wait(second.duration + 10) { model.engine.decoderReleased }
            let source = CGImageSourceCreateWithURL(disk.still(second) as CFURL, nil)!
            let expected = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            guard let finalContents = model.engine.surfaces.first?.image.contents else {
                throw ImportFailure(message: "No final still after switching scenes")
            }
            let finalImage = finalContents as! CGImage
            try require(model.engine.decoderReleased && finalImage.width == expected.width && finalImage.height == expected.height,
                        "switching scenes installs the new ending only after playback and releases its player")
            model.start()
        }

        // Exercise the same lock/unlock receive path without locking the Mac
        // or sending global loginwindow notifications to unrelated applications.
        model.replay()
        _ = await wait(10) { model.engine.player?.rate ?? 0 > 0 }
        let beforeLock = model.replayCount
        model.wake.receive(.lock, name: "verification lock")
        await pause(1.1)
        try require(model.engine.decoderReleased && model.replayCount == beforeLock,
                    "locking during playback settles to a still and waits for authentication")
        model.wake.receive(.unlock, name: "verification unlock")
        let unlocked = await wait(3) { model.replayCount == beforeLock + 1 && (model.engine.player?.rate ?? 0) > 0 }
        try require(unlocked, "a lock-only successful unlock starts real muted video playback")
        model.wake.receive(.unlock, name: "verification duplicate unlock")
        model.wake.receive(.active, name: "verification session active")
        model.wake.receive(.screenWake, name: "verification duplicate screen wake")
        await pause(1.6)
        try require(model.replayCount == beforeLock + 1, "overlapping unlock and wake signals do not replay a second time")
        model.engine.settle()

        // Drive the actual subscribed notification path without sleeping the user's machine.
        let baseline = model.replayCount
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didWakeNotification] { center.post(name: name, object: nil) }
        await pause(2.2)
        try require(model.replayCount == baseline + 1, "overlapping injected wake notifications cause exactly one replay")
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        await pause(1.8)
        try require(model.replayCount == baseline + 1, "duplicate wake and ordinary session activation do not replay")
        model.setEnabled(false)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] { center.post(name: name, object: nil) }
        await pause(1.8)
        try require(!model.state.enabled && model.engine.surfaces.isEmpty && model.replayCount == baseline + 1, "stop survives wake and keeps the selected system wallpaper")
        let stopped = try model.disk.read()
        try require(!stopped.enabled, "stopped preference persists on disk")
        model.setEnabled(true)
        try require(model.engine.decoderReleased, "resume restores still without an unsolicited intro")

        var gate = WakeGate()
        let now = Date()
        gate.accept(.sleep, now: now); gate.accept(.lock, now: now)
        gate.accept(.wake, now: now)
        try require(!gate.consume(now: now.addingTimeInterval(10), sessionAvailable: false), "locked wake remains pending")
        try require(!gate.consume(now: now.addingTimeInterval(10), sessionAvailable: true), "lock notification defers playback until an explicit unlock event")
        gate.accept(.unlock, now: now.addingTimeInterval(10))
        try require(!gate.consume(now: now.addingTimeInterval(10.2), sessionAvailable: true), "unlock waits for presentation debounce")
        try require(gate.consume(now: now.addingTimeInterval(11), sessionAvailable: true), "unlock consumes deferred cycle once")
        gate.accept(.unlock, now: now.addingTimeInterval(12))
        try require(!gate.consume(now: now.addingTimeInterval(20), sessionAvailable: true), "unlock alone never replays")
        let nativeURL = model.systemWallpaper.installedURL
        let nativeInstalled = await wait(4) {
            nativeURL != nil && NSScreen.screens.allSatisfy { NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL == nativeURL?.standardizedFileURL }
        }
        if !nativeInstalled {
            print("NATIVE EXPECTED: \(nativeURL?.absoluteString ?? "nil")")
            print("NATIVE ACTUAL: \(NSScreen.screens.map { NSWorkspace.shared.desktopImageURL(for: $0)?.absoluteString ?? "nil" })")
            print("NATIVE ERROR: \(model.error ?? "none")")
        }
        try require(nativeInstalled, "selected still is installed as the actual native system wallpaper")
        model.engine.stop()
        try require(NSScreen.screens.allSatisfy { NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL == nativeURL?.standardizedFileURL },
                    "native wallpaper persists after all overlay windows are closed")
        try model.systemWallpaper.restore()
        let originalRestored = await wait(4) { NSScreen.screens.map { NSWorkspace.shared.desktopImageURL(for: $0) } == originals }
        try require(originalRestored, "explicit restore brings back the saved previous wallpaper")
        let report: [String: Any] = ["passed": checks, "count": checks.count, "screens": NSScreen.screens.count,
                                    "duration": scene.duration, "stillTime": scene.stillTime,
                                    "physicalLidTested": false, "physicalLockTested": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("verification.json"))
        print("VERIFICATION COMPLETE: \(checks.count) checks")
        model.shutdown()
        NSApp.terminate(nil)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        try? Data(error.localizedDescription.utf8).write(to: root.appendingPathComponent("FAILED.txt"))
        model.shutdown()
        try? model.systemWallpaper.restore()
        exit(1)
    }
}
