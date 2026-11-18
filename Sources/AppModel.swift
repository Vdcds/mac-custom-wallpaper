import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var state = LibraryState()
    @Published var status = "Ready"
    @Published var busy = false
    @Published var error: String? {
        didSet { if error != nil { onPresentError?() } }
    }
    @Published var loginEnabled = false
    @Published var loginNote = ""
    let disk: LibraryDisk
    let engine = WallpaperEngine()
    let wake = WakeMonitor()
    private var storageWritable = true
    var selected: Scene? { state.scenes.first { $0.id == state.selectedID } }
    var onStateChange: (() -> Void)?
    var onBeforeReplay: (() -> Void)?
    var onPresentError: (() -> Void)?
    var onShowPicker: (() -> Void)?
    private(set) var replayCount = 0

    init(root: URL) {
        disk = LibraryDisk(root: root)
        do { state = try disk.read() }
        catch {
            storageWritable = false
            self.error = "Couldn’t read the library at \(root.path). Your files were left intact. \(error.localizedDescription)"
        }
        engine.onChange = { [weak self] in self?.status = $0; self?.onStateChange?() }
        engine.onError = { [weak self] in self?.error = $0 }
        wake.onReplay = { [weak self] in
            guard let self, self.state.enabled else { return }; self.replay()
        }
        wake.onSuspend = { [weak self] in self?.engine.settle() }
        wake.onEvent = { event in NSLog("Wake Scenes lifecycle: %@", event) }
        refreshLogin()
    }
    func start() {
        if state.enabled, let selected {
            do { try engine.showStill(disk.still(selected)) }
            catch { self.error = error.localizedDescription }
        }
    }
    @discardableResult
    func save(_ next: LibraryState) -> Bool {
        guard storageWritable else { error = "Library is unavailable. Restart after repairing library.json in \(disk.root.path)."; return false }
        do { try disk.write(next); state = next; onStateChange?(); return true }
        catch { self.error = "Couldn’t save the library: \(error.localizedDescription)"; return false }
    }
    func importFiles(_ urls: [URL]) {
        guard !busy, storageWritable, !urls.isEmpty else { return }
        busy = true
        Task {
            var failures: [String] = []
            for url in urls {
                status = "Importing \(url.lastPathComponent)…"
                do {
                    let disk = self.disk
                    let scene = try await Task.detached(priority: .userInitiated) { try await disk.ingest(url) }.value
                    var next = state
                    if !next.scenes.contains(where: { $0.id == scene.id }) { next.scenes.append(scene) }
                    let first = next.selectedID == nil
                    if first { next.selectedID = scene.id }
                    if save(next), first { start() }
                } catch { failures.append(error.localizedDescription) }
            }
            busy = false
            status = engine.phase
            if !failures.isEmpty { error = failures.joined(separator: "\n\n") }
        }
    }
    func choose(_ scene: Scene) {
        var next = state; next.selectedID = scene.id; next.enabled = true
        guard save(next) else { return }
        wake.cancelPending()
        replay()
    }
    func replay() {
        guard let selected else { return }
        guard WakeMonitor.sessionAvailable else { status = "Unlock this Mac to replay"; return }
        if !state.enabled { var next = state; next.enabled = true; guard save(next) else { return } }
        do {
            try engine.play(selected, disk: disk)
            onBeforeReplay?()
            replayCount += 1
        }
        catch { self.error = error.localizedDescription }
    }
    func setEnabled(_ enabled: Bool) {
        var next = state; next.enabled = enabled
        guard save(next) else { return }
        wake.cancelPending()
        if enabled { start() } else { engine.stop() }
    }
    func remove(_ scene: Scene) {
        guard !busy else { return }
        var next = state
        next.scenes.removeAll { $0.id == scene.id }
        let wasSelected = state.selectedID == scene.id
        if wasSelected { next.selectedID = next.scenes.first?.id }
        guard save(next) else { return }
        if wasSelected { engine.stop(); start() }
        do { try FileManager.default.removeItem(at: disk.folder(scene)) }
        catch { self.error = "Scene removed from library, but its files couldn’t be deleted: \(error.localizedDescription)" }
    }
    func refreshLogin() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginNote = status == .requiresApproval ? "Approve Wake Scenes in System Settings → General → Login Items." : ""
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "Couldn’t change launch at login. Install the app in Applications first. \(error.localizedDescription)" }
        refreshLogin()
    }
    func shutdown() { wake.shutdown(); engine.stop() }
}

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @StateObject private var viewState = LibraryViewState()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A little motion.\nA calmer desktop.").font(.system(size: 29, weight: .semibold, design: .rounded))
                    Text("One intro after wake. Then a quiet still.").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 12) {
                    Image(systemName: "sun.horizon.fill").font(.system(size: 30)).foregroundStyle(.orange)
                    Button("Choose scene…") { model.onShowPicker?() }.disabled(model.state.scenes.isEmpty)
                }
            }
            HStack {
                Image(systemName: "arrow.down.doc")
                Text(model.busy ? model.status : "Drop videos here, or import a scene")
                Spacer()
                Button("Import…", action: importPanel).disabled(model.busy)
            }
            .padding(16)
            .background(viewState.targeted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(viewState.targeted ? Color.accentColor : Color.primary.opacity(0.1)))
            if model.state.scenes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Your next favorite moment").font(.headline)
                    Text("Add a local video. We’ll keep a copy and save its final frame.\nShort clips work especially well; audio always stays muted.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.state.scenes) { scene in
                            HStack(spacing: 14) {
                                SceneThumbnail(url: model.disk.still(scene))
                                    .frame(width: 112, height: 65).clipped().cornerRadius(7)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(scene.name).font(.headline).lineLimit(1)
                                    Text(String(format: "%.1f sec · %@", scene.duration, ByteCountFormatter.string(fromByteCount: scene.bytes, countStyle: .file))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if scene.id == model.state.selectedID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("Selected")
                                }
                                Button(scene.id == model.state.selectedID ? "Replay" : "Use scene") { model.choose(scene) }
                                Button { viewState.removing = scene } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove imported copy").disabled(model.busy)
                            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Wallpaper on", isOn: Binding(get: { model.state.enabled }, set: model.setEnabled))
                    .toggleStyle(.switch).disabled(model.selected == nil)
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Replay now") { model.replay() }.disabled(model.selected == nil)
            }
            Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
            if !model.loginNote.isEmpty {
                HStack {
                    Text(model.loginNote).font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Text("Replays after system or display sleep, once unlocked. macOS doesn’t reliably identify lid-open wakes. Your system wallpaper stays untouched.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(minWidth: 660, minHeight: 550)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $viewState.targeted) { providers in
            guard !model.busy else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                model.importFiles(urls)
            }
            return true
        }
        .alert("Couldn’t complete that", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Remove \(viewState.removing?.name ?? "scene")?", isPresented: Binding(get: { viewState.removing != nil }, set: { if !$0 { viewState.removing = nil } }), titleVisibility: .visible) {
            Button("Remove imported copy", role: .destructive) { if let scene = viewState.removing { model.remove(scene) }; viewState.removing = nil }
        } message: { Text("Your original video will stay where it is.") }
        .onAppear { model.refreshLogin() }
    }
    private func importPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import videos"
        panel.message = "Choose local videos that macOS can decode. Files are copied into your library."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Keep all files selectable: decoder support is broader than extension lists.
        panel.begin { response in
            if response == .OK { model.importFiles(panel.urls) }
        }
    }
}

private final class LibraryViewState: ObservableObject {
    @Published var targeted = false
    @Published var removing: Scene?
}
private final class ThumbnailState: ObservableObject {
    @Published var image: NSImage?
}
struct SceneThumbnail: View {
    let url: URL
    var pixelSize: Int = 300
    @StateObject private var thumbnail = ThumbnailState()
    var body: some View {
        ZStack {
            Color.black.opacity(0.1)
            if let image = thumbnail.image { Image(nsImage: image).resizable().scaledToFill() }
        }.task(id: url) {
            // Downsample thumbnails instead of retaining a 4K bitmap per row.
            let value = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return Optional<NSImage>.none }
                return NSImage(cgImage: cg, size: .zero)
            }.value
            thumbnail.image = value
        }
    }
}
