import AppKit
import SwiftUI

struct RepositoryImportResult {
    var scenes: [Scene] = []
    var failures: [String] = []
    var cancelled = false
}

extension AppModel {
    func importRepository(_ pack: RepositoryPack, paths: Set<String>, client: RepositoryClient,
                          progress: @escaping (String) -> Void) async -> RepositoryImportResult {
        guard !busy, storageWritable else {
            return RepositoryImportResult(failures: ["Wait for the current import to finish, or repair the unavailable library."])
        }
        let videos = pack.videos.filter { paths.contains($0.id) }
        guard !videos.isEmpty else { return RepositoryImportResult(failures: ["Select at least one video."]) }
        guard videos.reduce(Int64(0), { $0 + ($1.file.size ?? 0) }) <= 8 * 1024 * 1024 * 1024 else {
            return RepositoryImportResult(failures: ["Choose fewer videos. Each import is limited to 8 GB; Git LFS sizes are checked during download."])
        }
        busy = true
        defer { busy = false; status = engine.phase }
        var result = RepositoryImportResult()
        var downloadedBytes: Int64 = 0
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Wake-Scenes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            progress("Saving source and media notices…")
            _ = try await client.preserveNotices(pack, under: disk.root)
            for (index, video) in videos.enumerated() {
                try Task.checkCancellation()
                if let existing = state.scenes.first(where: {
                    $0.source?.repository == pack.address.url && $0.source?.commit == pack.commit && $0.source?.videoPath == video.file.path
                }), FileManager.default.fileExists(atPath: disk.movie(existing).path), FileManager.default.fileExists(atPath: disk.still(existing).path) {
                    result.scenes.append(existing)
                    continue
                }
                let prefix = "\(index + 1)/\(videos.count) · \(video.name)"
                progress("Downloading \(prefix)…")
                let folder = scratch.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    let local = folder.appendingPathComponent(URL(fileURLWithPath: video.file.path).lastPathComponent)
                    let remaining = 8 * 1024 * 1024 * 1024 - downloadedBytes
                    guard remaining > 0 else { throw ImportFailure(message: "The 8 GB import limit was reached. Import the remaining scenes separately.") }
                    try await client.fetch(video.file, from: pack, to: local, limit: min(RepositoryClient.videoLimit, remaining)) { bytes in
                        let amount = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                        Task { @MainActor in progress("Downloading \(prefix) · \(amount)") }
                    }
                    downloadedBytes += (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
                    var posterURL: URL?
                    if let poster = video.poster {
                        let target = folder.appendingPathComponent("poster").appendingPathExtension(URL(fileURLWithPath: poster.path).pathExtension)
                        try await client.fetch(poster, from: pack, to: target, limit: 100 * 1024 * 1024)
                        posterURL = target
                    }
                    progress("Preparing \(prefix)…")
                    let origin = SceneSource(repository: pack.address.url, commit: pack.commit, videoPath: video.file.path, posterPath: video.poster?.path)
                    let disk = self.disk
                    let poster = posterURL
                    let ingestion = Task.detached(priority: .userInitiated) { try await disk.ingest(local, poster: poster, origin: origin) }
                    let scene = try await withTaskCancellationHandler { try await ingestion.value } onCancel: { ingestion.cancel() }
                    var next = state
                    if let existing = next.scenes.firstIndex(where: { $0.id == scene.id }) {
                        // Keep existing media and selection, but remember where this copy was found.
                        if next.scenes[existing].source == nil { next.scenes[existing].source = origin }
                    } else { next.scenes.append(scene) }
                    if next.selectedID == nil { next.selectedID = scene.id }
                    guard save(next) else { throw ImportFailure(message: error ?? "Couldn’t save the library.") }
                    result.scenes.append(next.scenes.first { $0.id == scene.id }!)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    result.failures.append("\(video.file.path): \(error.localizedDescription)")
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { result.cancelled = true }
            else { result.failures.append(error.localizedDescription) }
        }
        return result
    }
}

@MainActor
final class RepositoryImportModel: ObservableObject {
    @Published var link = ""
    @Published var pack: RepositoryPack?
    @Published var selection = Set<String>()
    @Published var working = false
    @Published var importing = false
    @Published var message = ""
    @Published var error: String?
    @Published var result: RepositoryImportResult?
    private var task: Task<Void, Never>?
    let client = RepositoryClient()

    func scan() {
        guard !working else { return }
        working = true; pack = nil; result = nil; error = nil; message = "Looking for video wallpapers…"
        let input = link
        task = Task {
            defer { working = false; task = nil }
            do {
                let found = try await client.scan(input)
                try Task.checkCancellation()
                pack = found
                selection = Set(found.videos.prefix(1).map(\.id))
                message = ""
            } catch {
                if Task.isCancelled { message = "Search cancelled." }
                else { self.error = error.localizedDescription; message = "" }
            }
        }
    }
    func runImport(model: AppModel, finish: @escaping (Scene) -> Void) {
        guard !working, let pack else { return }
        working = true; importing = true; error = nil; result = nil
        task = Task {
            defer { working = false; importing = false; task = nil }
            let imported = await model.importRepository(pack, paths: selection, client: client) { self.message = $0 }
            result = imported
            message = imported.cancelled ? "Cancelled. Completed imports are in your library." : "\(imported.scenes.count) scene(s) ready in your library."
            if !imported.failures.isEmpty { error = imported.failures.joined(separator: "\n\n") }
            if !imported.cancelled, imported.failures.isEmpty, let first = imported.scenes.first { finish(first) }
        }
    }
    func cancel() { task?.cancel() }
}

struct RepositoryImportView: View {
    @ObservedObject var model: AppModel
    @StateObject private var importer = RepositoryImportModel()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add wallpapers from GitHub").font(.title2.weight(.semibold))
            Text("Paste an Omarchy theme or video-wallpaper repository link.").foregroundStyle(.secondary)
            HStack {
                TextField("https://github.com/owner/theme", text: $importer.link)
                    .textFieldStyle(.roundedBorder).disabled(importer.working).onSubmit { importer.scan() }
                    .accessibilityLabel("GitHub repository link")
                    .onChange(of: importer.link) {
                        importer.pack = nil; importer.selection = []; importer.result = nil
                        importer.error = nil; importer.message = ""
                    }
                Button("Find wallpapers") { importer.scan() }.disabled(importer.working || importer.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let pack = importer.pack {
                HStack {
                    Link(pack.address.slug, destination: pack.address.url).font(.headline)
                    Spacer()
                    Text("\(pack.videos.count) videos").foregroundStyle(.secondary)
                }
                if pack.videos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No video wallpapers in this repository").font(.headline)
                        Text("Found \(pack.imageCount) still images. A theme can animate its wallpaper using Linux code or link to downloads elsewhere; those aren’t playable video files. Try a repository containing intro videos, or download its footage and use Import in the library.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    HStack {
                        Button("Select all") { importer.selection = Set(pack.videos.map(\.id)) }
                        Button("Clear") { importer.selection = [] }
                        Spacer()
                        Text(selectionSize(pack)).font(.caption).foregroundStyle(.secondary)
                    }.disabled(importer.working)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(pack.videos) { video in
                                Toggle(isOn: Binding(get: { importer.selection.contains(video.id) }, set: { enabled in
                                    if enabled { importer.selection.insert(video.id) } else { importer.selection.remove(video.id) }
                                })) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(video.name).font(.headline)
                                        Text(video.file.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text("\(ByteCountFormatter.string(fromByteCount: video.file.size ?? 0, countStyle: .file)) · \(video.poster == nil ? "Final frame saved from video" : "Matching original still included")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 10)
                                }.toggleStyle(.checkbox).disabled(importer.working)
                                Divider()
                            }
                        }
                    }.frame(minHeight: 140, maxHeight: .infinity)
                }
            } else if !importer.working, importer.error == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Intro videos and matching stills", systemImage: "play.rectangle")
                    Label("Original downloads, with no quality-reducing export", systemImage: "arrow.down.doc")
                    Label("Choose a scene, then replay once after unlock", systemImage: "sun.horizon")
                }.foregroundStyle(.secondary).padding(.vertical, 12)
            }
            if importer.working {
                HStack { ProgressView().controlSize(.small); Text(importer.message).font(.callout).lineLimit(2) }
            } else if !importer.message.isEmpty { Text(importer.message).foregroundStyle(.secondary) }
            if let error = importer.error {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
            }
            Spacer(minLength: 0)
            Text("Public GitHub repositories only. Videos must be decodable by macOS. Source links and repository notices are kept with your library. Some files may use Git LFS, so their final download size can be larger.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if importer.working { Button("Cancel \(importer.importing ? "import" : "search")") { importer.cancel() } }
                else { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
                Spacer()
                if !importer.working, let first = importer.result?.scenes.first {
                    Button("Use imported scene") { finish(first) }
                }
                Button("Import & use") { importer.runImport(model: model, finish: finish) }
                    .buttonStyle(.borderedProminent)
                    .disabled(importer.working || model.busy || importer.pack == nil || importer.selection.isEmpty)
            }
        }.padding(24).frame(width: 650, height: 570)
            .interactiveDismissDisabled(importer.working)
            .onDisappear { importer.cancel() }
    }
    private func selectionSize(_ pack: RepositoryPack) -> String {
        let bytes = pack.videos.filter { importer.selection.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.file.size ?? 0) + ($1.poster?.size ?? 0) }
        return "\(importer.selection.count) selected · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
    private func finish(_ scene: Scene) { dismiss(); model.choose(scene) }
}
