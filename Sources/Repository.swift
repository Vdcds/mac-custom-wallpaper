import Foundation
import CryptoKit

struct SceneSource: Codable, Equatable {
    let repository: URL
    let commit: String
    let videoPath: String
    let posterPath: String?
    var videoURL: URL { RepositoryAddress.fileURL(repository: repository, commit: commit, path: videoPath, host: "github.com", prefix: "blob") }
}

struct RepositoryAddress: Equatable {
    let owner: String
    let name: String
    let suffix: [String]
    let isFile: Bool
    var slug: String { "\(owner)/\(name)" }
    var url: URL { URL(string: "https://github.com/\(slug)")! }

    init(_ text: String) throws {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("github.com/") { text = "https://" + text }
        guard let parts = URLComponents(string: text), parts.scheme == "https",
              parts.host?.lowercased() == "github.com", parts.user == nil, parts.password == nil,
              parts.port == nil else {
            throw ImportFailure(message: "Paste a public GitHub repository link, such as https://github.com/owner/theme. Other hosts and private repositories aren’t supported yet.")
        }
        let path = parts.percentEncodedPath.split(separator: "/").compactMap { String($0).removingPercentEncoding }
        guard path.count >= 2 else { throw ImportFailure(message: "The link needs both a GitHub owner and repository name.") }
        let repo = path[1].hasSuffix(".git") ? String(path[1].dropLast(4)) : path[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [path[0], repo].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }),
              path.allSatisfy({ !$0.contains("\\") && !$0.contains("/") && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw ImportFailure(message: "This repository link contains an invalid path.")
        }
        guard path.count == 2 || (path.count >= 4 && ["tree", "blob"].contains(path[2])) else {
            throw ImportFailure(message: "Use the repository’s main link, a branch/folder link, or a video’s file link.")
        }
        owner = path[0]; name = repo
        suffix = path.count > 2 ? Array(path.dropFirst(3)) : []
        isFile = path.count > 2 && path[2] == "blob"
    }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func encoded(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }
    static func fileURL(repository: URL, commit: String, path: String, host: String = "raw.githubusercontent.com", prefix: String? = nil) -> URL {
        let slug = repository.path.split(separator: "/").map(String.init)
        let base = host == "media.githubusercontent.com" ? ["media"] + slug : slug + (prefix.map { [$0] } ?? [])
        let components = base + [commit] + path.split(separator: "/").map(String.init)
        return URL(string: "https://\(host)/" + components.map(encoded).joined(separator: "/"))!
    }
}

struct RepositoryFile: Decodable, Equatable {
    let path: String
    let mode: String
    let type: String
    let size: Int64?
    var sha: String? = nil
    var regular: Bool { type == "blob" && ["100644", "100755"].contains(mode) && RepositoryAddress.safePath(path) }
}

struct RepositoryVideo: Identifiable, Equatable {
    let file: RepositoryFile
    let poster: RepositoryFile?
    var id: String { file.path }
    var name: String { URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent }
}

struct RepositoryPack {
    let address: RepositoryAddress
    let commit: String
    let videos: [RepositoryVideo]
    let notices: [RepositoryFile]
    let imageCount: Int

    static func discover(address: RepositoryAddress, commit: String, files: [RepositoryFile], scope: String = "") -> RepositoryPack {
        let regular = files.filter(\.regular)
        let imageExtensions: Set<String> = ["png", "webp", "jpg", "jpeg", "heic", "tif", "tiff"]
        let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "mpg", "mpeg", "mts", "m2ts", "ts", "wmv", "flv", "ogv", "3gp"]
        let scoped = regular.filter { scope.isEmpty || (address.isFile ? $0.path == scope : $0.path.hasPrefix(scope + "/")) }
        let byPath = Dictionary(regular.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let videos = scoped.filter { videoExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }.map { file in
            let url = URL(fileURLWithPath: file.path)
            // Use relative string paths, not file URL normalization, to preserve exact Git paths.
            let parts = file.path.split(separator: "/").map(String.init)
            let parent = parts.dropLast().joined(separator: "/")
            let stem = url.deletingPathExtension().lastPathComponent
            let posterParent = parts.dropLast().last == "intros" ? parts.dropLast(2).joined(separator: "/") : parent
            let base = posterParent.isEmpty ? stem : posterParent + "/" + stem
            let poster = ["png", "webp", "jpg", "jpeg", "heic", "tif", "tiff"].compactMap { byPath[(base + "." + $0).lowercased()] }.first
            return RepositoryVideo(file: file, poster: poster)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let notices = regular.filter {
            let name = URL(fileURLWithPath: $0.path).lastPathComponent.uppercased()
            let isNotice = ["LICENSE", "LICENCE", "NOTICE", "COPYING", "COPYRIGHT"].contains { name == $0 || name.hasPrefix($0 + ".") || name.hasPrefix($0 + "-") }
            return (isNotice || (!$0.path.contains("/") && name.hasPrefix("README"))) && ($0.size ?? 0) <= 1_048_576
        }
        return RepositoryPack(address: address, commit: commit, videos: videos, notices: notices,
                              imageCount: scoped.filter { imageExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }.count)
    }
}

private struct RepositoryHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

private final class RepositoryDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let limit: Int64
    let progress: (Int64) -> Void
    private var observation: NSKeyValueObservation?
    private let lock = NSLock()
    private var exceeded = false
    private var lastReport = Date.distantPast
    var limitExceeded: Bool { lock.withLock { exceeded } }
    init(limit: Int64, progress: @escaping (Int64) -> Void) { self.limit = limit; self.progress = progress }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        // Async download APIs own their download callbacks. Observe the task's byte progress.
        observation = task.progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak task] _, _ in
            guard let self, let task else { return }
            let bytes = task.countOfBytesReceived
            let tooLarge = bytes > self.limit || task.countOfBytesExpectedToReceive > self.limit
            let report = self.lock.withLock {
                self.exceeded = self.exceeded || tooLarge
                guard Date().timeIntervalSince(self.lastReport) > 0.15 else { return false }
                self.lastReport = Date(); return true
            }
            if tooLarge { task.cancel() }
            if report { self.progress(bytes) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        let allowed = host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com")
        completionHandler(request.url?.scheme == "https" && allowed ? request : nil)
    }
}

struct RepositoryClient {
    static let videoLimit: Int64 = 2 * 1024 * 1024 * 1024
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 1800
        config.httpAdditionalHeaders = ["User-Agent": "Wake-Scenes", "Accept": "application/vnd.github+json"]
        self.session = URLSession(configuration: config)
    }

    private func download(_ url: URL, to destination: URL, limit: Int64, progress: @escaping (Int64) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let delegate = RepositoryDownloadDelegate(limit: limit, progress: progress)
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await session.download(from: url, delegate: delegate) }
        catch {
            if delegate.limitExceeded { throw ImportFailure(message: "This download exceeds the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) limit.") }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse else { throw ImportFailure(message: "GitHub returned an invalid response.") }
        guard response.statusCode == 200 else {
            let message: String
            switch response.statusCode {
            case 404: message = "Repository, branch, or file not found. Check the link; this importer supports public GitHub repositories."
            case 403, 429:
                if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let time = Double(reset) {
                    message = "GitHub’s request limit was reached. Try again after \(Date(timeIntervalSince1970: time).formatted(date: .omitted, time: .shortened))."
                } else { message = "GitHub temporarily refused the request (\(response.statusCode)). Try again later." }
            default: message = "GitHub returned HTTP \(response.statusCode). Try again later."
            }
            throw RepositoryHTTPError(status: response.statusCode, message: message)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= limit else { throw ImportFailure(message: "This download exceeds the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) limit.") }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    private func api<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try await download(URL(string: "https://api.github.com/repos/" + path)!, to: file, limit: 10 * 1024 * 1024)
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: file)) }
        catch { throw ImportFailure(message: "GitHub returned unreadable repository metadata. Try again later.") }
    }

    func scan(_ text: String) async throws -> RepositoryPack {
        let address = try RepositoryAddress(text)
        struct Info: Decodable { let default_branch: String }
        struct Commit: Decodable { let sha: String; let commit: Body
            struct Body: Decodable { let tree: Tree; struct Tree: Decodable { let sha: String } }
        }
        struct Tree: Decodable { let tree: [RepositoryFile]; let truncated: Bool }
        let info = try await api(address.slug, as: Info.self)
        var scope = ""
        let commit: Commit
        if address.suffix.isEmpty {
            commit = try await api(address.slug + "/commits/" + RepositoryAddress.encoded(info.default_branch), as: Commit.self)
        } else {
            // GitHub branch names may contain slashes. Resolve the longest valid ref first.
            guard address.suffix.count <= 16 else { throw ImportFailure(message: "This link is too deeply nested. Paste the repository’s main link instead.") }
            var resolved: Commit?
            for count in stride(from: address.suffix.count, through: 1, by: -1) {
                do {
                    resolved = try await api(address.slug + "/commits/" + RepositoryAddress.encoded(address.suffix.prefix(count).joined(separator: "/")), as: Commit.self)
                    scope = address.suffix.dropFirst(count).joined(separator: "/")
                    break
                } catch let error as RepositoryHTTPError where error.status == 404 || error.status == 422 { continue }
            }
            guard let resolved else { throw ImportFailure(message: "Couldn’t find this branch or tag. Paste the repository’s main link instead.") }
            commit = resolved
        }
        guard commit.sha.count == 40 && commit.sha.allSatisfy({ $0.isHexDigit }) else { throw ImportFailure(message: "GitHub returned an invalid commit identifier.") }
        let tree = try await api(address.slug + "/git/trees/" + commit.commit.tree.sha + "?recursive=1", as: Tree.self)
        guard !tree.truncated else { throw ImportFailure(message: "GitHub’s file listing for this repository is too large. Import the video files locally instead; no partial listing was used.") }
        return RepositoryPack.discover(address: address, commit: commit.sha, files: tree.tree, scope: scope)
    }

    func fetch(_ file: RepositoryFile, from pack: RepositoryPack, to destination: URL, limit: Int64, progress: @escaping (Int64) -> Void = { _ in }) async throws {
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        guard file.regular else { throw ImportFailure(message: "Only regular media files can be downloaded.") }
        guard (file.size ?? 0) <= limit else { throw ImportFailure(message: "\(file.path) exceeds the per-file download limit.") }
        try await download(RepositoryAddress.fileURL(repository: pack.address.url, commit: pack.commit, path: file.path), to: destination, limit: limit, progress: progress)
        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard file.size == nil || size == file.size else { throw ImportFailure(message: "The download of \(file.path) was incomplete. Try importing again.") }
        // Raw GitHub serves LFS pointers. Resolve the actual pinned media and verify it.
        if size < 1024, let text = try? String(contentsOf: destination, encoding: .utf8), text.hasPrefix("version https://git-lfs.github.com/spec/v1\n") {
            let lines = text.split(separator: "\n").map(String.init)
            guard let oid = lines.first(where: { $0.hasPrefix("oid sha256:") }).map({ String($0.dropFirst(11)) }),
                  oid.count == 64, oid.allSatisfy({ $0.isHexDigit }),
                  let length = lines.first(where: { $0.hasPrefix("size ") }).flatMap({ Int64($0.dropFirst(5)) }), length > 0, length <= limit else {
                throw ImportFailure(message: "\(file.path) has an invalid or oversized Git LFS pointer.")
            }
            try FileManager.default.removeItem(at: destination)
            let url = RepositoryAddress.fileURL(repository: pack.address.url, commit: pack.commit, path: file.path, host: "media.githubusercontent.com")
            try await download(url, to: destination, limit: limit, progress: progress)
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hash = SHA256(); var total: Int64 = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation(); hash.update(data: data); total += Int64(data.count)
            }
            guard total == length, hash.finalize().map({ String(format: "%02x", $0) }).joined() == oid else {
                throw ImportFailure(message: "Git LFS media failed its size or checksum check: \(file.path).")
            }
        }
        completed = true
    }

    func preserveNotices(_ pack: RepositoryPack, under root: URL) async throws -> URL {
        let folder = root.appendingPathComponent("Source Packs/GitHub").appendingPathComponent(pack.address.owner).appendingPathComponent(pack.address.name).appendingPathComponent(pack.commit)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = ["repository": pack.address.url.absoluteString, "commit": pack.commit]
        try JSONEncoder().encode(source).write(to: folder.appendingPathComponent("SOURCE.json"), options: .atomic)
        guard pack.notices.count <= 64 else { throw ImportFailure(message: "This repository has too many media notices to archive automatically. Import its media locally instead.") }
        for file in pack.notices {
            try Task.checkCancellation()
            let target = folder.appendingPathComponent("Repository").appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fetch(file, from: pack, to: target, limit: 1_048_576)
        }
        return folder
    }
}
