import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    private var pickerPanel: ScenePickerPanel?
    private var observers: [NSObjectProtocol] = []
    private var pendingURLs: [URL] = []
    let arguments = CommandLine.arguments
    var testMode: Bool { arguments.contains("--self-test") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root: URL
        if let index = arguments.firstIndex(of: "--library"), arguments.count > index + 1 {
            root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Wake Scenes", isDirectory: true)
        }
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Wake Scenes", action: #selector(quit), keyEquivalent: "q").target = self
        let appItem = NSMenuItem(); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Library…", action: #selector(showLibrary), keyEquivalent: "o").target = self
        let pickerItem = fileMenu.addItem(withTitle: "Choose Scene…", action: #selector(showPicker), keyEquivalent: "s")
        pickerItem.target = self
        pickerItem.keyEquivalentModifierMask = [.command, .shift]
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu; mainMenu.addItem(fileItem)
        fileMenu.addItem(withTitle: "Choose Scene…", action: #selector(showPicker), keyEquivalent: "s").target = self
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu; mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        model = AppModel(root: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = testMode ? "Wake Scenes · Verification" : "Wake Scenes"
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.minSize = NSSize(width: 710, height: 610)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.horizon", accessibilityDescription: "Wake Scenes")
        model.onStateChange = { [weak self] in self?.updateMenu() }
        model.onBeforeReplay = { [weak self] in
            self?.window.orderOut(nil)
            self?.dismissPicker()
        }
        model.onShowPicker = { [weak self] in self?.showPicker() }
        model.onPresentError = { [weak self] in self?.showLibrary() }
        updateMenu()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let model = self?.model, model.state.enabled, model.selected != nil else { return }
                model.engine.rebuildScreens()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let model = self?.model, model.state.enabled, model.selected != nil else { return }
                model.engine.rebuildScreens()
            }
        })
        model.start()
        if testMode {
            Task { await runVerification(model: model, arguments: arguments) }
        } else {
            if model.state.scenes.isEmpty || arguments.contains("--show-library") { showLibrary() }
            if arguments.contains("--show-picker") { showPicker() }
            if !pendingURLs.isEmpty { model.importFiles(pendingURLs); pendingURLs.removeAll() }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if model == nil { pendingURLs += urls }
        else { showLibrary(); model.importFiles(urls) }
        sender.reply(toOpenOrPrint: .success)
    }
    func updateMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Library…", action: #selector(showLibrary), keyEquivalent: "o").target = self
        let replay = menu.addItem(withTitle: "Replay Now", action: #selector(replay), keyEquivalent: "r")
        replay.target = self; replay.isEnabled = model.selected != nil
        let choose = menu.addItem(withTitle: "Choose Scene…", action: #selector(showPicker), keyEquivalent: "s")
        choose.keyEquivalentModifierMask = [.command, .shift]
        choose.target = self; choose.isEnabled = !model.state.scenes.isEmpty
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: model.state.enabled ? "Stop Wallpaper" : "Resume Wallpaper", action: #selector(toggleWallpaper), keyEquivalent: "")
        toggle.target = self; toggle.isEnabled = model.selected != nil
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Wake Scenes", action: #selector(quit), keyEquivalent: "q").target = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }
    @objc func showLibrary() { dismissPicker(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); model.refreshLogin() }
    @objc func replay() { model.replay() }
    @objc func showPicker() {
        guard !model.state.scenes.isEmpty else { showLibrary(); return }
        dismissPicker()
        window.orderOut(nil)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let width = min(1080, screen.visibleFrame.width - 48)
        let panel = ScenePickerPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 220),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        let picker = ScenePickerState(model: model) { [weak self] in self?.dismissPicker() }
        panel.pickerState = picker
        panel.contentView = NSHostingView(rootView: ScenePickerView(picker: picker))
        panel.title = "Choose Scene"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - 110))
        pickerPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel)
    }
    private func dismissPicker() {
        pickerPanel?.close()
        pickerPanel = nil
    }
    @objc func toggleWallpaper() { model.setEnabled(!model.state.enabled) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

MainActor.assumeIsolated {
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

}
