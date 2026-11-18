import AppKit
import AVFoundation
import CryptoKit

@MainActor
func runRepositoryVerification(model: AppModel) async {
    setbuf(stdout, nil)
    var checks: [String] = []
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw ImportFailure(message: "FAILED: \(name)") }
        checks.append(name); print("PASS: \(name)")
    }
    func wait(_ seconds: Double, until predicate: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        return predicate()
    }
    do {
        // Playback uses real desktop surfaces, but this test does not install a new native image.
        model.engine.onStillReady = nil
        let client = RepositoryClient()
        let flight = try await client.scan("https://github.com/yamz8/omarchy-flight-15-theme")
        try require(flight.videos.count >= 12 && flight.videos.allSatisfy { $0.poster != nil }, "Flight 15 repository discovers all twelve intro/still pairs")
        try require(flight.notices.contains { $0.path == "NOTICE.md" }, "upstream footage notice is discovered")
        let omarchy = try await client.scan("https://github.com/omacom/omarchy/tree/quattro/themes/lumon")
        try require(omarchy.videos.count == 2 && omarchy.videos.allSatisfy { $0.file.path.hasPrefix("themes/lumon/") && $0.poster != nil }, "a second real repository resolves a branch/folder link and pairs its videos")
        let staticPack = try await client.scan("https://github.com/MatthiasStaber/omarchy-retro-stripes-theme")
        try require(staticPack.videos.isEmpty && staticPack.imageCount > 0, "a real image-only theme reports still images without pretending it has video")
        guard let candidate = flight.videos.last else { throw ImportFailure(message: "Flight 15 has no video") }
        let imported = await model.importRepository(flight, paths: [candidate.id], client: client) { print($0) }
        try require(imported.scenes.count == 1 && imported.failures.isEmpty && !imported.cancelled && !model.busy, "real repository media downloads and imports through the app model")
        guard let scene = imported.scenes.first else { throw ImportFailure(message: "No imported scene") }
        try require(scene.source?.commit == flight.commit && scene.source?.videoPath == candidate.file.path, "scene preserves its pinned repository provenance")
        let handle = try FileHandle(forReadingFrom: model.disk.movie(scene))
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(scene.bytes)\0".utf8))
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        try handle.close()
        try require(hash.finalize().map { String(format: "%02x", $0) }.joined() == candidate.file.sha,
                    "imported video bytes match the pinned Git blob without transcoding")
        let poster = model.disk.still(scene)
        let source = CGImageSourceCreateWithURL(poster as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        try require(poster.lastPathComponent == "wallpaper.png" && image.width >= 3840, "matching original poster is retained at source resolution")
        let localDisk = LibraryDisk(root: model.disk.root.appendingPathComponent("local-first"))
        _ = try localDisk.read()
        let localMovie = model.disk.movie(scene)
        let origin = scene.source
        let upgraded = try await Task.detached {
            let existing = try await localDisk.ingest(localMovie)
            guard localDisk.still(existing).lastPathComponent == "still.png" else { throw ImportFailure(message: "Unexpected existing poster") }
            return try await localDisk.ingest(localMovie, poster: poster, origin: origin)
        }.value
        try require(localDisk.still(upgraded).lastPathComponent == "wallpaper.png" &&
                    (try Data(contentsOf: localDisk.still(upgraded))) == Data(contentsOf: poster),
                    "a video imported locally can gain its matching repository poster without a duplicate")
        let archive = model.disk.root.appendingPathComponent("Source Packs/GitHub/yamz8/omarchy-flight-15-theme/\(flight.commit)")
        let notice = try String(contentsOf: archive.appendingPathComponent("Repository/NOTICE.md"), encoding: .utf8)
        try require(notice.contains("SpaceX") && FileManager.default.fileExists(atPath: archive.appendingPathComponent("Repository/LICENSE").path), "media notice and license are saved locally")
        let second = await model.importRepository(omarchy, paths: [omarchy.videos[0].id], client: client) { print($0) }
        try require(second.scenes.count == 1 && second.failures.isEmpty && model.state.scenes.count == 2, "another Omarchy theme imports into the same library")
        let duplicate = await model.importRepository(flight, paths: [candidate.id], client: client) { _ in }
        try require(duplicate.scenes.count == 1 && model.state.scenes.count == 2, "reimporting repository media deduplicates without losing provenance")
        guard let readme = omarchy.notices.first(where: { $0.path.uppercased() == "README.MD" }) else { throw ImportFailure(message: "Missing README fixture") }
        let mixed = RepositoryPack(address: omarchy.address, commit: omarchy.commit,
                                   videos: [omarchy.videos[0], RepositoryVideo(file: readme, poster: nil)], notices: [], imageCount: 0)
        let partial = await model.importRepository(mixed, paths: Set(mixed.videos.map(\.id)), client: client) { _ in }
        try require(partial.scenes.count == 1 && partial.failures.count == 1 && model.state.scenes.count == 2,
                    "one undecodable file reports a failure while retaining other completed imports")
        let cancelled = Task { await model.importRepository(flight, paths: [candidate.id], client: client) { _ in } }
        cancelled.cancel()
        let stopped = await cancelled.value
        try require(stopped.cancelled && !model.busy && model.state.scenes.count == 2, "cancelling leaves completed imports intact and releases the busy state")
        let selection = second.scenes[0]
        model.choose(selection)
        let playing = await wait(10) { (model.engine.player?.rate ?? 0) > 0 && model.engine.surfaces.allSatisfy { $0.video.isReadyForDisplay } }
        try require(playing && model.engine.player?.isMuted == true, "repository scene starts real muted video on the desktop")
        let settled = await wait(selection.duration + 10) { model.engine.decoderReleased }
        try require(settled && model.engine.surfaces.allSatisfy { $0.image.contents != nil && $0.video.opacity == 0 }, "repository video settles to its paired still and releases decoding")
        let persisted = try model.disk.read()
        try require(persisted.selectedID == selection.id && persisted.scenes.allSatisfy { $0.source != nil }, "repository library, chosen scene, and source links persist")
        let restored = AppModel(root: model.disk.root)
        try require(restored.selected == selection, "a fresh app model restores the repository selection")
        restored.shutdown()
        let report: [String: Any] = ["passed": checks, "count": checks.count, "flightCommit": flight.commit,
                                     "omarchyCommit": omarchy.commit, "physicalLidTested": false, "physicalLockTested": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: model.disk.root.appendingPathComponent("repository-verification.json"))
        print("REPOSITORY VERIFICATION COMPLETE: \(checks.count) checks")
        model.shutdown(); NSApp.terminate(nil)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        try? Data(error.localizedDescription.utf8).write(to: model.disk.root.appendingPathComponent("FAILED.txt"))
        model.shutdown(); exit(1)
    }
}
