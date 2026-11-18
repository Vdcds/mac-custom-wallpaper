import AppKit
import AVFoundation

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WallpaperEngine {
    struct Surface {
        let displayID: CGDirectDisplayID
        let window: DesktopWindow
        let image: CALayer
        let video: AVPlayerLayer
    }
    private(set) var surfaces: [Surface] = []
    private(set) var player: AVPlayer?
    private(set) var phase = "Stopped"
    private var currentImage: CGImage?
    private var pendingImage: CGImage?
    private var pendingStillURL: URL?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var boundary: Any?
    private var statusObservation: NSKeyValueObservation?
    private var layerObservations: [NSKeyValueObservation] = []
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    var onChange: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStillReady: ((URL) -> Void)?
    var decoderReleased: Bool { player == nil && surfaces.allSatisfy { $0.video.player == nil } }

    private func loadStill(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImportFailure(message: "The saved final frame is missing or damaged. Remove and reimport this scene.")
        }
        return image
    }

    func showStill(_ url: URL) throws {
        let image = try loadStill(url)
        releasePlayer()
        currentImage = image
        rebuildScreens()
        onStillReady?(url)
        setPhase("Still · ready for next wake")
    }

    func rebuildScreens() {
        guard currentImage != nil else { return }
        let screens = NSScreen.screens
        let existing = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.displayID, $0) })
        var remaining = existing
        surfaces = screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            if let surface = remaining.removeValue(forKey: id) {
                surface.window.setFrame(screen.frame, display: true)
                configure(surface, screen: screen)
                return surface
            }
            let window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.isOpaque = true
            window.backgroundColor = .black
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let image = CALayer()
            image.contents = currentImage
            image.contentsGravity = .resizeAspectFill
            image.masksToBounds = true
            let video = AVPlayerLayer(player: player)
            video.videoGravity = .resizeAspectFill
            video.opacity = 0
            view.layer?.addSublayer(image)
            view.layer?.addSublayer(video)
            window.contentView = view
            let surface = Surface(displayID: id, window: window, image: image, video: video)
            configure(surface, screen: screen)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return surface
        }
        remaining.values.forEach { $0.window.close() }
        observeLayers()
    }

    private func configure(_ surface: Surface, screen: NSScreen) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        surface.image.contents = currentImage
        surface.image.frame = bounds
        surface.video.frame = bounds
        surface.image.contentsScale = screen.backingScaleFactor
        surface.video.contentsScale = screen.backingScaleFactor
        surface.image.minificationFilter = .trilinear
        surface.image.magnificationFilter = .linear
        CATransaction.commit()
    }

    private func observeLayers() {
        layerObservations = surfaces.map { surface in
            surface.video.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                Task { @MainActor in
                    guard self?.player != nil else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.opacity = layer.isReadyForDisplay ? 1 : 0
                    CATransaction.commit()
                }
            }
        }
    }

    func play(_ scene: Scene, disk: LibraryDisk) throws {
        let finalImage = try loadStill(disk.still(scene))
        releasePlayer()
        pendingImage = finalImage
        pendingStillURL = disk.still(scene)
        // Keep the existing wallpaper visible while the new intro is prepared.
        // Its ending is installed only when that intro finishes or is suspended.
        if currentImage == nil {
            currentImage = finalImage
            rebuildScreens()
        }
        let token = UUID()
        generation = token
        let item = AVPlayerItem(url: disk.movie(scene))
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer
        surfaces.forEach { $0.video.player = newPlayer }
        observeLayers()
        setPhase("Loading intro…")
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish(token) }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fail(token, message: item.error?.localizedDescription ?? "Video decoding failed during playback.") }
        }
        if scene.stillTime > 0 {
            boundary = newPlayer.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: scene.stillTime, preferredTimescale: 60000))], queue: .main) { [weak self] in
                Task { @MainActor in self?.finish(token) }
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                switch item.status {
                case .readyToPlay:
                    newPlayer.preroll(atRate: 1) { [weak self] ready in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            guard ready else { self.fail(token, message: "Couldn’t prepare the intro for playback."); return }
                            self.setPhase("Playing intro · muted")
                            newPlayer.play()
                            self.timeout?.cancel()
                            self.timeout = Task { [weak self] in
                                try? await Task.sleep(for: .seconds(scene.duration + 8))
                                guard !Task.isCancelled else { return }
                                self?.fail(token, message: "Playback stalled. The final frame is still available; try reimporting this video.")
                            }
                        }
                    }
                case .failed: self.fail(token, message: item.error?.localizedDescription ?? "macOS couldn’t decode this video.")
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.fail(token, message: "This video took too long to load. Try exporting a new copy with QuickTime Player.")
        }
    }

    private func finish(_ token: UUID) {
        guard token == generation else { return }
        installPendingStill()
        releasePlayer()
        setPhase("Still · ready for next wake")
    }
    private func installPendingStill() {
        guard let pendingImage else { return }
        currentImage = pendingImage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaces.forEach { $0.image.contents = pendingImage }
        CATransaction.commit()
        if let pendingStillURL { onStillReady?(pendingStillURL) }
    }
    private func fail(_ token: UUID, message: String) {
        guard token == generation else { return }
        finish(token)
        onError?(message)
    }
    func settle() {
        installPendingStill()
        releasePlayer()
        if currentImage != nil { setPhase("Still · ready for next wake") }
    }
    func stop() {
        releasePlayer()
        surfaces.forEach { $0.window.close() }
        surfaces.removeAll()
        currentImage = nil
        setPhase("Intro stopped · system wallpaper kept")
    }
    private func setPhase(_ text: String) { phase = text; onChange?(text) }
    private func releasePlayer() {
        generation = UUID()
        pendingImage = nil
        pendingStillURL = nil
        timeout?.cancel(); timeout = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil; failureObserver = nil
        if let boundary, let player { player.removeTimeObserver(boundary) }
        boundary = nil
        player?.pause()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaces.forEach { $0.video.opacity = 0; $0.video.player = nil }
        CATransaction.commit()
        layerObservations.removeAll()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
