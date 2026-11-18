import AppKit

/// Uses the public desktop-image API. macOS owns Spaces sharing; this class never
/// edits WallpaperAgent's private store or restarts Dock/WindowServer.
@MainActor
final class SystemWallpaper {
    private struct Previous: Codable {
        let display: String
        let originalURL: URL
        let copiedURL: URL?
        let scaling: Int
        let clipping: Bool
        let color: [Double]?
    }
    private let root: URL
    private(set) var installedURL: URL?
    private var backupURL: URL { root.appendingPathComponent("previous-wallpaper.json") }
    var hasPrevious: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    init(root: URL) { self.root = root }

    private func displayID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
        let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value).takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func previous() throws -> [Previous] {
        guard hasPrevious else { return [] }
        return try JSONDecoder().decode([Previous].self, from: Data(contentsOf: backupURL))
    }
    private func preserve(_ screen: NSScreen) throws {
        var entries = try previous()
        let id = displayID(screen)
        guard !entries.contains(where: { $0.display == id }) else { return }
        guard let original = NSWorkspace.shared.desktopImageURL(for: screen) else {
            throw ImportFailure(message: "macOS didn’t provide the current wallpaper, so it couldn’t be backed up.")
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let rgb = (options[.fillColor] as? NSColor)?.usingColorSpace(.deviceRGB)
        let color = rgb.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent), Double($0.alphaComponent)] }
        let folder = root.appendingPathComponent("Previous Wallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied: URL?
        if original.isFileURL, FileManager.default.fileExists(atPath: original.path) {
            let path = folder.appendingPathComponent(id).appendingPathExtension(original.pathExtension)
            if !FileManager.default.fileExists(atPath: path.path) { try FileManager.default.copyItem(at: original, to: path) }
            copied = path
        }
        entries.append(Previous(display: id, originalURL: original, copiedURL: copied,
                                scaling: (options[.imageScaling] as? NSNumber)?.intValue ?? Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                                clipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? true, color: color))
        try JSONEncoder().encode(entries).write(to: backupURL, options: .atomic)
    }
    func install(_ image: URL) throws {
        // A library scene may be removed later. Keep the native wallpaper in a
        // separate durable directory so macOS never points at a deleted scene.
        let folder = root.appendingPathComponent("System Wallpapers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let published = folder.appendingPathComponent(image.deletingLastPathComponent().lastPathComponent + "-" + image.lastPathComponent)
        if !FileManager.default.fileExists(atPath: published.path) {
            try FileManager.default.copyItem(at: image, to: published)
        }
        try apply(published)
        installedURL = published
    }
    private func apply(_ image: URL) throws {
        // Snapshot every display before any write, including when macOS shares
        // one wallpaper across multiple displays.
        for screen in NSScreen.screens { try preserve(screen) }
        for screen in NSScreen.screens {
            if NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL != image.standardizedFileURL {
                try NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                    .fillColor: NSColor.black
                ])
            }
        }
    }
    func synchronize() throws {
        if let installedURL { try apply(installedURL) }
    }
    func restore() throws {
        let entries = try previous()
        guard !entries.isEmpty else { throw ImportFailure(message: "No previous wallpaper has been saved yet.") }
        installedURL = nil
        for screen in NSScreen.screens {
            guard let entry = entries.first(where: { $0.display == displayID(screen) }) else { continue }
            let url = FileManager.default.fileExists(atPath: entry.originalURL.path) ? entry.originalURL : entry.copiedURL ?? entry.originalURL
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [.imageScaling: entry.scaling, .allowClipping: entry.clipping]
            if let c = entry.color, c.count == 4 {
                options[.fillColor] = NSColor(deviceRed: c[0], green: c[1], blue: c[2], alpha: c[3])
            }
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
    }
}
