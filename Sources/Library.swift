import AppKit
import AVFoundation
import CryptoKit

struct Scene: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let movieName: String
    let duration: Double
    let stillTime: Double
    let bytes: Int64
}

struct LibraryState: Codable {
    var scenes: [Scene] = []
    var selectedID: String?
    var enabled = true
}

struct ImportFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// All file and decoder work happens away from the main actor. Imported files are
// owned copies; no security bookmark or dependency on the original is required.
struct LibraryDisk {
    let root: URL
    var manifest: URL { root.appendingPathComponent("library.json") }
    func folder(_ scene: Scene) -> URL { root.appendingPathComponent(scene.id) }
    func movie(_ scene: Scene) -> URL { folder(scene).appendingPathComponent(scene.movieName) }
    func still(_ scene: Scene) -> URL {
        let original = folder(scene).appendingPathComponent("wallpaper.png")
        return FileManager.default.fileExists(atPath: original.path) ? original : folder(scene).appendingPathComponent("still.png")
    }

    func read() throws -> LibraryState {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return LibraryState() }
        return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: manifest))
    }
    func write(_ state: LibraryState) throws {
        try JSONEncoder().encode(state).write(to: manifest, options: .atomic)
    }

    func ingest(_ source: URL) async throws -> Scene {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let movieName = "video.\(ext)"
        let local = staging.appendingPathComponent(movieName)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        do { try fm.copyItem(at: source, to: local) }
        catch { throw ImportFailure(message: "Couldn’t copy \(source.lastPathComponent). Check access and available disk space. \(error.localizedDescription)") }

        let asset = AVURLAsset(url: local)
        do {
            let playable = try await asset.load(.isPlayable)
            let assetDuration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard playable, let track = tracks.first else {
                throw ImportFailure(message: "This file has no playable video track.")
            }
            // Audio can outlast the picture. Settle at the end of the video track.
            let range = try await track.load(.timeRange)
            let duration = min(assetDuration, CMTimeRangeGetEnd(range).seconds)
            guard duration.isFinite, duration > 0 else {
                throw ImportFailure(message: "This file has no playable, finite video track.")
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = .zero
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // Ask immediately before the end. The actual timestamp returned is
            // retained as the stopping point, including variable-frame-rate media.
            var frame: CGImage?
            var actual = CMTime.zero
            for offset in [1.0 / 600, 0.05, 0.25, 1.0] {
                let time = CMTime(seconds: max(0, duration - offset), preferredTimescale: 60000)
                if let result = try? await generator.image(at: time) {
                    frame = result.image
                    actual = result.actualTime
                    break
                }
            }
            guard let frame else { throw ImportFailure(message: "macOS couldn’t decode a usable final frame.") }
            let bitmap = NSBitmapImageRep(cgImage: frame)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ImportFailure(message: "Couldn’t save the final frame.")
            }
            try png.write(to: staging.appendingPathComponent("still.png"))
            let handle = try FileHandle(forReadingFrom: local)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            let id = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let bytes = (try fm.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
            let scene = Scene(id: id, name: source.deletingPathExtension().lastPathComponent,
                              movieName: movieName, duration: duration,
                              stillTime: max(0, actual.seconds), bytes: bytes)
            let destination = folder(scene)
            if !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: staging, to: destination) }
            return scene
        } catch {
            throw ImportFailure(message: "\(source.lastPathComponent): \(error.localizedDescription)\nTry exporting as H.264 or HEVC in a .mov/.mp4 file using QuickTime Player → File → Export As. Renaming the extension won’t convert a codec.")
        }
    }
}
