import Foundation
import CryptoKit

private final class RepositoryStub: URLProtocol {
    static var handler: (URLRequest) throws -> (Int, [String: String], Data) = { _ in (404, [:], Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct RepositoryTests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw ImportFailure(message: "FAILED: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let address = try RepositoryAddress(" https://github.com/owner/theme.git?tab=readme#wallpapers\n")
        try check(address.slug == "owner/theme" && address.suffix.isEmpty, "repository URLs normalize .git, whitespace, query, and fragment")
        try check(try RepositoryAddress("github.com/owner/theme").url == address.url, "pasted GitHub URLs may omit https")
        for bad in ["https://example.com/owner/theme", "https://github.com.evil.test/o/r", "file:///tmp/repo", "https://token@github.com/o/r", "https://github.com/o/r/tree/main/../secret", "https://github.com/o/r/issues/1", "https://github.com/o/r/tree/main/%2Fetc", "https://github.com/o/r/tree/main/%00file", "https://github.com/o"] {
            try check((try? RepositoryAddress(bad)) == nil, "reject unsupported or unsafe URL: \(bad)")
        }
        let folder = try RepositoryAddress("https://github.com/o/r/tree/feature/new/backgrounds")
        try check(folder.suffix == ["feature", "new", "backgrounds"] && !folder.isFile, "branch/folder suffixes retain slash-separated refs")
        func file(_ path: String, mode: String = "100644") -> RepositoryFile {
            RepositoryFile(path: path, mode: mode, type: "blob", size: 100)
        }
        let files = [file("backgrounds/intros/1-Scene.MP4"), file("backgrounds/1-Scene.webp"),
                     file("clips/second.mov"), file("clips/second.png"), file("clips/second.jpg"),
                     file("demo/preview.webm"), file("README.md"), file("NOTICE.md"), file("LICENSE"),
                     file("colors.toml"), file("install.sh", mode: "100755"), file("unsafe/link.mp4", mode: "120000"),
                     file("../escape.mp4"), file("/absolute.mp4"), file("C:\\video.mp4"), file("clips/duplicate//file.mp4")]
        let pack = RepositoryPack.discover(address: address, commit: String(repeating: "a", count: 40), files: files)
        try check(pack.videos.count == 3, "discover videos recursively without accepting symlinks, scripts, or unsafe paths")
        try check(pack.videos.first { $0.name == "1-Scene" }?.poster?.path == "backgrounds/1-Scene.webp", "Omarchy intro pairs with its original matching background")
        try check(pack.videos.first { $0.name == "second" }?.poster?.path == "clips/second.png", "standalone videos pair locally with deterministic image preference")
        try check(pack.notices.map(\.path).sorted() == ["LICENSE", "NOTICE.md", "README.md"], "repository notices and readme are preserved")
        let scoped = RepositoryPack.discover(address: folder, commit: pack.commit, files: files, scope: "backgrounds/intros")
        try check(scoped.videos.count == 1 && scoped.videos[0].poster != nil, "folder imports can find paired stills outside the selected intro folder")
        let blob = try RepositoryAddress("https://github.com/o/r/blob/main/clips/second.mov")
        let single = RepositoryPack.discover(address: blob, commit: pack.commit, files: files, scope: "clips/second.mov")
        try check(single.videos.count == 1 && single.videos[0].name == "second", "file links select only that video")
        let images = RepositoryPack.discover(address: address, commit: pack.commit, files: [file("backgrounds/static.jpg")])
        try check(images.videos.isEmpty && images.imageCount == 1, "image-only themes are reported without inventing animation")
        let path = "backgrounds/space & colour #1.mp4"
        let raw = RepositoryAddress.fileURL(repository: address.url, commit: pack.commit, path: path)
        try check(raw.absoluteString.hasSuffix("backgrounds/space%20%26%20colour%20%231.mp4"), "raw file URLs preserve reserved characters as path data")
        let lfs = RepositoryAddress.fileURL(repository: address.url, commit: pack.commit, path: path, host: "media.githubusercontent.com")
        try check(lfs.absoluteString.hasPrefix("https://media.githubusercontent.com/media/owner/theme/"), "Git LFS media uses the correct endpoint")
        let source = SceneSource(repository: address.url, commit: pack.commit, videoPath: path, posterPath: nil)
        try check(source.videoURL.absoluteString.contains("/owner/theme/blob/" + pack.commit), "source attribution links to the pinned file")
        // Existing libraries must remain readable without the new optional provenance.
        let legacy = Data("{\"scenes\":[{\"id\":\"a\",\"name\":\"old\",\"movieName\":\"video.mp4\",\"duration\":4,\"stillTime\":3.9,\"bytes\":100}],\"selectedID\":\"a\",\"enabled\":true}".utf8)
        try check(try JSONDecoder().decode(LibraryState.self, from: legacy).scenes[0].source == nil, "existing libraries decode without source metadata")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RepositoryStub.self]
        let client = RepositoryClient(session: URLSession(configuration: config))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Wake-Scenes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func expectFailure(_ name: String, containing text: String, operation: () async throws -> Void) async throws {
            var failure: Error?
            do { try await operation() } catch { failure = error }
            try check(failure?.localizedDescription.contains(text) == true, "\(name) (\(failure?.localizedDescription ?? "no failure"))")
        }
        RepositoryStub.handler = { _ in (403, ["X-RateLimit-Reset": "1800000000"], Data()) }
        try await expectFailure("rate limits give a retry time", containing: "Try again after") { _ = try await client.scan(address.url.absoluteString) }
        RepositoryStub.handler = { request in
            let path = request.url!.path
            if path == "/repos/owner/theme" { return (200, [:], Data("{\"default_branch\":\"main\"}".utf8)) }
            if path.contains("/commits/") { return (200, [:], Data("{\"sha\":\"\(pack.commit)\",\"commit\":{\"tree\":{\"sha\":\"tree\"}}}".utf8)) }
            return (200, [:], Data("{\"tree\":[],\"truncated\":true}".utf8))
        }
        try await expectFailure("truncated trees cannot silently omit wallpapers", containing: "too large") { _ = try await client.scan(address.url.absoluteString) }
        let content = Data("original-media-bytes".utf8)
        let oid = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize \(content.count)\n".utf8)
        let lfsFile = RepositoryFile(path: "backgrounds/lfs.mp4", mode: "100644", type: "blob", size: Int64(pointer.count))
        var mediaRequested = false
        RepositoryStub.handler = { request in
            if request.url!.host == "media.githubusercontent.com" {
                mediaRequested = request.url!.path.hasPrefix("/media/owner/theme/")
                return (200, [:], content)
            }
            return (200, [:], pointer)
        }
        let target = root.appendingPathComponent("media.mp4")
        try await client.fetch(lfsFile, from: pack, to: target, limit: 1024)
        try check(mediaRequested && (try Data(contentsOf: target)) == content, "Git LFS resolves and verifies original media bytes")
        try FileManager.default.removeItem(at: target)
        RepositoryStub.handler = { request in (200, [:], request.url!.host == "media.githubusercontent.com" ? Data("tampered".utf8) : pointer) }
        try await expectFailure("Git LFS checksum failures reject the media", containing: "checksum") { try await client.fetch(lfsFile, from: pack, to: target, limit: 1024) }
        try check(!FileManager.default.fileExists(atPath: target.path), "failed downloads leave no file that could be reused")
        RepositoryStub.handler = { _ in (200, [:], Data("short".utf8)) }
        try await expectFailure("incomplete raw downloads are rejected", containing: "incomplete") { try await client.fetch(lfsFile, from: pack, to: target, limit: 1024) }
        let cancelled = Task { try await client.fetch(lfsFile, from: pack, to: target, limit: 1024) }
        cancelled.cancel()
        var didCancel = false
        do { try await cancelled.value } catch is CancellationError { didCancel = true }
        try check(didCancel, "cancelled imports stop before downloading")
        print("REPOSITORY TESTS COMPLETE: \(count) checks")
    }
}
